use strict;
use warnings;
use utf8;

use Encode     ();
use File::Temp ();
use FindBin    ();
use IPC::Open2 ();
use JSON::PP   ();
use Test::More;
use Time::HiRes ();

my $SCRIPT = "$FindBin::Bin/../bin/claude-prompt";
my $BLANK  = "\x{2800}";

# Keep the person's own git and prompt settings out of the tests
$ENV{GIT_CONFIG_GLOBAL}   = '/dev/null';
$ENV{GIT_CONFIG_NOSYSTEM} = 1;
delete $ENV{$_} for grep {/^(?:GIT_PS1_|CLAUDE_PROMPT_|XDG_CONFIG_HOME$)/} keys %ENV;

binmode Test::More->builder->$_, ':encoding(UTF-8)' for qw(output failure_output todo_output);

# A statusline input shaped like what Claude Code sends
sub session_input {
    my ($dir) = @_;

    return {
        hook_event_name => 'Status',
        session_id      => '3f2c9a1e-7b4d-4e8a-9c1f-2d6b5a8e0f13',
        transcript_path => "$dir/.claude/transcript.jsonl",
        cwd             => $dir,
        model           => { id          => 'claude-opus-5-5', display_name => 'Opus 5.5' },
        workspace       => { current_dir => $dir,              project_dir  => $dir },
        version         => '2.1.0',
        output_style    => { name => 'default' },
        cost            => {
            total_cost_usd        => 1.97,
            total_duration_ms     => 3_720_000,
            total_api_duration_ms => 1_250_000,
            total_lines_added     => 120,
            total_lines_removed   => 34,
        },
        context_window => {
            total_input_tokens   => 18_400,
            total_output_tokens  => 2_100,
            context_window_size  => 200_000,
            used_percentage      => 10,
            remaining_percentage => 90,
            current_usage        => {
                input_tokens                => 50,
                output_tokens               => 320,
                cache_creation_input_tokens => 1_000,
                cache_read_input_tokens     => 18_000,
            },
        },
        prompt_cache => { hit_ratio => 0.98 },
    };
}

# Real input saved from Claude Code with t/save-input, as text, with __HOME__ replaced by
# the given home folder. Personal details in it were replaced by hand before saving it here.
sub saved_input {
    my ( $name, $home ) = @_;

    open my $fh, '<:encoding(UTF-8)', "$FindBin::Bin/data/$name" or die "$name: $!\n";
    my $json = do { local $/; <$fh> };
    close $fh;

    $json =~ s/__HOME__/$home/g;

    return Encode::encode( 'UTF-8', $json );
}

# Runs the script with the given input (a hash, or raw text), returning its output lines
sub run_prompt {
    my ( $input, %env ) = @_;

    local @ENV{ keys %env } = values %env;

    my $json = ref $input ? JSON::PP->new->utf8->encode($input) : $input;

    # Under a memory limit and a timer, so a bug that runs away stops the test, not the machine.
    # Some systems, such as macOS, don't allow the memory limit, so it runs without one there.
    my $pid = IPC::Open2::open2( my $out, my $in, '/bin/sh', '-c', 'ulimit -v 1000000 2>/dev/null; exec "$@"', 'sh', $^X, $SCRIPT );

    local $SIG{ALRM} = sub { kill 'KILL', $pid; die "claude-prompt took more than 10 seconds\n" };
    alarm 10;

    print {$in} $json;
    close $in;

    my $output = do { local $/; <$out> };
    waitpid $pid, 0;
    alarm 0;

    return split /\n/, Encode::decode( 'UTF-8', $output );
}

sub git {
    my ( $dir, @args ) = @_;

    system( 'git', '-C', $dir, '-c', 'user.name=Test', '-c', 'user.email=test@example.com', @args ) == 0
        or die "git @args failed\n";
}

# A home folder holding one git repo with a single commit
sub home_with_repo {
    my $home = File::Temp->newdir;
    my $repo = "$home/git/claude-pulse";

    mkdir "$home/git";
    mkdir $repo;
    git( $repo, 'init', '-q' );

    # Not 'init -b main', which needs git 2.28 or newer
    git( $repo, 'symbolic-ref', 'HEAD', 'refs/heads/main' );

    open my $fh, '>', "$repo/README.md" or die $!;
    print {$fh} "# claude-pulse\n";
    close $fh;
    git( $repo, 'add', 'README.md' );
    git( $repo, 'commit', '-q', '-m', 'Initial commit' );

    return ( $home, $repo );
}

sub add_uncommitted_change {
    my ($repo) = @_;

    open my $fh, '>>', "$repo/README.md" or die $!;
    print {$fh} "more\n";
    close $fh;
}

# Writes a config file into the home folder's default location, from a hash or raw text
sub write_config {
    my ( $home, $config ) = @_;

    mkdir "$home/.config";
    mkdir "$home/.config/claude-prompt";

    open my $fh, '>:raw', "$home/.config/claude-prompt/config.json" or die $!;
    print {$fh} ref $config ? JSON::PP->new->utf8->encode($config) : Encode::encode( 'UTF-8', $config );
    close $fh;
}

# Writes a stand-in for git's prompt helper, defining __git_ps1 with the given shell code,
# and returns its path. Lets the tests check how the helper is run without needing git.
sub fake_git_prompt {
    my ( $dir, $body ) = @_;

    my $path = "$dir/fake-git-prompt.sh";
    open my $fh, '>', $path or die $!;
    print {$fh} "__git_ps1 () { $body; }\n";
    close $fh;

    return $path;
}

my $have_git_prompt = grep { -r $_ } ( '/usr/lib/git-core/git-sh-prompt', '/usr/share/git-core/contrib/completion/git-prompt.sh', '/etc/bash_completion.d/git-prompt', '/opt/homebrew/etc/bash_completion.d/git-prompt.sh', '/usr/local/etc/bash_completion.d/git-prompt.sh', );

SKIP: {
    skip "git's prompt helper is not installed", 5 unless $have_git_prompt;

    subtest 'should print the folder, branch, and session details when in a git repo' => sub {

        # Arrange
        my ( $home, $repo ) = home_with_repo();

        # Act
        my ($line) = run_prompt( session_input($repo), HOME => "$home" );

        # Assert
        is( $line, '~/git/claude-pulse (main) [model:Opus 5.5 | context:10% | cache:98% | cost:$1.97 | time:1h 2m]' );
    };

    subtest 'should mark the branch with * when the repo has uncommitted changes' => sub {

        # Arrange
        my ( $home, $repo ) = home_with_repo();
        open my $fh, '>>', "$repo/README.md" or die $!;
        print {$fh} "more\n";
        close $fh;

        # Act
        my ($line) = run_prompt( session_input($repo), HOME => "$home" );

        # Assert
        like( $line, qr/^~\/git\/claude-pulse \(main \*\) \[/ );
    };

    subtest 'should leave out the dirty marker when GIT_PS1_SHOWDIRTYSTATE is empty' => sub {

        # Arrange
        my ( $home, $repo ) = home_with_repo();
        open my $fh, '>>', "$repo/README.md" or die $!;
        print {$fh} "more\n";
        close $fh;

        # Act
        my ($line) = run_prompt( session_input($repo), HOME => "$home", GIT_PS1_SHOWDIRTYSTATE => '' );

        # Assert
        like( $line, qr/^~\/git\/claude-pulse \(main\) \[/ );
    };

    subtest 'should wrap the branch in the git format from the config' => sub {

        # Arrange
        my ( $home, $repo ) = home_with_repo();
        write_config( $home, { git => { format => '‹%s›' } } );

        # Act
        my ($line) = run_prompt( session_input($repo), HOME => "$home" );

        # Assert
        like( $line, qr/^~\/git\/claude-pulse ‹main› \[/ );
    };

    subtest 'should pass git.env settings from the config to __git_ps1' => sub {

        # Arrange
        my ( $home, $repo ) = home_with_repo();
        add_uncommitted_change($repo);
        write_config( $home, { git => { env => { GIT_PS1_STATESEPARATOR => '' } } } );

        # Act
        my ($line) = run_prompt( session_input($repo), HOME => "$home" );

        # Assert
        like( $line, qr/^~\/git\/claude-pulse \(main\*\) \[/ );
    };
}

subtest 'should leave out the branch when the folder is not a git repo' => sub {

    # Arrange
    my $home = File::Temp->newdir;
    mkdir "$home/notes";

    # Act
    my ($line) = run_prompt( session_input("$home/notes"), HOME => "$home" );

    # Assert
    is( $line, '~/notes [model:Opus 5.5 | context:10% | cache:98% | cost:$1.97 | time:1h 2m]' );
};

subtest 'should show ~ when the folder is the home folder' => sub {

    # Arrange
    my $home = File::Temp->newdir;

    # Act
    my ($line) = run_prompt( session_input("$home"), HOME => "$home" );

    # Assert
    like( $line, qr/^~ \[/ );
};

subtest 'should show the full path when the folder is outside the home folder' => sub {

    # Arrange
    my $home  = File::Temp->newdir;
    my $other = File::Temp->newdir;

    # Act
    my ($line) = run_prompt( session_input("$other"), HOME => "$home" );

    # Assert
    like( $line, qr/^\Q$other\E \[/ );
};

subtest 'should not shorten a folder that only starts with the same letters as home' => sub {

    # Arrange
    my $home = File::Temp->newdir;
    my $dir  = "${home}-other";

    # Act
    my ($line) = run_prompt( session_input($dir), HOME => "$home" );

    # Assert
    like( $line, qr/^\Q$dir\E \[/ );
};

subtest 'should keep non-ASCII characters in folder names' => sub {

    # Arrange
    my $home = File::Temp->newdir;
    mkdir Encode::encode( 'UTF-8', "$home/café" );

    # Act
    my ($line) = run_prompt( session_input("$home/café"), HOME => "$home" );

    # Assert
    like( $line, qr/^~\/café \[/ );
};

subtest 'should use cwd when workspace is missing' => sub {

    # Arrange
    my $home  = File::Temp->newdir;
    my $input = session_input("$home/elsewhere");
    delete $input->{workspace};

    # Act
    my ($line) = run_prompt( $input, HOME => "$home" );

    # Assert
    like( $line, qr/^~\/elsewhere \[/ );
};

subtest 'should round the context percentage half up' => sub {

    # Arrange
    my $home  = File::Temp->newdir;
    my $input = session_input("$home");
    $input->{context_window}{used_percentage} = 12.5;

    # Act
    my ($line) = run_prompt( $input, HOME => "$home" );

    # Assert
    like( $line, qr/\| context:13% \|/ );
};

subtest 'should leave out context when used_percentage is null' => sub {

    # Arrange
    my $home  = File::Temp->newdir;
    my $input = session_input("$home");
    $input->{context_window}{used_percentage} = undef;

    # Act
    my ($line) = run_prompt( $input, HOME => "$home" );

    # Assert
    is( $line, '~ [model:Opus 5.5 | cache:98% | cost:$1.97 | time:1h 2m]' );
};

subtest 'should work out cache from the last request when hit_ratio is missing' => sub {

    # Arrange
    my $home  = File::Temp->newdir;
    my $input = session_input("$home");
    delete $input->{prompt_cache};

    # Act
    my ($line) = run_prompt( $input, HOME => "$home" );

    # Assert
    # 18,000 cache reads out of 19,050 input tokens
    like( $line, qr/\| cache:94% \|/ );
};

subtest 'should leave out cache when there are no cache figures' => sub {

    # Arrange
    my $home  = File::Temp->newdir;
    my $input = session_input("$home");
    delete $input->{prompt_cache};
    delete $input->{context_window}{current_usage};

    # Act
    my ($line) = run_prompt( $input, HOME => "$home" );

    # Assert
    is( $line, '~ [model:Opus 5.5 | context:10% | cost:$1.97 | time:1h 2m]' );
};

subtest 'should show two decimal places for cost' => sub {

    # Arrange
    my $home  = File::Temp->newdir;
    my $input = session_input("$home");
    $input->{cost}{total_cost_usd} = 0.4;

    # Act
    my ($line) = run_prompt( $input, HOME => "$home" );

    # Assert
    like( $line, qr/\| cost:\$0\.40 \|/ );
};

subtest 'should show seconds when the session is under a minute' => sub {

    # Arrange
    my $home  = File::Temp->newdir;
    my $input = session_input("$home");
    $input->{cost}{total_duration_ms} = 45_300;

    # Act
    my ($line) = run_prompt( $input, HOME => "$home" );

    # Assert
    like( $line, qr/\| time:45s\]$/ );
};

subtest 'should show minutes and seconds when the session is under an hour' => sub {

    # Arrange
    my $home  = File::Temp->newdir;
    my $input = session_input("$home");
    $input->{cost}{total_duration_ms} = 605_000;

    # Act
    my ($line) = run_prompt( $input, HOME => "$home" );

    # Assert
    like( $line, qr/\| time:10m 5s\]$/ );
};

subtest 'should show only hours when the session is a whole number of hours' => sub {

    # Arrange
    my $home  = File::Temp->newdir;
    my $input = session_input("$home");
    $input->{cost}{total_duration_ms} = 7_200_000;

    # Act
    my ($line) = run_prompt( $input, HOME => "$home" );

    # Assert
    like( $line, qr/\| time:2h\]$/ );
};

subtest 'should add one padding line by default' => sub {

    # Arrange
    my $home = File::Temp->newdir;

    # Act
    my @lines = run_prompt( session_input("$home"), HOME => "$home" );

    # Assert
    is_deeply( [ @lines[ 1 .. $#lines ] ], [$BLANK] );
};

subtest 'should add the number of padding lines set in the config' => sub {

    # Arrange
    my $home = File::Temp->newdir;
    write_config( $home, { padding => 3 } );

    # Act
    my @lines = run_prompt( session_input("$home"), HOME => "$home" );

    # Assert
    is_deeply( [ @lines[ 1 .. $#lines ] ], [ $BLANK, $BLANK, $BLANK ] );
};

subtest 'should add no padding lines when the config sets padding to 0' => sub {

    # Arrange
    my $home = File::Temp->newdir;
    write_config( $home, { padding => 0 } );

    # Act
    my @lines = run_prompt( session_input("$home"), HOME => "$home" );

    # Assert
    is( scalar @lines, 1 );
};

subtest 'should print an empty line and padding when the input is not JSON' => sub {

    # Arrange
    my $home = File::Temp->newdir;

    # Act
    my @lines = run_prompt( 'not json', HOME => "$home" );

    # Assert
    is_deeply( \@lines, [ '', $BLANK ] );
};

subtest 'should show the layout config.example.json describes' => sub {

    # Arrange
    my $home = File::Temp->newdir;

    # Act
    my @lines = run_prompt( session_input("$home"), HOME => "$home", CLAUDE_PROMPT_CONFIG => "$FindBin::Bin/../config.example.json" );

    # Assert
    # Not in a git repo, so there's no git part; the last part is the clock command
    like( $lines[0], qr/^~ \[model:Opus 5\.5 \| context:10% \| cache:98% \| cost:\$1\.97 \| time:1h 2m \| lines:\+120 -34\] \d\d:\d\d$/ );
    is_deeply( [ @lines[ 1 .. $#lines ] ], [$BLANK] );
};

subtest 'should show sections in the order the config lists them' => sub {

    # Arrange
    my $home = File::Temp->newdir;
    write_config( $home, { sections => [qw(cost model dir)] } );

    # Act
    my ($line) = run_prompt( session_input("$home"), HOME => "$home" );

    # Assert
    is( $line, 'cost:$1.97 model:Opus 5.5 ~' );
};

subtest 'should join sections with the separator from the config' => sub {

    # Arrange
    my $home = File::Temp->newdir;
    write_config( $home, { sections => [qw(dir model)], separator => ' :: ' } );

    # Act
    my ($line) = run_prompt( session_input("$home"), HOME => "$home" );

    # Assert
    is( $line, '~ :: model:Opus 5.5' );
};

subtest 'should keep the default labels for sections the config does not relabel' => sub {

    # Arrange
    my $home = File::Temp->newdir;
    write_config( $home, { sections => [qw(model context)], labels => { context => 'ctx ' } } );

    # Act
    my ($line) = run_prompt( session_input("$home"), HOME => "$home" );

    # Assert
    is( $line, 'model:Opus 5.5 ctx 10%' );
};

subtest 'should show no label when the config sets it to an empty string' => sub {

    # Arrange
    my $home = File::Temp->newdir;
    write_config( $home, { sections => ['model'], labels => { model => '' } } );

    # Act
    my ($line) = run_prompt( session_input("$home"), HOME => "$home" );

    # Assert
    is( $line, 'Opus 5.5' );
};

subtest 'should leave out a group and its brackets when none of its sections have a value' => sub {

    # Arrange
    my $home  = File::Temp->newdir;
    my $input = session_input("$home");
    delete $input->{cost};
    write_config( $home, { sections => [ 'dir', { before => '{', sections => [qw(cost time)], after => '}' } ] } );

    # Act
    my ($line) = run_prompt( $input, HOME => "$home" );

    # Assert
    is( $line, '~' );
};

subtest 'should join a group with a space when the group has no separator' => sub {

    # Arrange
    my $home = File::Temp->newdir;
    write_config( $home, { sections => [ { sections => [qw(cost time)] } ] } );

    # Act
    my ($line) = run_prompt( session_input("$home"), HOME => "$home" );

    # Assert
    is( $line, 'cost:$1.97 time:1h 2m' );
};

subtest 'should render a group inside a group' => sub {

    # Arrange
    my $home = File::Temp->newdir;
    write_config( $home, { sections => [ { before => '<', sections => [ 'model', { before => '(', sections => ['cost'], after => ')' } ], after => '>' } ] } );

    # Act
    my ($line) = run_prompt( session_input("$home"), HOME => "$home" );

    # Assert
    is( $line, '<model:Opus 5.5 (cost:$1.97)>' );
};

subtest 'should allow comments and trailing commas in the config' => sub {

    # Arrange
    my $home = File::Temp->newdir;
    write_config( $home, qq({\n    # just the model\n    "sections": ["model",],\n}\n) );

    # Act
    my ($line) = run_prompt( session_input("$home"), HOME => "$home" );

    # Assert
    is( $line, 'model:Opus 5.5' );
};

subtest 'should read the config from XDG_CONFIG_HOME when it is set' => sub {

    # Arrange
    my $home = File::Temp->newdir;
    my $xdg  = File::Temp->newdir;
    mkdir "$xdg/claude-prompt";
    open my $fh, '>', "$xdg/claude-prompt/config.json" or die $!;
    print {$fh} '{"sections": ["cost"]}';
    close $fh;

    # Act
    my ($line) = run_prompt( session_input("$home"), HOME => "$home", XDG_CONFIG_HOME => "$xdg" );

    # Assert
    is( $line, 'cost:$1.97' );
};

subtest 'should read the config from CLAUDE_PROMPT_CONFIG when it is set' => sub {

    # Arrange
    my $home = File::Temp->newdir;
    my $file = File::Temp->new( SUFFIX => '.json' );
    print {$file} '{"sections": ["time"]}';
    close $file;

    # Act
    my ($line) = run_prompt( session_input("$home"), HOME => "$home", CLAUDE_PROMPT_CONFIG => $file->filename );

    # Assert
    is( $line, 'time:1h 2m' );
};

subtest 'should show an error in the statusline when the config is not valid JSON' => sub {

    # Arrange
    my $home = File::Temp->newdir;
    write_config( $home, '{"sections": [' );

    # Act
    my ($line) = run_prompt( session_input("$home"), HOME => "$home" );

    # Assert
    like( $line, qr/^claude-prompt: ~\/\.config\/claude-prompt\/config\.json: not valid JSON: / );
};

subtest 'should show an error naming an unknown section' => sub {

    # Arrange
    my $home = File::Temp->newdir;
    write_config( $home, { sections => [qw(dir modle)] } );

    # Act
    my ($line) = run_prompt( session_input("$home"), HOME => "$home" );

    # Assert
    like( $line, qr/^claude-prompt: .*: unknown section "modle" in "sections" \(known: / );
};

subtest 'should show an error naming an unknown section inside a group' => sub {

    # Arrange
    my $home = File::Temp->newdir;
    write_config( $home, { sections => [ { sections => ['coast'] } ] } );

    # Act
    my ($line) = run_prompt( session_input("$home"), HOME => "$home" );

    # Assert
    like( $line, qr/: unknown section "coast" in "sections\.sections"/ );
};

subtest 'should show an error naming an unknown setting' => sub {

    # Arrange
    my $home = File::Temp->newdir;
    write_config( $home, { seperator => ' ' } );

    # Act
    my ($line) = run_prompt( session_input("$home"), HOME => "$home" );

    # Assert
    like( $line, qr/: unknown setting "seperator"$/ );
};

subtest 'should show an error when padding is not a whole number' => sub {

    # Arrange
    my $home = File::Temp->newdir;
    write_config( $home, { padding => 'two' } );

    # Act
    my ($line) = run_prompt( session_input("$home"), HOME => "$home" );

    # Assert
    like( $line, qr/: "padding" should be a whole number/ );
};

subtest 'should still add one padding line when showing a config error' => sub {

    # Arrange
    my $home = File::Temp->newdir;
    write_config( $home, { padding => 'two' } );

    # Act
    my @lines = run_prompt( session_input("$home"), HOME => "$home" );

    # Assert
    is_deeply( [ @lines[ 1 .. $#lines ] ], [$BLANK] );
};

subtest 'should show a command from the config as a section, with its label' => sub {

    # Arrange
    my $home = File::Temp->newdir;
    write_config( $home, { commands => { greeting => { run => 'echo hello' } }, sections => [qw(greeting model)], labels => { greeting => 'say:' } } );

    # Act
    my ($line) = run_prompt( session_input("$home"), HOME => "$home" );

    # Assert
    is( $line, 'say:hello model:Opus 5.5' );
};

subtest 'should send the session JSON to a command on STDIN' => sub {

    # Arrange
    my $home = File::Temp->newdir;
    write_config( $home, { commands => { session => { run => qq("$^X" -MJSON::PP -0777 -ne 'print decode_json(\$_)->{session_id}') } }, sections => ['session'] } );

    # Act
    my ($line) = run_prompt( session_input("$home"), HOME => "$home" );

    # Assert
    is( $line, '3f2c9a1e-7b4d-4e8a-9c1f-2d6b5a8e0f13' );
};

subtest 'should run a command in the folder Claude Code is working in' => sub {

    # Arrange
    my $home = File::Temp->newdir;
    mkdir "$home/project";
    write_config( $home, { commands => { folder => { run => 'pwd' } }, sections => ['folder'] } );

    # Act
    my ($line) = run_prompt( session_input("$home/project"), HOME => "$home" );

    # Assert
    like( $line, qr{/project$} );
};

subtest 'should show only the first line a command prints' => sub {

    # Arrange
    my $home = File::Temp->newdir;
    write_config( $home, { commands => { lines => { run => 'echo one; echo two' } }, sections => [qw(lines model)] } );

    # Act
    my ($line) = run_prompt( session_input("$home"), HOME => "$home" );

    # Assert
    is( $line, 'one model:Opus 5.5' );
};

subtest 'should keep non-ASCII characters in a command\'s output' => sub {

    # Arrange
    my $home = File::Temp->newdir;
    write_config( $home, { commands => { weather => { run => 'echo ☀ 21°' } }, sections => ['weather'] } );

    # Act
    my ($line) = run_prompt( session_input("$home"), HOME => "$home" );

    # Assert
    is( $line, '☀ 21°' );
};

subtest 'should leave out a command that exits with an error' => sub {

    # Arrange
    my $home = File::Temp->newdir;
    write_config( $home, { commands => { broken => { run => 'echo partial; exit 3' } }, sections => [qw(broken model)] } );

    # Act
    my ($line) = run_prompt( session_input("$home"), HOME => "$home" );

    # Assert
    is( $line, 'model:Opus 5.5' );
};

subtest 'should leave out a command that prints nothing' => sub {

    # Arrange
    my $home = File::Temp->newdir;
    write_config( $home, { commands => { quiet => { run => 'true' } }, sections => [qw(quiet model)] } );

    # Act
    my ($line) = run_prompt( session_input("$home"), HOME => "$home" );

    # Assert
    is( $line, 'model:Opus 5.5' );
};

subtest 'should leave out a command that runs past its timeout, without waiting for it' => sub {

    # Arrange
    my $home = File::Temp->newdir;
    write_config( $home, { commands => { slow => { run => 'sleep 5; echo late', timeout => 0.5 } }, sections => [qw(slow model)] } );

    # Act
    my $start   = Time::HiRes::time();
    my ($line)  = run_prompt( session_input("$home"), HOME => "$home" );
    my $elapsed = Time::HiRes::time() - $start;

    # Assert
    is( $line, 'model:Opus 5.5' );
    cmp_ok( $elapsed, '<', 3, 'finished well before the command would have' );
};

subtest 'should stop everything a command started when it runs past its timeout' => sub {

    # Arrange
    my $home = File::Temp->newdir;
    write_config( $home, { commands => { slow => { run => "sleep 30 & echo \$! > '$home/pid'; wait", timeout => 0.5 } }, sections => ['slow'] } );

    # Act
    run_prompt( session_input("$home"), HOME => "$home" );

    # Assert
    open my $fh, '<', "$home/pid" or die $!;
    chomp( my $pid = <$fh> );
    close $fh;

    # The stopped process can take a moment to be cleaned up after it's killed
    my $running = 1;
    for ( 1 .. 20 ) {
        $running = kill 0, $pid;
        last unless $running;
        Time::HiRes::sleep(0.05);
    }
    ok( !$running, 'the sleep the command started is no longer running' );
};

subtest 'should leave out a command that prints without stopping, without running out of memory' => sub {

    # Arrange
    my $home = File::Temp->newdir;
    write_config( $home, { commands => { endless => { run => 'yes', timeout => 0.5 } }, sections => [qw(endless model)] } );

    # Act
    my ($line) = run_prompt( session_input("$home"), HOME => "$home" );

    # Assert
    is( $line, 'model:Opus 5.5' );
};

subtest 'should list commands from the config among the known sections in an error' => sub {

    # Arrange
    my $home = File::Temp->newdir;
    write_config( $home, { commands => { weather => { run => 'true' } }, sections => ['wether'] } );

    # Act
    my ($line) = run_prompt( session_input("$home"), HOME => "$home" );

    # Assert
    like( $line, qr/: unknown section "wether" in "sections" \(known: .*\bweather\b/ );
};

subtest 'should show an error when a command has the same name as a built-in section' => sub {

    # Arrange
    my $home = File::Temp->newdir;
    write_config( $home, { commands => { git => { run => 'true' } } } );

    # Act
    my ($line) = run_prompt( session_input("$home"), HOME => "$home" );

    # Assert
    like( $line, qr/: command "git" has the same name as a built-in section$/ );
};

subtest 'should show an error when a command has no run setting' => sub {

    # Arrange
    my $home = File::Temp->newdir;
    write_config( $home, { commands => { weather => {} } } );

    # Act
    my ($line) = run_prompt( session_input("$home"), HOME => "$home" );

    # Assert
    like( $line, qr/: command "weather" needs "run"/ );
};

subtest 'should show an error when a command\'s timeout is not above 0' => sub {

    # Arrange
    my $home = File::Temp->newdir;
    write_config( $home, { commands => { weather => { run => 'true', timeout => 0 } } } );

    # Act
    my ($line) = run_prompt( session_input("$home"), HOME => "$home" );

    # Assert
    like( $line, qr/: "timeout" in command "weather" should be a number of seconds above 0/ );
};

subtest 'should show an error naming an unknown setting in a command' => sub {

    # Arrange
    my $home = File::Temp->newdir;
    write_config( $home, { commands => { weather => { run => 'true', tmeout => 1 } } } );

    # Act
    my ($line) = run_prompt( session_input("$home"), HOME => "$home" );

    # Assert
    like( $line, qr/: unknown setting "tmeout" in command "weather"$/ );
};

subtest 'should use the prompt helper named in git.script' => sub {

    # Arrange
    my $home = File::Temp->newdir;
    write_config( $home, { git => { script => fake_git_prompt( $home, 'printf "$1" fake-branch' ) }, sections => [qw(dir git)] } );

    # Act
    my ($line) = run_prompt( session_input("$home"), HOME => "$home" );

    # Assert
    is( $line, '~ (fake-branch)' );
};

subtest 'should run __git_ps1 in the folder Claude Code is working in' => sub {

    # Arrange
    my $home = File::Temp->newdir;
    mkdir "$home/project";
    write_config( $home, { git => { script => fake_git_prompt( $home, 'printf "$1" "${PWD##*/}"' ) }, sections => ['git'] } );

    # Act
    my ($line) = run_prompt( session_input("$home/project"), HOME => "$home" );

    # Assert
    is( $line, '(project)' );
};

subtest 'should leave out git when the prompt helper in git.script does not exist' => sub {

    # Arrange
    my $home = File::Temp->newdir;
    write_config( $home, { git => { script => "$home/no-such-helper.sh" }, sections => [qw(dir git)] } );

    # Act
    my ($line) = run_prompt( session_input("$home"), HOME => "$home" );

    # Assert
    is( $line, '~' );
};

subtest 'should leave out git when the folder does not exist' => sub {

    # Arrange
    my $home = File::Temp->newdir;
    write_config( $home, { git => { script => fake_git_prompt( $home, 'printf "$1" fake-branch' ) }, sections => [qw(dir git)] } );

    # Act
    my ($line) = run_prompt( session_input("$home/gone"), HOME => "$home" );

    # Assert
    is( $line, '~/gone' );
};

subtest 'should leave out git without waiting for it when it takes longer than 1 second' => sub {

    # Arrange
    my $home = File::Temp->newdir;
    write_config( $home, { git => { script => fake_git_prompt( $home, 'sleep 5; printf "$1" late' ) }, sections => [qw(dir git)] } );

    # Act
    my $start   = Time::HiRes::time();
    my ($line)  = run_prompt( session_input("$home"), HOME => "$home" );
    my $elapsed = Time::HiRes::time() - $start;

    # Assert
    is( $line, '~' );
    cmp_ok( $elapsed, '<', 3, 'finished well before git would have' );
};

subtest 'should set GIT_OPTIONAL_LOCKS to 0 for git' => sub {

    # Arrange
    my $home = File::Temp->newdir;
    write_config( $home, { git => { script => fake_git_prompt( $home, 'printf "$1" "locks=$GIT_OPTIONAL_LOCKS"' ) }, sections => ['git'] } );

    # Act
    my ($line) = run_prompt( session_input("$home"), HOME => "$home" );

    # Assert
    is( $line, '(locks=0)' );
};

subtest 'should keep GIT_OPTIONAL_LOCKS from the environment when it is set' => sub {

    # Arrange
    my $home = File::Temp->newdir;
    write_config( $home, { git => { script => fake_git_prompt( $home, 'printf "$1" "locks=$GIT_OPTIONAL_LOCKS"' ) }, sections => ['git'] } );

    # Act
    my ($line) = run_prompt( session_input("$home"), HOME => "$home", GIT_OPTIONAL_LOCKS => 1 );

    # Assert
    is( $line, '(locks=1)' );
};

subtest 'should set GIT_PS1_SHOWDIRTYSTATE to 1 when it is not set anywhere' => sub {

    # Arrange
    my $home = File::Temp->newdir;
    write_config( $home, { git => { script => fake_git_prompt( $home, 'printf "$1" "dirty=$GIT_PS1_SHOWDIRTYSTATE"' ) }, sections => ['git'] } );

    # Act
    my ($line) = run_prompt( session_input("$home"), HOME => "$home" );

    # Assert
    is( $line, '(dirty=1)' );
};

subtest 'should let git.env override the same setting in the environment' => sub {

    # Arrange
    my $home = File::Temp->newdir;
    write_config( $home, { git => { script => fake_git_prompt( $home, 'printf "$1" "sep=$GIT_PS1_STATESEPARATOR"' ), env => { GIT_PS1_STATESEPARATOR => 'from-config' } }, sections => ['git'] } );

    # Act
    my ($line) = run_prompt( session_input("$home"), HOME => "$home", GIT_PS1_STATESEPARATOR => 'from-environment' );

    # Assert
    is( $line, '(sep=from-config)' );
};

subtest 'should show the default statusline for real input from Claude Code 2.1.318' => sub {

    # Arrange
    my $home = File::Temp->newdir;
    mkdir "$home/git";
    mkdir "$home/git/project";

    # Act
    my @lines = run_prompt( saved_input( 'claude-code-2.1.318.json', "$home" ), HOME => "$home" );

    # Assert
    # Not a git repo, so no git part. cache is prompt_cache.hit_ratio, 0.9859, rounded.
    is( $lines[0], '~/git/project [model:Opus 5.5 | context:13% | cache:99% | cost:$2.73 | time:37m 59s]' );
    is_deeply( [ @lines[ 1 .. $#lines ] ], [$BLANK], 'followed by one padding line' );
};

subtest 'should send real input from Claude Code 2.1.318 to a command as it was sent' => sub {

    # Arrange
    my $home  = File::Temp->newdir;
    my $input = saved_input( 'claude-code-2.1.318.json', "$home" );
    write_config( $home, { commands => { copy => { run => "cat > '$home/received.json'; echo saved" } }, sections => ['copy'] } );

    # Act
    my ($line) = run_prompt( $input, HOME => "$home" );

    # Assert
    is( $line, 'saved' );
    open my $fh, '<:raw', "$home/received.json" or die $!;
    my $received = do { local $/; <$fh> };
    close $fh;
    is( $received, $input, 'the command got the same bytes Claude Code sent' );
};

# Each config problem, and the message the statusline should show for it
my @CONFIG_ERRORS = (
    [ 'the file holds a list instead of an object', '[]', 'should hold a JSON object, like {"padding": 1}' ],
    [ '"sections" is not a list',                   { sections  => 'dir' },                                               '"sections" should be a list, like ["dir", "git"]' ],
    [ 'an item in "sections" is a list',            { sections  => [ ['dir'] ] },                                         'each item in "sections" should be a section name or a group' ],
    [ 'a group has no list of sections',            { sections  => [ {} ] },                                              '"sections.sections" should be a list, like ["dir", "git"]' ],
    [ 'a group has an unknown setting',             { sections  => [ { sections => ['dir'], befor => '[' } ] },           'unknown setting "befor" in a group in "sections"' ],
    [ 'a group\'s "before" is not text',            { sections  => [ { sections => ['dir'], before => [] } ] },           '"before" in a group in "sections" should be text' ],
    [ '"separator" is not text',                    { separator => [] },                                                  '"separator" should be text' ],
    [ '"labels" is not an object',                  { labels    => [] },                                                  '"labels" should be an object, like {"model": "model:"}' ],
    [ '"labels" names an unknown section',          { labels    => { modle => 'm:' } },                                   'unknown section "modle" in "labels"' ],
    [ 'a label is not text',                        { labels    => { model => [] } },                                     'label for "model" should be text' ],
    [ '"git" is not an object',                     { git       => 'yes' },                                               '"git" should be an object, like {"format": "(%s)"}' ],
    [ '"git" has an unknown setting',               { git       => { fromat => '(%s)' } },                                'unknown setting "fromat" in "git"' ],
    [ '"git.format" is not text',                   { git       => { format => [] } },                                    '"git.format" should be text' ],
    [ '"git.script" is not text',                   { git       => { script => [] } },                                    '"git.script" should be text' ],
    [ '"git.env" is not an object',                 { git       => { env => [] } },                                       '"git.env" should be an object, like {"GIT_PS1_SHOWDIRTYSTATE": "1"}' ],
    [ 'a "git.env" value is not text',              { git       => { env => { GIT_PS1_SHOWDIRTYSTATE => [] } } },         '"git.env" value for "GIT_PS1_SHOWDIRTYSTATE" should be text' ],
    [ '"commands" is not an object',                { commands  => [] },                                                  '"commands" should be an object, like {"k8s": {"run": "kubectl config current-context"}}' ],
    [ 'a command has an empty name',                { commands  => { '' => { run => 'true' } } },                         'a command in "commands" has an empty name' ],
    [ 'a command is not an object',                 { commands  => { weather => 'curl wttr.in' } },                       'command "weather" should be an object, like {"run": "date +%H:%M"}' ],
    [ 'a command\'s "run" is empty',                { commands  => { weather => { run => '' } } },                        'command "weather" needs "run", the command to run, like "date +%H:%M"' ],
    [ 'a command\'s timeout is not a number',       { commands  => { weather => { run => 'true', timeout => 'soon' } } }, '"timeout" in command "weather" should be a number of seconds above 0, like 1' ],
);

for my $case (@CONFIG_ERRORS) {
    my ( $problem, $config, $message ) = @$case;

    subtest "should show an error when $problem" => sub {

        # Arrange
        my $home = File::Temp->newdir;
        write_config( $home, $config );

        # Act
        my @lines = run_prompt( session_input("$home"), HOME => "$home" );

        # Assert
        is( $lines[0], "claude-prompt: ~/.config/claude-prompt/config.json: $message" );
        is_deeply( [ @lines[ 1 .. $#lines ] ], [$BLANK], 'followed by one padding line' );
    };
}

SKIP: {
    skip 'root can read any file', 1 if $> == 0;

    subtest 'should show an error when the config file cannot be read' => sub {

        # Arrange
        my $home = File::Temp->newdir;
        write_config( $home, { padding => 1 } );
        chmod 0, "$home/.config/claude-prompt/config.json";

        # Act
        my ($line) = run_prompt( session_input("$home"), HOME => "$home" );

        # Assert
        like( $line, qr/^claude-prompt: ~\/\.config\/claude-prompt\/config\.json: can't read it: / );
    };
}

done_testing;
