#! -*-perl-*-
package CheckSpelling::SummaryTables;

use Cwd 'abs_path';
use File::Basename;
use File::Temp qw/ tempfile tempdir /;
use JSON::PP;
use CheckSpelling::Util;

unless (eval 'use URI::Escape; 1') {
    eval 'use URI::Escape::XS qw/uri_escape/';
}

my %git_roots = ();
my %github_urls = ();
my $pull_base;
my $pull_head;

sub github_repo {
    my ($source) = @_;
    $source =~ s<https://[^/]+/|.*:><>;
    $source =~ s<\.git$><>;
    return '' unless $source =~ m#^[^/]+/[^/]+$#;
    return $source;
}

sub file_ref {
    my ($file, $line) = @_;
    $file =~ s/ /%20/g;
    return "$file:$line";
}

sub find_git {
    our $git_dir;
    return $git_dir if defined $git_dir;
    if ($ENV{PATH} =~ /(.*)/) {
        my $path = $1;
        for my $maybe_git (split /:/, $path) {
            if (-x "$maybe_git/git") {
                $git_dir = $maybe_git;
                return $git_dir;
            }
        }
    }
}

sub github_blame {
    my ($file, $line) = @_;
    our (%git_roots, %github_urls, $pull_base, $pull_head);

    return file_ref($file, $line) if ($file =~ m{^https?://});

    my $last_git_dir;
    my $dir = $file;
    my @children;
    while ($dir ne '.' && $dir ne '/') {
        my $child = basename($dir);
        push @children, $child;
        my $parent = dirname($dir);
        last if $dir eq $parent;
        $dir = $parent;
        last if defined $git_roots{$dir};
        my $git_dir = "$dir/.git";
        if (-e $git_dir) {
            if (-d $git_dir) {
                $git_roots{$dir} = $git_dir;
                last;
            }
            if (-s $git_dir) {
                open $git_dir_file, '<', $git_dir;
                my $git_dir_path = <$git_dir_file>;
                close $git_dir_file;
                if ($git_dir_path =~ /^gitdir: (.*)$/) {
                    $git_roots{$dir} = abs_path("$dir/$1");
                }
            }
        }
    }
    $last_git_dir = $git_roots{$dir};
    my $length = scalar @children - 1;
    for (my $i = 0; $i < $length; $i++) {
        $dir .= "/$children[$i]";
        $git_roots{$dir} = $last_git_dir;
    }

    return file_ref($file, $line) unless defined $last_git_dir;
    $file = join '/', (reverse @children);

    my $prefix = '';
    my $line_delimiter = ':';
    if (defined $github_urls{$last_git_dir}) {
        $prefix = $github_urls{$last_git_dir};
    } else {
        my $full_path = $ENV{PATH};
        $ENV{PATH} = find_git();
        my $git_dir = $ENV{GIT_DIR};
        $ENV{GIT_DIR} = $last_git_dir;
        my $git_remotes = `git remote`;
        my @remotes = split /\n/, $git_remotes;
        my $origin;
        if (grep { /^origin$/ } @remotes) {
            $origin = 'origin';
        } elsif (@remotes) {
            $origin = $remotes[0];
        }
        my $remote_url;
        my $rev;
        if ($origin) {
            $remote_url = `git remote get-url "$origin" 2>/dev/null`;
            chomp $remote_url;
            $rev = `git rev-parse HEAD 2>/dev/null`;
            chomp $rev;
            my $private_synthetic_sha = $ENV{PRIVATE_SYNTHETIC_SHA};
            if (defined $private_synthetic_sha) {
                $rev = $ENV{PRIVATE_MERGE_SHA} if ($rev eq $private_synthetic_sha);
            }
        }
        $ENV{PATH} = $full_path;
        $ENV{GIT_DIR} = $git_dir;
        my $url_base;
        if ($remote_url && $remote_url ne '.') {
            unless ($remote_url =~ m<^https?://>) {
                $remote_url =~ s!.*\@([^:]+):!https://$1/!;
            }
            $remote_url =~ s!\.git$!!;
            $url_base = "$remote_url/blame";
        } elsif ($ENV{GITHUB_SERVER_URL} ne '' && $ENV{GITHUB_REPOSITORY} ne '') {
            $url_base = "$ENV{GITHUB_SERVER_URL}/$ENV{GITHUB_REPOSITORY}/blame";
            $rev = $ENV{GITHUB_HEAD_REF} || $ENV{GITHUB_SHA} unless $rev;
        }
        if ($url_base) {
            if ($pull_base) {
                $url_base =~ s<^$pull_base/><$pull_head/>i;
            }
            $prefix = "$url_base/$rev/";
        }
        if ($last_git_dir) {
            $github_urls{$last_git_dir} = $prefix;
        }
    }
    $line_delimiter = '#L' if $prefix =~ m<https?://>;

    $file = uri_escape($file, "^A-Za-z0-9\-\._~/");
    return "$prefix$file$line_delimiter$line";
}

sub main {
    my $budget = CheckSpelling::Util::get_val_from_env("summary_budget", "");
    print STDERR "Summary Tables budget: $budget\n";
    my $summary_tables = tempdir();
    my $table;
    my @tables;

    my $head_ref = CheckSpelling::Util::get_file_from_env('GITHUB_HEAD_REF', "");
    my $github_url = CheckSpelling::Util::get_file_from_env('GITHUB_SERVER_URL', "");
    my $github_repository = CheckSpelling::Util::get_file_from_env('GITHUB_REPOSITORY', "");
    my $event_file_path = CheckSpelling::Util::get_file_from_env('GITHUB_EVENT_PATH', "");
    if ($head_ref && $github_url && $github_repository && $event_file_path) {
        if (open $event_file_handle, '<', $event_file_path) {
            local $/;
            my $json = <$event_file_handle>;
            close $event_file_handle;
            my $data = decode_json($json);
            our $pull_base = "$github_url/$github_repository";
            our $pull_head = "$github_url/".$data->{'pull_request'}->{'head'}->{'repo'}->{'full_name'};
            unless ($pull_head && $pull_base && ($pull_base ne $pull_head)) {
                $pull_base = $pull_head = '';
            }
        }
    }

    while (<>) {
        next unless m{^(.+):(\d+):(\d+) \.\.\. (\d+),\s(Error|Warning|Notice)\s-\s(.+)\s\(([-a-z]+)\)$};
        my ($file, $line, $column, $endColumn, $severity, $message, $code) = ($1, $2, $3, $4, $5, $6, $7);
        my $table_file = "$summary_tables/$code";
        push @tables, $code unless -e $table_file;
        open $table, ">>", $table_file;
        $message =~ s/\|/\\|/g;
        my $blame = CheckSpelling::SummaryTables::github_blame($file, $line);
        print $table "$message | $blame\n";
        close $table;
    }
    return unless @tables;

    my ($details_prefix, $footer, $suffix, $need_suffix) = (
        "<details><summary>Details :mag_right:</summary>\n\n",
        "</details>\n\n",
        "\n</details>\n\n",
        0
    );
    my $footer_length = length $footer;
    if ($budget) {
        $budget -= (length $details_prefix) + (length $suffix);
        print STDERR "Summary Tables budget reduced to: $budget\n";
    }
    for $table_file (sort @tables) {
        my $header = "<details><summary>:open_file_folder: $table_file</summary>\n\n".
            "note|path\n".
            "-|-\n";
        my $header_length = length $header;
        my $file_path = "$summary_tables/$table_file";
        my $cost = $header_length + $footer_length + -s $file_path;
        if ($budget && ($budget < $cost)) {
            print STDERR "::warning title=summary-table::Details for '$table_file' too big to include in Step Summary. (summary-table-skipped)\n";
            next;
        }
        open $table, "<", $file_path;
        my @entries;
        my $real_cost = $header_length + $footer_length;
        foreach my $line (<$table>) {
            $real_cost += length $line;
            push @entries, $line;
        }
        close $table;
        if ($real_cost > $cost) {
            print STDERR "budget ($real_cost > $cost)\n";
            if ($budget && ($budget < $real_cost)) {
                print STDERR "::warning title=summary-tables::budget exceeded for $table_file (summary-table-skipped)\n";
                next;
            }
        }
        if ($details_prefix ne '') {
            print $details_prefix;
            $details_prefix = '';
            $need_suffix = 1;
        }
        print $header;
        print join ("", sort CheckSpelling::Util::case_biased @entries);
        print $footer;
        if ($budget) {
            $budget -= $cost;
            print STDERR "Summary Tables budget reduced to: $budget\n";
        }
    }
    print $suffix if $need_suffix;
}

1;
