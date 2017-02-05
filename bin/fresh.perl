#!/usr/bin/env perl

# TODO: remove this debug
# use Data::Dumper;
# print Dumper(\$entry);

use strict;
use warnings FATAL => 'all';

use Carp qw(croak);
use File::Temp qw(tempfile);
use Text::ParseWords qw(shellwords);
use Getopt::Long qw(GetOptionsFromArray :config posix_default permute no_ignore_case pass_through);
use File::Path qw(make_path remove_tree);
use File::Glob qw(bsd_glob);
use File::Basename qw(dirname basename);
use File::Find qw(find);
use Cwd qw(getcwd chdir realpath);
use POSIX qw(strftime);
use sort 'stable';

my $FRESH_RCFILE = $ENV{FRESH_RCFILE} ||= "$ENV{HOME}/.freshrc";
my $FRESH_PATH = $ENV{FRESH_PATH} ||= "$ENV{HOME}/.fresh";
my $FRESH_LOCAL = $ENV{FRESH_LOCAL} ||= "$ENV{HOME}/.dotfiles";
my $FRESH_BIN_PATH = $ENV{FRESH_BIN_PATH} ||= "$ENV{HOME}/bin";
my $FRESH_NO_LOCAL_CHECK = $ENV{FRESH_NO_LOCAL_CHECK} ||= 1;
my $FRESH_NO_PATH_EXPORT = $ENV{FRESH_NO_PATH_EXPORT};

sub read_freshrc {
  my ($script_fh, $script_filename) = tempfile('fresh.XXXXXX', TMPDIR => 1, UNLINK => 1);
  my ($output_fh, $output_filename) = tempfile('fresh.XXXXXX', TMPDIR => 1, UNLINK => 1);

  print $script_fh <<'SH';
  set -e

  _FRESH_RCFILE="$1"
  _FRESH_OUTPUT="$2"

  _output() {
    local RC_LINE _ RC_FILE
    read RC_LINE _ RC_FILE <<< "$(caller 1)"
    printf "%s %s" $RC_FILE $RC_LINE >> "$_FRESH_OUTPUT"
    for arg in "$@"; do
      printf " %q" "$arg" >> "$_FRESH_OUTPUT"
    done
    echo >> "$_FRESH_OUTPUT"
  }

  _env() {
    for NAME in "$@"; do
      if declare -p "$NAME" &> /dev/null; then
        _output env "$NAME" "$(eval "echo \"\$$NAME\"")"
      fi
    done
  }

  fresh() {
    _env FRESH_NO_BIN_CONFLICT_CHECK
    _output fresh "$@"
  }

  fresh-options() {
    _output fresh-options "$@"
  }

  if [ -e "$_FRESH_RCFILE" ]; then
    source "$_FRESH_RCFILE"
  fi
SH

  close $script_fh;

  system('bash', $script_filename, $FRESH_RCFILE, $output_filename) == 0 or exit(1);

  my @entries;
  my %default_options;
  my %env;

  while (my $line = <$output_fh>) {
    my @args = shellwords($line);

    my %entry = parse_fresh_dsl_args($line, @args);

    # use Data::Dumper;
    # print Dumper(\%entry);

    push @entries, \%entry;
  }
  close $output_fh;

  unlink $script_filename;
  unlink $output_filename;

  return @entries;
}

sub parse_fresh_dsl_args {
  my ($line, @args) = @_;

  my %default_options;
  my %env;
  # print "x\n";
  # use Data::Dumper;
  # print Dumper(\@args);

  # my %entry;

  # indent
    (my $clean_line = $line) =~ s/^.* fresh /fresh /;
    # chomp($clean_line);
    my %entry = (
      file => shift(@args),
      line => shift(@args),
      freshrc_line => $clean_line,
    );
    my $cmd = shift(@args);

    for my $arg (@args) {
      if ($arg eq '--marker=') {
        entry_error(\%entry, "Marker not specified.");
      }
    }

    my %options = ();
    GetOptionsFromArray(\@args, \%options, 'marker:s', 'file:s', 'bin:s', 'ref:s', 'filter:s', 'ignore-missing') or croak "Parse error at $entry{file}:$entry{line}\n";

    if (defined($options{marker}) && !defined($options{file})) {
      entry_error(\%entry, "--marker is only valid with --file.");
    }

    if (defined($options{ref}) && $options{ref} eq "") {
      entry_error(\%entry, "You must specify a Git reference.");
    }

    if (defined($options{filter}) && $options{filter} eq "") {
      entry_error(\%entry, "You must specify a filter program.");
    }

    if (defined($options{file}) && defined($options{bin})) {
      entry_error(\%entry, "Cannot have more than one mode.");
    }

    if ($cmd eq 'fresh') {
      for my $arg (@args) {
        if ($arg =~ /^--/) {
          entry_error(\%entry, "Unknown option: $arg");
        }
      }
      if (@args == 0) {
        entry_error(\%entry, "Filename is required");
      } elsif (@args == 1) {
        $entry{name} = $args[0];
      } elsif (@args == 2) {
        $entry{repo} = $args[0];
        $entry{name} = $args[1];
      } else {
        entry_error(\%entry, "Expected 1 or 2 args.");
      }
      $entry{options} = {%default_options, %options};
      $entry{env} = {%env};
      undef %env;
      # push @entries, \%entry;
      # return \%entry;
    } elsif ($cmd eq 'fresh-options') {
      croak "fresh-options cannot have args" unless (@args == 0);
      %default_options = %options;
    } elsif ($cmd eq 'env') {
      croak 'expected env to have 2 args' unless @args == 2;
      $env{$args[0]} = $args[1];
    } else {
      croak "Unknown command: $cmd";
    }

    # use Data::Dumper;
    # print Dumper(\%entry);

    if (defined($entry{name}) && $entry{name} eq ".") {
      if (defined($options{file}) && $options{file} !~ /\/$/) {
        entry_error(\%entry, "Whole repositories require destination to be a directory.");
      }

      if (!defined($options{file})) {
        entry_error(\%entry, "Whole repositories can only be sourced in file mode.");
      }
    }
  return %entry;
}

sub apply_filter {
  my ($input, $cmd) = @_;

  my ($script_fh, $script_filename) = tempfile('fresh.XXXXXX', TMPDIR => 1, UNLINK => 1);
  my ($input_fh, $input_filename) = tempfile('fresh.XXXXXX', TMPDIR => 1, UNLINK => 1);
  my ($output_fh, $output_filename) = tempfile('fresh.XXXXXX', TMPDIR => 1, UNLINK => 1);

  print $script_fh <<'SH';
  set -euo pipefail

  _FRESH_RCFILE="$1"
  _FRESH_INPUT="$2"
  _FRESH_OUTPUT="$3"
  _FRESH_FILTER="$4"

  fresh() {
    true
  }

  fresh-options() {
    true
  }

  source "$_FRESH_RCFILE"
  cat "$_FRESH_INPUT" | eval "$_FRESH_FILTER" > "$_FRESH_OUTPUT"
SH
  close $script_fh;

  print $input_fh $input;
  close $input_fh;

  system('bash', $script_filename, $FRESH_RCFILE, $input_filename, $output_filename, $cmd) == 0 or croak 'filter failed';

  local $/ = undef;
  my $output = <$output_fh>;
  close $output_fh;

  unlink $script_filename;
  unlink $input_filename;
  unlink $output_filename;

  return $output;
}

sub append {
  my ($filename, $data) = @_;
  make_path(dirname($filename));
  open(my $fh, '>>', $filename) or croak "$!: $filename";
  print $fh $data;
  close $fh;
}

sub print_and_append {
  my ($filename, $data) = @_;
  print $data;
  append $filename, $data;
}

sub readfile {
  my ($filename) = @_;
  if (open(my $fh, $filename)) {
    local $/ = undef;
    my $data = <$fh>;
    close $fh;
    return $data;
  }
}

sub read_file_line {
  my ($filename, $line_no) = @_;
  if (open(my $fh, $filename)) {
    my $line;
    while (<$fh>) {
      if ($. == $line_no) {
        $line = $_;
        last;
      }
    }
    close $fh;
    return $line;
  }
}

sub read_cmd {
  my @args = @_;

  open(my $fh, '-|', @args) or croak "$!: @args";
  local $/ = undef;
  my $output = <$fh>;
  close($fh);
  $? == 0 or exit 1;

  return $output;
}

sub read_cwd_cmd {
  my $cwd = shift;
  my @args = @_;

  $cwd =~ s/(?!^)\/+$//;
  my $old_cwd = getcwd();
  chdir($cwd) or croak "$!: $cwd";

  open(my $fh, '-|', @args) or croak "$!: @args";
  local $/ = undef;
  my $output = <$fh>;
  close($fh);
  $? == 0 or exit 1;

  chdir($old_cwd) or croak "$!: $old_cwd";

  return $output;
}

sub read_cwd_cmd_no_check_exit {
  my $cwd = shift;
  my @args = @_;

  $cwd =~ s/(?!^)\/+$//;
  my $old_cwd = getcwd();
  chdir($cwd) or croak "$!: $cwd";

  open(my $fh, '-|', @args) or croak "$!: @args";
  local $/ = undef;
  my $output = <$fh>;
  close($fh);

  chdir($old_cwd) or croak "$!: $old_cwd";

  return $output;
}

sub format_url {
  my ($url) = @_;
  "\033[4;34m$url\033[0m"
}

sub note {
  my ($msg) = @_;

  print "\033[1;33mNote\033[0m: $msg\n";
}

sub entry_note {
  my ($entry, $msg, $desc) = @_;

  my $content = read_file_line($$entry{file}, $$entry{line});

  print STDOUT <<EOF;
\033[1;33mNote\033[0m: $msg
$$entry{file}:$$entry{line}: $content
$desc
EOF
}

sub entry_error {
  my ($entry, $msg, $options) = @_;

  my $content = read_file_line($$entry{file}, $$entry{line});
  chomp($content);

  my $file = $$entry{file};
  $file =~ s{^\Q$ENV{HOME}\E}{~};

  print STDERR <<EOF;
\033[4;31mError\033[0m: $msg
$file:$$entry{line}: $content
EOF
  if (!$$options{skip_info}) {
    print STDERR <<EOF;

You may need to run `fresh update` if you're adding a new line,
or the file you're referencing may have moved or been deleted.
EOF
  }
  if ($$entry{repo}) {
    my $url = repo_url($$entry{repo});
    my $formatted_url = format_url($url);
    print STDERR "Have a look at the repo: <$formatted_url>\n";
  }
  exit 1;
}

sub fatal_error {
  my ($msg, $content) = @_;
  $content ||= "";
  chomp($msg);
  print STDERR "\033[4;31mError\033[0m: $msg\n$content";
  exit 1;
}

sub glob_filter {
  my $glob = shift;
  my @paths = @_;

  my ($script_fh, $script_filename) = tempfile('fresh.XXXXXX', TMPDIR => 1, UNLINK => 1);
  my ($output_fh, $output_filename) = tempfile('fresh.XXXXXX', TMPDIR => 1, UNLINK => 1);

  print $script_fh <<'SH';
  set -euo pipefail
  IFS=$'\n'

  GLOB="$1"
  OUTPUT_FILE="$2"

  while read LINE; do
    if [[ "$LINE" == $GLOB ]]; then
      if ! echo "${LINE#$GLOB}" | grep -q /; then
        echo "$LINE"
      fi
    fi
  done > "$OUTPUT_FILE"
SH

  close $script_fh;

  open(my $input_fh, '|-', 'bash', $script_filename, $glob, $output_filename) or croak "$!";

  foreach my $path (@paths) {
    print $input_fh "$path\n";
  }

  close $input_fh;
  $? == 0 or croak 'filter call failed';

  my @matches;

  while (my $line = <$output_fh>) {
    chomp($line);
    if (basename($line) !~ /^\./ || basename($glob) =~ /^\./) {
      push(@matches, $line);
    }
  }

  close $output_fh;

  unlink $script_filename;
  unlink $output_filename;

  return @matches;
}

sub prefix_filter {
  my $prefix = shift;
  my @paths = @_;
  my @matches;

  foreach my $path (@paths) {
    if (substr($path, 0, length($prefix)) eq $prefix) {
      push(@matches, $path);
    }
  }

  @matches;
}

sub remove_prefix {
  my ($str, $prefix) = @_;
  if (substr($str, 0, length($prefix)) eq $prefix) {
    $str = substr($str, length($prefix));
  }
  return $str;
}

sub prefix_match {
  my ($str, $prefix) = @_;
  substr($str, 0, length($prefix)) eq $prefix;
}

sub make_entry_link {
  my ($entry, $link_path, $link_target) = @_;
  my $existing_target = readlink($link_path);

  if (is_relative_path($link_path)) {
    if ($link_path =~ /^\.\./) {
      entry_error $entry, "Relative paths must be inside build dir.";
    }
    return
  }

  if (defined($existing_target)) {
    if ($existing_target ne $link_target) {
      if (prefix_match($existing_target, "$FRESH_PATH/build/") && -l $link_path) {
        unlink($link_path);
        symlink($link_target, $link_path);
      } else {
        entry_error $entry, "$link_path already exists (pointing to $existing_target)."; # TODO: this should skip info
      }
    }
  } elsif (-e $link_path) {
    entry_error $entry, "$link_path already exists.", {skip_info => 1};
  } else {
    make_path(dirname($link_path), {error => \my $err});
    if (@$err || !symlink($link_target, $link_path)) {
      entry_error $entry, "Could not create $link_path. Do you have permission?", {skip_info => 1};
    }
  }
}

sub is_relative_path {
  my ($path) = @_;
  $path !~ /^[~\/]/
}

sub repo_url {
  my ($repo) = @_;
  if ($repo =~ /:/) {
    $repo
  } else {
    "https://github.com/$repo"
  }
}

sub repo_name {
  my ($repo) = @_;

  if ($repo =~ /:/) {
    $repo =~ s/^.*@//;
    $repo =~ s/^.*:\/\///;
    $repo =~ s/:/\//;
    $repo =~ s/\.git$//;
  }

  if ($repo =~ /github.com\//) {
    $repo =~ s/^github\.com\///;
    $repo
  } else {
    my @parts = split(/\//, $repo);
    my $end = join('-', @parts[1..$#parts]);
    "$parts[0]/$end"
  }
}

sub repo_name_from_source_path {
  my ($path) = @_;
  my @parts = split(/\//, $path);
  join('/', @parts[-2..-1]);
}

sub get_entry_prefix {
  my ($entry) = @_;

  my $prefix;
  if ($$entry{repo}) {
    # TODO: Not sure if we need $repo_dir as the only difference from $prefix
    # is the trailing slash. I don't want to change the specs though.
    my $repo_name = repo_name($$entry{repo});
    my $repo_dir = "$FRESH_PATH/source/$repo_name";

    if (-d "$FRESH_LOCAL/.git" && $FRESH_NO_LOCAL_CHECK) {
      my $old_cwd = getcwd();
      chdir($FRESH_LOCAL) or croak "$!: $FRESH_LOCAL";
      my $upstream_branch = `git rev-parse --abbrev-ref --symbolic-full-name \@{u} 2> /dev/null`;
      chdir($old_cwd) or croak "$!: $old_cwd";

      my @parts = split(/\//, $upstream_branch);
      my $upstream_remote = $parts[0];

      if (defined($upstream_remote)) {
        my $local_repo_url = read_cwd_cmd($FRESH_LOCAL, "git", "config", "--get", "remote.$upstream_remote.url");
        chomp($local_repo_url);

        my $local_repo_name = repo_name($local_repo_url);
        my $source_repo_name = repo_name($$entry{repo});

        if ($local_repo_name eq $source_repo_name) {
          entry_note $entry, "You seem to be sourcing your local files remotely.", <<EOF;
You can remove "$$entry{repo}" when sourcing from your local dotfiles repo (${FRESH_LOCAL}).
Use `fresh file` instead of `fresh $$entry{repo} file`.

To disable this warning, add `FRESH_NO_LOCAL_CHECK=true` in your freshrc file.
EOF
          $FRESH_NO_LOCAL_CHECK = 0;
        }
      }
    }

    make_path dirname($repo_dir);

    if (! -d $repo_dir) {
      system('git', 'clone', repo_url($$entry{repo}), $repo_dir) == 0 or croak 'git clone failed';
    }

    $prefix = "$repo_dir/";
  } else {
    $prefix = "$FRESH_LOCAL/";
    # use Data::Dumper;
    # print Dumper(\$entry);
    if ($$entry{name} eq ".") {
      fatal_error("Cannot source whole of local dotfiles.");
    }
  }

  return $prefix;
}

sub get_entry_paths {
  my ($entry, $prefix) = @_;

  my @paths;

  # TODO: Should we DRY these up?
  my $is_dir_target = defined($$entry{options}{file}) && $$entry{options}{file} =~ /\/$/;
  my $is_external_target = defined($$entry{options}{file}) && $$entry{options}{file} =~ /^[\/~]/;

  my $full_entry_name = "$prefix$$entry{name}";
  my $base_entry_name = dirname($full_entry_name);

  if ($$entry{options}{ref}) {
    $base_entry_name = dirname($$entry{name});
    @paths = split(/\n/, read_cwd_cmd($prefix, 'git', 'ls-tree', '-r', '--name-only', $$entry{options}{ref}));
    if ($is_dir_target) {
      if ($$entry{name} ne ".") {
        @paths = prefix_filter("$$entry{name}/", @paths);
      }
    } else {
      @paths = glob_filter("$$entry{name}", @paths);
    }
  } elsif ($is_dir_target) {
    my $wanted = sub {
      if ($$entry{name} eq ".") {
        if (!prefix_match($_, "$full_entry_name/.git")) {
          push @paths, $_;
        }
      } else {
        push @paths, $_;
      }
    };
    find({wanted => $wanted, no_chdir => 1}, $full_entry_name);
  } else {
    @paths = bsd_glob($full_entry_name);
  }

  my $fresh_order_data;
  if ($$entry{options}{ref}) {
    if ($$entry{name} =~ /\*/) {
      my $dir = dirname($$entry{name});
      $fresh_order_data = read_cwd_cmd($prefix, 'git', 'show', "$$entry{options}{ref}:$dir/.fresh-order");
    }
  } else {
    $fresh_order_data = readfile($base_entry_name . '/.fresh-order');
  }

  @paths = sort @paths;

  if ($fresh_order_data) {
    my @order_lines = map { "$base_entry_name/$_" } split(/\n/, $fresh_order_data);
    my $path_index = sub {
      my ($path) = @_;
      my ($index) = grep { $order_lines[$_] eq $path } 0..$#order_lines;
      $index = 1e6 unless defined($index);
      $index;
    };
    @paths = sort {
      $path_index->($a) <=> $path_index->($b);
    } @paths;
  }

  @paths = grep { basename($_) ne '.fresh-order' } @paths;

  return @paths;
}

sub marker {
  my ($entry, $name) = @_;
  my $marker;

  if (!defined($$entry{options}{file}) && !defined($$entry{options}{bin})) {
    $marker = '#';
  }

  if (defined($$entry{options}{marker})) {
    $marker = $$entry{options}{marker} || '#';
  }

  if (defined($marker)) {
    $marker .= " fresh:";
    if ($$entry{repo}) {
      $marker .= " $$entry{repo}";
    }
    $marker .= " $name";
    if ($$entry{options}{ref}) {
      $marker .= " @ $$entry{options}{ref}";
    }
    my $filter = $$entry{options}{filter};
    if ($filter) {
      $marker .= " # $filter";
    }
  }

  return $marker;
}

sub file_contents {
  my ($entry, $prefix, $path) = @_;
  my $data;

  if ($$entry{options}{ref}) {
    $data = read_cwd_cmd($prefix, 'git', 'show', "$$entry{options}{ref}:$path");
  } else {
    $data = readfile($path);
  }

  if (defined $data) {
    my $filter = $$entry{options}{filter};
    if ($filter) {
      $data = apply_filter($data, $filter);
    }
  }

  return $data;
}

sub fresh_install {
  umask 0077;
  remove_tree "$FRESH_PATH/build.new";
  make_path "$FRESH_PATH/build.new";

  if (!defined($FRESH_NO_PATH_EXPORT)) {
    append "$FRESH_PATH/build.new/shell.sh", '__FRESH_BIN_PATH__=$HOME/bin; [[ ! $PATH =~ (^|:)$__FRESH_BIN_PATH__(:|$) ]] && export PATH="$__FRESH_BIN_PATH__:$PATH"; unset __FRESH_BIN_PATH__' . "\n";
  }
  append "$FRESH_PATH/build.new/shell.sh", "export FRESH_PATH=\"$FRESH_PATH\"\n";

  for my $entry (read_freshrc()) {
    my $prefix = get_entry_prefix($entry);

    my @paths = get_entry_paths($entry, $prefix);

    my $is_dir_target = defined($$entry{options}{file}) && $$entry{options}{file} =~ /\/$/;
    my $is_external_target = defined($$entry{options}{file}) && $$entry{options}{file} =~ /^[\/~]/;

    my $matched = 0;

    for my $path (@paths) {
      my $name = remove_prefix($path, $prefix);

      my ($build_name, $link_path);

      if (defined($$entry{options}{file})) {
        $link_path = $$entry{options}{file} || '~/.' . (basename($name) =~ s/^\.//r);
        $link_path =~ s{^~/}{$ENV{HOME}/};
        $build_name = remove_prefix($link_path, $ENV{HOME}) =~ s/^\///r =~ s/^\.//r;
        if ($is_external_target) {
          $build_name = $build_name =~ s/(?<!^~)[\/ ()]+/-/gr =~ s/-$//r;
        }
        if ($is_dir_target) {
          if ($$entry{name} eq ".") {
            $build_name .= "/";
          }
          $build_name .= remove_prefix($name, $$entry{name});
        }
      } elsif (defined($$entry{options}{bin})) {
        $link_path = $$entry{options}{bin} || '~/bin/' . basename($name);
        $link_path =~ s{^~/}{$ENV{HOME}/};
        if ($link_path !~ /^\//) {
          entry_error $entry, '--bin file paths cannot be relative.';
        }
        $build_name = 'bin/' . basename($link_path);
      } else {
        $build_name = "shell.sh";
      }

      my $build_target = "$FRESH_PATH/build.new/$build_name";
      my $data = file_contents($entry, $prefix, $path);

      if (defined $data) {
        $matched = 1;

        if (!defined($$entry{env}{FRESH_NO_BIN_CONFLICT_CHECK}) || $$entry{env}{FRESH_NO_BIN_CONFLICT_CHECK} ne 'true') {
          if (defined($$entry{options}{bin}) && -e $build_target) {
            entry_note $entry, "Multiple sources concatenated into a single bin file.", <<EOF;
Typically bin files should not be concatenated together into one file.
"$build_name" may not function as expected.

To disable this warning, add `FRESH_NO_BIN_CONFLICT_CHECK=true` in your freshrc file.
EOF
          }
        }

        my $marker = marker($entry, $name);
        if (defined($marker)) {
          append $build_target, "\n" if -e $build_target;
          append $build_target, "$marker\n\n"
        }
        append $build_target, $data;

        if (defined($$entry{options}{bin})) {
          chmod 0700, $build_target;
        }

        if (defined($link_path) && !$is_dir_target) {
          make_entry_link($entry, $link_path, "$FRESH_PATH/build/$build_name");
        }
      }
    }
    unless ($matched) {
      unless ($$entry{options}{'ignore-missing'}) {
        entry_error $entry, "Could not find \"$$entry{name}\" source file.";
      }
    }

    if ($is_dir_target && $is_external_target) {
      # TODO: can this be DRYed up with `$link_path = …`, etc` above?
      # rspec spec/fresh_spec.rb -e 'local files in nested'
      my $link_path = $$entry{options}{file} =~ s{^~/}{$ENV{HOME}/}r =~ s{/$}{}r;
      my $build_name = $$entry{options}{file} =~ s/(?<!^~)[\/ ()]+/-/gr =~ s/-$//r;
      $build_name = remove_prefix($build_name =~ s{^~/}{$ENV{HOME}/}r, $ENV{HOME}) =~ s/^\///r =~ s/^\.//r;
      make_entry_link($entry, $link_path, "$FRESH_PATH/build/$build_name");
    }
  }

  if (!defined($ENV{FRESH_NO_BIN_CHECK}) && !(-x "$FRESH_PATH/build.new/bin/fresh")) {
    fatal_error <<EOF;
It looks you do not have fresh in your freshrc file. This could result
in difficulties running `fresh` later. You probably want to add a line like
the following using `fresh edit`:

  fresh freshshell/fresh bin/fresh --bin

To disable this error, add `FRESH_NO_BIN_CHECK=true` in your freshrc file.
EOF
  }

  system(qw(find), "$FRESH_PATH/build.new", qw(-type f -exec chmod -w {} ;)) == 0 or croak 'chmod failed';

  remove_tree "$FRESH_PATH/build.old";
  rename "$FRESH_PATH/build", "$FRESH_PATH/build.old";
  rename "$FRESH_PATH/build.new", "$FRESH_PATH/build";
  remove_tree "$FRESH_PATH/build.old";

  print "Your dot files are now \033[1;32mfresh\033[0m.\n"
}

sub fresh_install_with_latest_binary {
  my ($fresh_bin_fh, $fresh_bin_filename);

  for my $entry (read_freshrc()) {
    my $prefix = get_entry_prefix($entry);
    my @paths = get_entry_paths($entry, $prefix);

    foreach my $path (@paths) {
      if (defined($$entry{options}{bin}) && basename($path) eq "fresh") {
        ($fresh_bin_fh, $fresh_bin_filename) = tempfile('fresh.XXXXXX', TMPDIR => 1, UNLINK => 1);
        print $fresh_bin_fh file_contents($entry, $prefix, $path);
        close $fresh_bin_fh;
        last;
      }
    }

    if (defined($fresh_bin_filename)) {
      last;
    }
  }

  if (defined($fresh_bin_filename)) {
    chmod 0700, $fresh_bin_filename;
    system($fresh_bin_filename);
    unlink $fresh_bin_filename;
  } else {
    fresh_install;
  }
}

sub update_repo {
  my ($path, $repo_display_name, $log_file) = @_;

  print_and_append $log_file, "* Updating $repo_display_name\n";
  my $git_log = read_cwd_cmd_no_check_exit($path, 'git', 'pull', '--rebase');

  (my $pretty_git_log = $git_log) =~ s/^/| /gm;
  print_and_append $log_file, "$pretty_git_log";

  if ($git_log =~ /^From .*(:\/\/github.com\/|git\@github.com:)(.*)/) {
    my $repo_name = $2;
    $git_log =~ /^ {2,}([0-9a-f]{7,})\.\.([0-9a-f]{7,}) /gm;
    if (defined($1) && defined($2)) {
      my $compare_url =  format_url("https://github.com/$repo_name/compare/$1...$2");
      print_and_append $log_file, "| <$compare_url>\n";
    }
  }

  $? == 0 or exit(1);
}

sub fresh_update {
  if (0 + @_ > 1) {
    fatal_error "Invalid arguments.", <<EOF;

usage: fresh update <filter>

    The filter can be either a GitHub username or username/repo.
EOF
  }


  make_path "$FRESH_PATH/logs";
  my $date = strftime('%Y-%m-%d-%H%M%S', localtime);
  my $log_file = "$FRESH_PATH/logs/update-$date.log";

  my ($filter) = @_;

  if ((!defined($filter) || $filter eq "--local") && -d "$FRESH_LOCAL/.git") {
    read_cwd_cmd($FRESH_LOCAL, 'git', 'rev-parse', '@{u}'); # TODO: Add specs and impliment "non-tracking branch" note
    my $git_status = read_cwd_cmd($FRESH_LOCAL, 'git', 'status', '--porcelain');

    if ($git_status eq "") {
      update_repo($FRESH_LOCAL, 'local files', $log_file);
    } else {
      note "Not updating $FRESH_LOCAL because it has uncommitted changes.";
      exit(1); # TODO: Only if --local
    }
  }

  if (defined($filter) && $filter eq "--local") {
    return;
  }

  if (-d "$FRESH_PATH/source") {
    my @paths;
    my $wanted = sub {
      /\.git\z/ && push @paths, dirname($_);
    };
    find({wanted => $wanted, no_chdir => 1}, "$FRESH_PATH/source");
    @paths = sort @paths;

    if (defined($filter)) {
      if ($filter =~ /\//) {
        @paths = glob_filter("*$filter", @paths);
      } else {
        @paths = glob_filter("*$filter/*", @paths);
      }
    }

    if (!@paths) {
      fatal_error("No matching sources found.");
    }

    foreach my $path (@paths) {
      my $repo_name = repo_name_from_source_path($path);
      update_repo($path, $repo_name, $log_file);
    }
  }
}

sub fresh_search {
  if (0 + @_ == 0) {
    fatal_error "No search query given."
  }

  my $args = join(' ', @_);
  my $results = read_cmd('curl', '-sS', 'http://api.freshshell.com/directory', '--get', '--data-urlencode', "q=$args");

  if ($results eq "") {
    fatal_error "No results."
  } else {
    print $results;
  }
}

sub fresh_edit {
  my $rcfile;
  if (-l $FRESH_RCFILE ) {
    $rcfile = realpath($FRESH_RCFILE);
  } else {
    $rcfile = $FRESH_RCFILE;
  }
  exec($ENV{EDITOR} || 'vi', $rcfile) == 0 or exit(1);
}

sub github_blob_url {
  my ($repo_name, $ref, $blob_path) = @_;
  return "https://github.com/$repo_name/blob/$ref/$blob_path";
}

sub source_file_url {
  my ($entry, $path) = @_;

  my $repo = $$entry{repo};
  my $ref = $$entry{options}{ref};

  if (defined($repo)) {
    if ($repo =~ /:/) {
      return repo_url($repo);
    } elsif (defined($ref)) {
      return github_blob_url($repo, $ref, $path)
    } else {
      my $prefix = get_entry_prefix($entry);
      my $file = remove_prefix($path, $prefix);
      $ref = read_cwd_cmd($prefix, "git", "log", "--pretty=%H", "-n", "1", "--", $file);
      chomp($ref);
      return github_blob_url($repo, $ref, $file);
    }
  } else {
    return $path;
  }
}

sub fresh_show {
  my $count = 0;

  for my $entry (read_freshrc()) {
    print "\n" if ($count >= 1);

    # TODO: This used to run through the _escape function.
    # I think it's okay now because it's just a string...
    print $$entry{freshrc_line};

    my $prefix = get_entry_prefix($entry);
    my @paths = get_entry_paths($entry, $prefix);
    foreach my $path (@paths) {
      my $url = source_file_url($entry, $path);
      print "<${\format_url($url)}>\n";
    }

    $count++;
  }
}

sub fresh_clean {
  fresh_clean_symlinks($ENV{HOME});
  fresh_clean_symlinks("$ENV{HOME}/bin");
}

sub fresh_clean_symlinks {
  my ($base) = @_;

  if (-e $base) {
    my @symlinks;
    my $wanted = sub {
      -l && push @symlinks, $_;
    };
    my $nodirs = sub {
      grep {! -d File::Spec->rel2abs($_, $base)} @_;
    };
    find({wanted => $wanted, no_chdir => 1, preprocess => $nodirs}, $base);

    foreach my $symlink (@symlinks) {
      my $dest = readlink($symlink);
      if (prefix_match($dest, "$FRESH_PATH/build/") && ! -e $dest ) {
        (my $display = $symlink) =~ s{^\Q$ENV{HOME}\E}{~};
        print "Removing $display\n";
        unlink($symlink);
      }
    }
  }
}

sub fresh_help {
  print <<EOF;
Keep your dot files \033[1;32mfresh\033[0m.

The following commands will install/update configuration files
as specified in your $FRESH_RCFILE file.

See ${\format_url 'http://freshshell.com/readme'} for more documentation.

usage: fresh <command> [<args>]

Available commands:
    install            Build shell configuration and relevant symlinks (default)
    update [<filter>]  Update from source repos and rebuild
    clean              Removes dead symlinks and source repos
    search <query>     Search the fresh directory
    edit               Open freshrc for editing
    show               Show source references for freshrc lines
    help               Show this help
EOF

  foreach my $path (split(/:/, $ENV{PATH})) {
    my @matches = bsd_glob("$path/fresh-*");
    foreach my $command_path (@matches) {
      my $command = remove_prefix($command_path, "$path/fresh-");
      printf "    %-18s %s\n", "$command", "Run $command plugin";
    }
  }
}

sub confirm {
  my ($question) = @_;

  print "$question [Y/n]? ";
  my $answer = <STDIN> || "";
  chomp($answer);

  if ($answer eq "Y" || $answer eq "y" || $answer eq "") {
    return 1;
  } elsif ($answer eq "N" || $answer eq "n") {
    return 0;
  } else {
    confirm($question);
  }
}

sub fresh_add {
  my $args = join('', @_);

  my $line = "fresh ${\quotemeta($args)}";

  if (confirm("Add `$line` to $FRESH_RCFILE")) {
    print "Adding `$line` to $FRESH_RCFILE...\n";
    append $FRESH_RCFILE, "$line\n";

    #

    fresh_install;
  } else {
    note "Use `fresh edit` to manually edit your $FRESH_RCFILE."
  }
}

sub main {
  my $arg = shift(@ARGV) || "install";

  if ($arg eq "update") {
    fresh_update(@ARGV);
    fresh_install_with_latest_binary;
  } elsif ($arg eq "install") {
    # TODO: should error if passed any args
    fresh_install;
  } elsif ($arg eq "edit") {
    # TODO: should error if passed any args
    fresh_edit;
  } elsif ($arg eq "show") {
    # TODO: should error if passed any args
    fresh_show;
  } elsif ($arg eq "clean") {
    # TODO: should error if passed any args
    fresh_clean;
  } elsif ($arg eq "search") {
    fresh_search(@ARGV);
  } elsif ($arg eq "help") {
    # TODO: should error if passed any args
    fresh_help;
  } else {
    my $bin_name = "fresh-$arg";

    if ($arg =~ /\// || -e "$FRESH_LOCAL/$arg") {
      fresh_add($arg, @ARGV);
    } else {
      if (system("which ${\quotemeta($bin_name)} > /dev/null 2> /dev/null") == 0) {
        exec($bin_name, @ARGV) or croak "$!";
      } else {
        fatal_error "Unknown command: $arg";
      }
    }
  }
}

if (__FILE__ eq $0) {
  main;
}
