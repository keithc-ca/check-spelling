#!/usr/bin/env -S perl -T -w -Ilib

use strict;
use warnings;

use File::Basename;
use File::Temp qw/ tempfile /;
use Test::More;
use CheckSpelling::Util;

plan tests => 4;
use_ok('CheckSpelling::SuggestExcludes');

my $tests = dirname(__FILE__);
my $base = dirname($tests);

my ($fh, $list) = tempfile();
my @files = qw(
  test/.keep
  case/.keep
  case/README.md
  case/ignore
  README.md
  a/test/case
  a/q.go
  a/ignore
  b/test/file
  gamma-delta/go.md
  gamma-delta/README.md
  case
  Ignore.md
  flour/wine
  flour/grapes
  flour/meal
  flour/wheat
  flour/eggs
  flour/cream
  flour/rice
  flour/meat
  flour/flour/pie
  new/wine
  new/grapes
  new/meal
  new/wheat
  new/eggs
  new/cream
  new/rice
  new/meat
  new/pie
);
print $fh CheckSpelling::Util::list_with_terminator "\0", @files;
close $fh;

my $excludes_file;
($fh, $excludes_file) = tempfile();
my @excludes = qw (
  a/ignore
  test/.keep
  case/.keep
  gamma-delta/go.md
  case/ignore
  Ignore.me.md
  flour/wine
  flour/grapes
  flour/meal
  flour/wheat
  flour/eggs
  flour/cream
  flour/rice
  flour/meat
  ignored
);
print $fh CheckSpelling::Util::list_with_terminator "\n", @excludes;
close $fh;

my $old_excludes_file;
($fh, $old_excludes_file) = tempfile();
my @old_excludes = qw <
  ^test\.keep$
  ^\Qtest(0)a\E$
>;
print $fh CheckSpelling::Util::list_with_terminator "\n", @old_excludes;
close $fh;

my @expected_results = qw(
(?:^|/)\.keep$
^gamma-delta/go\.md$
^\QIgnore.me.md\E$
(?:^|/)ignore$
^ignored$
);
push @expected_results, '(?:|$^ 88% - excluded 8/9)^flour/';
@expected_results = sort CheckSpelling::Util::case_biased @expected_results;

my @expect_drop_patterns = qw(
^test\.keep$
^\Qtest(0)a\E$
);
@expect_drop_patterns = sort CheckSpelling::Util::case_biased @expect_drop_patterns;

my ($results_ref, $drop_ref) = CheckSpelling::SuggestExcludes::main($list, $excludes_file, $old_excludes_file);
my @results = @{$results_ref};
my @drop_patterns = sort CheckSpelling::Util::case_biased @{$drop_ref};
@results = sort CheckSpelling::Util::case_biased @results;
is(CheckSpelling::Util::list_with_terminator("\n", @results),
CheckSpelling::Util::list_with_terminator("\n", @expected_results));
is(CheckSpelling::Util::list_with_terminator("\n", @drop_patterns),
CheckSpelling::Util::list_with_terminator("\n", @expect_drop_patterns));

is(CheckSpelling::SuggestExcludes::path_to_pattern('a'), '^\Qa\E$');
