#! -*-perl-*-

# ~/bin/w
# Search for potentially misspelled words
# Output is:
# misspellled
# woord (WOORD, Woord, woord, woord's)
package CheckSpelling::UnknownWordSplitter;

use 5.022;
use feature 'unicode_strings';
use strict;
use warnings;
no warnings qw(experimental::vlb);
use Encode qw/decode_utf8 encode FB_DEFAULT/;
use File::Basename;
use Cwd 'abs_path';
use File::Temp qw/ tempfile tempdir /;
use CheckSpelling::Util;
our $VERSION='0.1.0';

my ($longest_word, $shortest_word, $word_match, $forbidden_re, $patterns_re, $candidates_re, $disable_word_collating, $check_file_names);
my ($ignore_pattern, $upper_pattern, $lower_pattern, $not_lower_pattern, $not_upper_or_lower_pattern, $punctuation_pattern);
my ($shortest, $longest) = (255, 0);
my @forbidden_re_list;
my @candidates_re_list;
my $hunspell_dictionary_path;
my @hunspell_dictionaries;
my %dictionary = ();
my $base_dict;
my %unique;
my %unique_unrecognized;
my ($last_file, $words, $unrecognized) = ('', 0, 0);

my $disable_flags;

sub test_re {
  my ($expression) = @_;
  return eval { qr /$expression/ };
}

sub quote_re {
  my ($expression) = @_;
  return $expression if $expression =~ /\?\{/;
  $expression =~ s/
   \G
   (
      (?:[^\\]|\\[^Q])*
   )
   (?:
      \\Q
      (?:[^\\]|\\[^E])*
      (?:\\E)?
   )?
/
   $1 . (defined($2) ? quotemeta($2) : '')
/xge;
  return $expression;
}

sub file_to_list {
  my ($re) = @_;
  my @file;
  return @file unless open(FILE, '<:utf8', $re);

  local $/=undef;
  my $file=<FILE>;
  close FILE;
  my $line_number = 0;
  for (split /\R/, $file) {
    ++$line_number;
    next if /^#/;
    chomp;
    next unless s/^(.+)/(?:$1)/;
    my $quoted = quote_re($1);
    if (test_re $quoted) {
      push @file, $_;
    } else {
      my $error = $@;
      my $home = dirname(__FILE__);
      $error =~ s/$home.*?\.pm line \d+\./$re line $line_number (bad-regular-expression)/;
      print STDERR $error;
      push @file, '(?:\$^ - skipped because bad-regular-expression)';
    }
  }

  return @file;
}

sub list_to_re {
  my (@list) = @_;
  @list = map { my $quoted = quote_re($_); test_re($quoted) ? $quoted : '' } @list;
  @list = grep { $_ ne '' } @list;
  return '$^' unless scalar @list;
  return join "|", (@list);
}

sub file_to_re {
  my ($re) = @_;
  return list_to_re(file_to_list($re));
}

sub not_empty {
  my ($thing) = @_;
  return defined $thing && $thing ne ''
}

sub valid_word {
  # shortest_word is an absolute
  our ($shortest, $longest, $shortest_word, $longest_word);
  $shortest = $shortest_word if $shortest_word;
  if ($longest_word) {
    # longest_word is an absolute
    $longest = $longest_word;
  } elsif (not_empty($longest)) {
    # we allow for some sloppiness (a couple of stuck keys per word)
    # it's possible that this should scale with word length
    $longest += 2;
  }
  our ($upper_pattern, $lower_pattern, $punctuation_pattern);
  my $word_pattern = join '|', (grep { defined $_ && /./ } ($upper_pattern, $lower_pattern, $punctuation_pattern));
  $word_pattern = q<\\w|'> unless $word_pattern;
  if ((defined $shortest && not_empty($longest)) &&
      ($shortest > $longest)) {
    $word_pattern = "(?:$word_pattern){3}";
    return qr/$word_pattern/;
  }
  $shortest = 3 unless defined $shortest;
  $longest = '' unless defined $longest;
  $word_match = "(?:$word_pattern){$shortest,$longest}";
  return qr/\b$word_match\b/;
}

sub load_dictionary {
  my ($dict) = @_;
  our ($word_match, $longest, $shortest, $longest_word, $shortest_word, %dictionary);
  $longest_word = CheckSpelling::Util::get_val_from_env('INPUT_LONGEST_WORD', undef);
  $shortest_word = CheckSpelling::Util::get_val_from_env('INPUT_SHORTEST_WORD', undef);
  our ($ignore_pattern, $upper_pattern, $lower_pattern, $not_lower_pattern, $not_upper_or_lower_pattern, $punctuation_pattern);
  $ignore_pattern = CheckSpelling::Util::get_file_from_env_utf8('INPUT_IGNORE_PATTERN', q<[^a-zA-Z']>);
  $upper_pattern = CheckSpelling::Util::get_file_from_env_utf8('INPUT_UPPER_PATTERN', '[A-Z]');
  $lower_pattern = CheckSpelling::Util::get_file_from_env_utf8('INPUT_LOWER_PATTERN', '[a-z]');
  $not_lower_pattern = CheckSpelling::Util::get_file_from_env_utf8('INPUT_NOT_LOWER_PATTERN', '[^a-z]');
  $not_upper_or_lower_pattern = CheckSpelling::Util::get_file_from_env_utf8('INPUT_NOT_UPPER_OR_LOWER_PATTERN', '[^A-Za-z]');
  $punctuation_pattern = CheckSpelling::Util::get_file_from_env_utf8('INPUT_PUNCTUATION_PATTERN', q<'>);
  %dictionary = ();

  open(DICT, '<:utf8', $dict);
  while (!eof(DICT)) {
    my $word = <DICT>;
    chomp $word;
    next unless $word =~ $word_match;
    my $l = length $word;
    $longest = -1 unless not_empty($longest);
    $longest = $l if $l > $longest;
    $shortest = $l if $l < $shortest;
    $dictionary{$word}=1;
  }
  close DICT;

  $word_match = valid_word();
}

sub hunspell_dictionary {
  my ($dict) = @_;
  my $name = $dict;
  $name =~ s{/src/index/hunspell/index\.dic$}{};
  $name =~ s{.*/}{};
  my $aff = $dict;
  my $encoding;
  $aff =~ s/\.dic$/.aff/;
  if (open AFF, '<', $aff) {
    while (<AFF>) {
      next unless /^SET\s+(\S+)/;
      $encoding = $1 if ($1 !~ /utf-8/i);
      last;
    }
    close AFF;
  }
  return {
    name => $name,
    dict => $dict,
    aff => $aff,
    encoding => $encoding,
    engine => Text::Hunspell->new($aff, $dict),
  }
}

sub init {
  my ($configuration) = @_;
  our ($word_match, %unique, $patterns_re, @forbidden_re_list, $forbidden_re, @candidates_re_list, $candidates_re);
  our $sandbox = CheckSpelling::Util::get_file_from_env('sandbox', '');
  our $hunspell_dictionary_path = CheckSpelling::Util::get_file_from_env('hunspell_dictionary_path', '');
  our $timeout = CheckSpelling::Util::get_val_from_env('splitter_timeout', 30);
  if ($hunspell_dictionary_path) {
    our @hunspell_dictionaries = ();
    if (eval 'use Text::Hunspell; 1') {
      my @hunspell_dictionaries_list = glob("$hunspell_dictionary_path/*.dic");
      for my $hunspell_dictionary_file (@hunspell_dictionaries_list) {
        push @hunspell_dictionaries, hunspell_dictionary($hunspell_dictionary_file);
      }
    } else {
      print STDERR "Could not load Text::Hunspell for dictionaries (hunspell-unavailable)\n";
    }
  }
  my (@patterns_re_list, %in_patterns_re_list);
  if (-e "$configuration/patterns.txt") {
    @patterns_re_list = file_to_list "$configuration/patterns.txt";
    $patterns_re = list_to_re @patterns_re_list;
    %in_patterns_re_list = map {$_ => 1} @patterns_re_list;
  } else {
    $patterns_re = undef;
  }

  if (-e "$configuration/forbidden.txt") {
    @forbidden_re_list = file_to_list "$configuration/forbidden.txt";
    $forbidden_re = list_to_re @forbidden_re_list;
  } else {
    $forbidden_re = undef;
  }

  if (-e "$configuration/candidates.txt") {
    @candidates_re_list = file_to_list "$configuration/candidates.txt";
    @candidates_re_list = map { my $quoted = quote_re($_); $in_patterns_re_list{$_} || !test_re($quoted) ? '' : $quoted } @candidates_re_list;
    $candidates_re = list_to_re @candidates_re_list;
  } else {
    $candidates_re = undef;
  }

  our $largest_file = CheckSpelling::Util::get_val_from_env('INPUT_LARGEST_FILE', 1024*1024);

  my $disable_flags = CheckSpelling::Util::get_file_from_env('INPUT_DISABLE_CHECKS', '');
  our $disable_word_collating = $disable_flags =~ /(?:^|,|\s)word-collating(?:,|\s|$)/;
  our $disable_minified_file = $disable_flags =~ /(?:^|,|\s)minified-file(?:,|\s|$)/;
  our $disable_single_line_file = $disable_flags =~ /(?:^|,|\s)single-line-file(?:,|\s|$)/;

  our $check_file_names = CheckSpelling::Util::get_file_from_env('check_file_names', '');

  our $use_magic_file = CheckSpelling::Util::get_val_from_env('INPUT_USE_MAGIC_FILE', '');

  $word_match = valid_word();

  our $base_dict = CheckSpelling::Util::get_file_from_env('dict', "$configuration/words");
  $base_dict = '/usr/share/dict/words' unless -e $base_dict;
  load_dictionary($base_dict);
}

sub split_line {
  our (%dictionary, $word_match, $disable_word_collating);
  our ($ignore_pattern, $upper_pattern, $lower_pattern, $not_lower_pattern, $not_upper_or_lower_pattern, $punctuation_pattern);
  our @hunspell_dictionaries;
  our $shortest;
  my $pattern = '.';
  # $pattern = "(?:$upper_pattern){$shortest,}|$upper_pattern(?:$lower_pattern){2,}\n";

  # https://www.fileformat.info/info/unicode/char/2019/
  my $rsqm = "\xE2\x80\x99";

  my ($words, $unrecognized) = (0, 0);
  my ($line, $unique_ref, $unique_unrecognized_ref, $unrecognized_line_items_ref) = @_;
    $line =~ s/(?:$rsqm|&apos;|&#39;|\%27|&#8217;|&#x2019;|&rsquo;|\\u2019|\x{2019}|')+/'/g;
    $line =~ s/(?:$ignore_pattern)+/ /g;
    while ($line =~ s/($upper_pattern{2,})($upper_pattern$lower_pattern{2,})/ $1 $2 /g) {}
    while ($line =~ s/((?:$lower_pattern|$punctuation_pattern)+)($upper_pattern)/$1 $2/g) {}
    for my $token (split /\s+/, $line) {
      next unless $token =~ /$pattern/;
      $token =~ s/^(?:'|$rsqm)+//g;
      $token =~ s/(?:'|$rsqm)+s?$//g;
      my $raw_token = $token;
      $token =~ s/^[^Ii]?'+(.*)/$1/;
      $token =~ s/(.*?)'+$/$1/;
      next unless $token =~ $word_match;
      if (defined $dictionary{$token}) {
        ++$words;
        $unique_ref->{$token}=1;
        next;
      }
      if (@hunspell_dictionaries) {
        my $found = 0;
        for my $hunspell_dictionary (@hunspell_dictionaries) {
          my $token_encoded = defined $hunspell_dictionary->{'encoding'} ?
            encode($hunspell_dictionary->{'encoding'}, $token) : $token;
          next unless ($hunspell_dictionary->{'engine'}->check($token_encoded));
          ++$words;
          $dictionary{$token} = 1;
          $unique_ref->{$token}=1;
          $found = 1;
          last;
        }
        next if $found;
      }
      my $key = lc $token;
      if (defined $dictionary{$key}) {
        ++$words;
        $unique_ref->{$key}=1;
        next;
      }
      unless ($disable_word_collating) {
        $key =~ s/''+/'/g;
        $key =~ s/'[sd]$//;
      }
      if (defined $dictionary{$key}) {
        ++$words;
        $unique_ref->{$key}=1;
        next;
      }
      ++$unrecognized;
      $unique_unrecognized_ref->{$raw_token}=1;
      $unrecognized_line_items_ref->{$raw_token}=1;
    }
    return ($words, $unrecognized);
}

sub skip_file {
  my ($temp_dir, $reason) = @_;
  open(SKIPPED, '>:utf8', "$temp_dir/skipped");
  print SKIPPED $reason;
  close SKIPPED;
}

sub split_file {
  my ($file) = @_;
  our (
    $unrecognized, $shortest, $largest_file, $words,
    $word_match, %unique, %unique_unrecognized, $forbidden_re,
    @forbidden_re_list, $patterns_re, %dictionary,
    $candidates_re, @candidates_re_list, $check_file_names, $use_magic_file, $disable_minified_file,
    $disable_single_line_file,
    $sandbox,
  );
  our ($ignore_pattern, $upper_pattern, $lower_pattern, $not_lower_pattern, $not_upper_or_lower_pattern, $punctuation_pattern);

  # https://www.fileformat.info/info/unicode/char/2019/
  my $rsqm = "\xE2\x80\x99";

  my @candidates_re_hits = (0) x scalar @candidates_re_list;
  my @candidates_re_lines = (0) x scalar @candidates_re_list;
  my @forbidden_re_hits = (0) x scalar @forbidden_re_list;
  my @forbidden_re_lines = (0) x scalar @forbidden_re_list;
  my $temp_dir = tempdir(DIR=>$sandbox);
  print STDERR "checking file: $file\n" if defined $ENV{'DEBUG'};
  open(NAME, '>:utf8', "$temp_dir/name");
    print NAME $file;
  close NAME;
  my $file_size = -s $file;
  if (defined $largest_file) {
    unless ($check_file_names eq $file) {
      if ($file_size > $largest_file) {
        skip_file($temp_dir, "size `$file_size` exceeds limit `$largest_file`. (large-file)\n");
        return $temp_dir;
      }
    }
  }
  if ($use_magic_file) {
    if (open(my $file_fh, '-|',
              '/usr/bin/file',
              '-b',
              '--mime',
              '-e', 'cdf',
              '-e', 'compress',
              '-e', 'csv',
              '-e', 'elf',
              '-e', 'json',
              '-e', 'tar',
              $file)) {
      my $file_kind = <$file_fh>;
      close $file_fh;
      if ($file_kind =~ /^(.*?); charset=binary/) {
        skip_file($temp_dir, "it appears to be a binary file (`$1`). (binary-file)\n");
        return $temp_dir;
      }
    }
  }
  open FILE, '<', $file;
  binmode FILE;
  my $head;
  read(FILE, $head, 4096);
  $head =~ s/(?:\r|\n)+$//;
  my $dos_new_lines = () = $head =~ /\r\n/gi;
  my $unix_new_lines = () = $head =~ /\n/gi;
  my $mac_new_lines = () = $head =~ /\r/gi;
  local $/;
  if ($unix_new_lines == 0 && $mac_new_lines == 0) {
    $/ = "\n";
  } elsif ($dos_new_lines >= $unix_new_lines && $dos_new_lines >= $mac_new_lines) {
    $/ = "\r\n";
  } elsif ($mac_new_lines > $unix_new_lines) {
    $/ = "\r";
  } else {
    $/ = "\n";
  }
  seek(FILE, 0, 0);
  ($words, $unrecognized) = (0, 0);
  %unique = ();
  %unique_unrecognized = ();

  local $SIG{__WARN__} = sub {
    my $message = shift;
    $message =~ s/> line/> in $file - line/;
    chomp $message;
    print STDERR "$message\n";
  };

  open(WARNINGS, '>:utf8', "$temp_dir/warnings");
  our $timeout;
  eval {
    local $SIG{ALRM} = sub { die "alarm\n" }; # NB: \n required
    alarm $timeout;

    my $offset = 0;
    while (<FILE>) {
      if ($. == 1) {
        unless ($disable_minified_file) {
          if ($file_size >= 512 && length($_) == $file_size) {
            skip_file($temp_dir, "file is a single line file. (single-line-file)\n");
            last;
          }
        }
      }
      $_ = decode_utf8($_, FB_DEFAULT);
      if (/[\x{D800}-\x{DFFF}]/) {
        skip_file($temp_dir, "file contains a UTF-16 surrogate. This is not supported. (utf16-surrogate-file)\n");
        last;
      }
      s/\R$//;
      s/^\x{FEFF}// if $. == 1;
      next unless /./;
      my $raw_line = $_;

      # hook for custom line based text exclusions:
      if (defined $patterns_re) {
        s/($patterns_re)/"="x length($1)/ge;
      }
      my $previous_line_state = $_;
      my $line_flagged;
      if ($forbidden_re) {
        while (s/($forbidden_re)/"="x length($1)/e) {
          $line_flagged = 1;
          my ($begin, $end, $match) = ($-[0] + 1, $+[0] + 1, $1);
          my $found_trigger_re;
          for my $i (0 .. $#forbidden_re_list) {
            my $forbidden_re_singleton = $forbidden_re_list[$i];
            my $test_line = $previous_line_state;
            if ($test_line =~ s/($forbidden_re_singleton)/"="x length($1)/e) {
              next unless $test_line eq $_;
              my ($begin_test, $end_test, $match_test) = ($-[0] + 1, $+[0] + 1, $1);
              next unless $begin == $begin_test;
              next unless $end == $end_test;
              next unless $match eq $match_test;
              $found_trigger_re = $forbidden_re_singleton;
              my $hit = "$.:$begin:$end";
              $forbidden_re_hits[$i]++;
              $forbidden_re_lines[$i] = $hit unless $forbidden_re_lines[$i];
              last;
            }
          }
          my $wrapped = CheckSpelling::Util::wrap_in_backticks($match);
          if ($found_trigger_re) {
            $found_trigger_re =~ s/^\(\?:(.*)\)$/$1/;
            my $quoted_trigger_re = CheckSpelling::Util::wrap_in_backticks($found_trigger_re);
            print WARNINGS ":$.:$begin ... $end, Warning - $wrapped matches a line_forbidden.patterns entry: $quoted_trigger_re. (forbidden-pattern)\n";
          } else {
            print WARNINGS ":$.:$begin ... $end, Warning - $wrapped matches a line_forbidden.patterns entry. (forbidden-pattern)\n";
          }
          $previous_line_state = $_;
        }
      }
      # This is to make it easier to deal w/ rules:
      s/^/ /;
      my %unrecognized_line_items = ();
      my ($new_words, $new_unrecognized) = split_line($_, \%unique, \%unique_unrecognized, \%unrecognized_line_items);
      $words += $new_words;
      $unrecognized += $new_unrecognized;
      my $line_length = length($raw_line);
      for my $token (sort CheckSpelling::Util::case_biased keys %unrecognized_line_items) {
        my $found_token = 0;
        my $raw_token = $token;
        $token =~ s/'/(?:'|\x{2019}|\&apos;|\&#39;)+/g;
        my $before;
        if ($token =~ /^$upper_pattern$lower_pattern/) {
          $before = '(?<=.)';
        } elsif ($token =~ /^$upper_pattern/) {
          $before = "(?<!$upper_pattern)";
        } else {
          $before = "(?<=$not_lower_pattern)";
        }
        my $after = ($token =~ /$upper_pattern$/) ? "(?=$not_upper_or_lower_pattern)|(?=$upper_pattern$lower_pattern)" : "(?=$not_lower_pattern)";
        while ($raw_line =~ /(?:\b|$before)($token)(?:\b|$after)/g) {
          $line_flagged = 1;
          $found_token = 1;
          my ($begin, $end, $match) = ($-[0] + 1, $+[0] + 1, $1);
          next unless $match =~ /./;
          my $wrapped = CheckSpelling::Util::wrap_in_backticks($match);
          print WARNINGS ":$.:$begin ... $end: $wrapped\n";
        }
        unless ($found_token) {
          if ($raw_line !~ /$token.*$token/ && $raw_line =~ /($token)/) {
            my ($begin, $end, $match) = ($-[0] + 1, $+[0] + 1, $1);
            my $wrapped = CheckSpelling::Util::wrap_in_backticks($raw_token);
            print WARNINGS ":$.:$begin ... $end: $wrapped\n";
          } else {
            my $offset = $line_length + 1;
            my $wrapped = CheckSpelling::Util::wrap_in_backticks($raw_token);
            print WARNINGS ":$.:1 ... $offset, Warning - Could not identify whole word $wrapped in line. (token-is-substring)\n";
          }
        }
      }
      if ($line_flagged && $candidates_re) {
        $_ = $previous_line_state;
        s/($candidates_re)/"="x length($1)/ge;
        if ($_ ne $previous_line_state) {
          $_ = $previous_line_state;
          for my $i (0 .. $#candidates_re_list) {
            my $candidate_re = $candidates_re_list[$i];
            next unless $candidate_re =~ /./ && $raw_line =~ /$candidate_re/;
            if (($_ =~ s/($candidate_re)/"="x length($1)/e)) {
              my ($begin, $end) = ($-[0] + 1, $+[0] + 1);
              my $hit = "$.:$begin:$end";
              $_ = $previous_line_state;
              my $replacements = ($_ =~ s/($candidate_re)/"="x length($1)/ge);
              $candidates_re_hits[$i] += $replacements;
              $candidates_re_lines[$i] = $hit unless $candidates_re_lines[$i];
              $_ = $previous_line_state;
            }
          }
        }
      }
      unless ($disable_minified_file) {
        s/={3,}//g;
        $offset += length;
        my $ratio = int($offset / $.);
        my $ratio_threshold = 1000;
        if ($ratio > $ratio_threshold) {
          skip_file($temp_dir, "average line width ($ratio) exceeds the threshold ($ratio_threshold). (minified-file)\n");
        }
      }
    }

    alarm 0;
  };
  if ($@) {
    die unless $@ eq "alarm\n";
    print WARNINGS ":$.:1 ... 1, Warning - Could not parse file within time limit. (slow-file)\n";
    skip_file($temp_dir, "could not parse file within time limit. (slow-file)\n");
  }

  close FILE;
  close WARNINGS;

  if ($unrecognized || @candidates_re_hits || @forbidden_re_hits) {
    open(STATS, '>:utf8', "$temp_dir/stats");
      print STATS "{words: $words, unrecognized: $unrecognized, unknown: ".(keys %unique_unrecognized).
      ", unique: ".(keys %unique).
      (@candidates_re_hits ? ", candidates: [".(join ',', @candidates_re_hits)."]" : "").
      (@candidates_re_lines ? ", candidate_lines: [".(join ',', @candidates_re_lines)."]" : "").
      (@forbidden_re_hits ? ", forbidden: [".(join ',', @forbidden_re_hits)."]" : "").
      (@forbidden_re_lines ? ", forbidden_lines: [".(join ',', @forbidden_re_lines)."]" : "").
      "}";
    close STATS;
    open(UNKNOWN, '>:utf8', "$temp_dir/unknown");
      print UNKNOWN map { "$_\n" } sort CheckSpelling::Util::case_biased keys %unique_unrecognized;
    close UNKNOWN;
  }

  return $temp_dir;
}

sub main {
  my ($configuration, @ARGV) = @_;
  our %dictionary;
  unless (%dictionary) {
    init($configuration);
  }

  # read all input
  my @reports;

  for my $file (@ARGV) {
    my $temp_dir = split_file($file);
    push @reports, "$temp_dir\n";
  }
  print join '', @reports;
}

1;
