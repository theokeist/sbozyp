#!/usr/bin/perl

use strict;
use warnings;
use v5.34.0;

use Test2::V0 -no_srand => 1;
use Test2::Plugin::BailOnFail; # bail out of testing on the first failure

use Capture::Tiny qw(capture);
use File::Temp;
use File::stat;
use File::Find;
use File::Path qw(make_path remove_tree);
use File::Basename qw(basename);
use File::Copy qw(mv);
use Getopt::Long qw(:config no_ignore_case bundling);
use Cwd qw(getcwd);
use FindBin;
require "$FindBin::Bin/../bin/sbozyp";

$SIG{INT} = sub { die "sbozyp.t: got a SIGINT ... going down!\n" };

            ####################################################
            #                       TESTS                      #
            ####################################################

my $TEST_DIR = File::Temp->newdir(DIR => '/tmp', TEMPLATE => 'sbozyp.tXXXXXX', CLEANUP => 1);

subtest 'is_multilib_system()' => sub {
    if (-f '/etc/profile.d/32dev.sh') {
        ok(Sbozyp::is_multilib_system(), 'true if system is multilib');
    } else {
        ok(!Sbozyp::is_multilib_system(), 'false if system is not multilib');
    }
};

subtest 'arch()' => sub {
    chomp(my $arch = `uname -m`);
    is(Sbozyp::arch(), $arch, 'returns the systems architecture');
};

subtest 'sbozyp_die()' => sub {
    like(dies { Sbozyp::sbozyp_die('dead') },
         qr/^sbozyp: error: dead$/,
         'dies with an sbozyp error prefix'
    );

    like(dies { Sbozyp::sbozyp_die("dead\n") },
         qr/^sbozyp: error: dead\n$/,
         'does not chomp death message'
    );
};

subtest 'sbozyp_system()' => sub {
    ok(lives { Sbozyp::sbozyp_system('true') }, 'lives if system command succeeds');

    my ($stdout) = capture { Sbozyp::sbozyp_system('echo foo') };
    is($stdout, "foo\n", 'produces output to stdout');

    my (undef, $stderr) = capture { Sbozyp::sbozyp_system('>&2 echo foo') };
    is($stderr, "foo\n", 'produces output to stderr');

    ($stdout) = capture { Sbozyp::sbozyp_system('echo', 'foo') };
    is($stdout, "foo\n", 'accepts list');

    ok(dies { Sbozyp::sbozyp_system('false') }, 'dies if system command fails');

    like(dies { Sbozyp::sbozyp_system('false') },
         qr/^sbozyp: error: system command 'false' exited with status 1$/,
         'dies with error message containing the exit status when system command fails'
    );
};

subtest 'sbozyp_qx()' => sub {
    ok(lives { Sbozyp::sbozyp_qx('true') }, 'lives if system command succeeds');

    is(Sbozyp::sbozyp_qx('echo foo'), 'foo', 'returns stdout with chomped newline when called in scalar context');

    is([Sbozyp::sbozyp_qx('echo -e "foo\nbar"')],
       ['foo', 'bar'],
       'returns list of chomped lines when called in list context'
    );

    ok(dies { Sbozyp::sbozyp_qx('false') },
       'dies if system command fails'
    );

    like(dies { Sbozyp::sbozyp_qx('false') },
         qr/^sbozyp: error: system command 'false' exited with status 1$/,
         'dies with error message containing the exit status when system command fails'
     );
};

subtest 'sbozyp_getopts()' => sub {
    my @args = ('-f', '-b', 'foo', 'quux');
    Sbozyp::sbozyp_getopts(\@args, 'f' => \my $foo, 'b=s' => \my $bar);
    ok(($foo and $bar eq 'foo'), 'parses options with Getopt::Long::GetOptionsFromArray()');
    is([@args], ['quux'], 'mutates input array to remove options');
    like(dies { Sbozyp::sbozyp_getopts(['-b'], 'f' => \my $blah) },
         qr/^sbozyp: error: Unknown option: b$/,
         'dies with useful error message if option parsing fails'
    );
};

subtest 'sbozyp_open()' => sub {
    ok(lives { Sbozyp::sbozyp_open('>', "$TEST_DIR/foo") }, 'lives if open() succeeds');

    my $fh = Sbozyp::sbozyp_open('>', "$TEST_DIR/foo");
    ok(lives { close $fh }, 'returns filehandle');

    like(dies { Sbozyp::sbozyp_open('<', "$TEST_DIR/bar") },
         qr/^sbozyp: error: could not open file '\Q$TEST_DIR\E\/bar': No such file or directory$/,
         'dies with useful error message if open() fails'
     );
};

subtest 'sbozyp_unlink()' => sub {
    open my $fh, '>', "$TEST_DIR/foo" or die;
    close $fh or die;
    Sbozyp::sbozyp_unlink("$TEST_DIR/foo");
    ok(! -f "$TEST_DIR/foo", 'successfully unlinks file');

    like(dies { Sbozyp::sbozyp_unlink("$TEST_DIR/foo") },
         qr/^sbozyp: error: could not unlink file '\Q$TEST_DIR\E\/foo': No such file or directory$/,
         'dies with useful error message if unlink() fails'
    );
};

subtest 'sbozyp_copy()' => sub {
    open my $fh, '>', "$TEST_DIR/foo" or die;
    close $fh or die;

    my $umask = umask();
    my $perm = $umask == 0666 ? 0555 : 0666;

    chmod $perm, "$TEST_DIR/foo";
    Sbozyp::sbozyp_copy("$TEST_DIR/foo", "$TEST_DIR/bar");
    ok(-f "$TEST_DIR/foo" && -f "$TEST_DIR/bar", 'successfully copied file');
    is(stat("$TEST_DIR/bar")->mode & 0777, $perm, 'copies permission of source file to target file');
    is(umask(), $umask, 'does not modify umask');
    unlink "$TEST_DIR/foo" or die;
    unlink "$TEST_DIR/bar" or die;

    make_path("$TEST_DIR/baz/quux") or die;
    open $fh, '>', "$TEST_DIR/baz/foo" or die;
    close $fh or die;
    open $fh, '>', "$TEST_DIR/baz/quux/bar" or die;
    close $fh or die;
    mkdir "$TEST_DIR/dest" or die;
    Sbozyp::sbozyp_copy("$TEST_DIR/baz", "$TEST_DIR/dest");
    is([do{ my @files; File::Find::find(sub { push @files, $File::Find::name}, "$TEST_DIR/dest"); @files }],
       ["$TEST_DIR/dest", "$TEST_DIR/dest/foo", "$TEST_DIR/dest/quux",  "$TEST_DIR/dest/quux/bar"],
       'clones only contents of directory recursively'
    );

    remove_tree("$TEST_DIR/baz") or die;
    remove_tree("$TEST_DIR/dest") or die;

    like(dies { Sbozyp::sbozyp_copy("$TEST_DIR/foo", "$TEST_DIR/bar") },
         qr/^sbozyp: error: system command 'cp -a \Q$TEST_DIR\E\/foo \Q$TEST_DIR\E\/bar' exited with status 1$/,
         q(dies with error message about system command failure if 'cp' command fails)
    );
};

subtest 'sbozyp_move()' => sub {
    open my $fh, '>', "$TEST_DIR/foo" or die;
    close $fh or die;
    mkdir "$TEST_DIR/bar" or die;

    my $umask = umask();
    my $perm = $umask == 0666 ? 0555 : 0666;
    chmod $perm, "$TEST_DIR/foo";

    Sbozyp::sbozyp_move("$TEST_DIR/foo", "$TEST_DIR/bar");
    ok(! -f "$TEST_DIR/foo" && -f "$TEST_DIR/bar/foo", 'successfully moved file');
    is(stat("$TEST_DIR/bar/foo")->mode & 0777, $perm, 'saves permissions');
    is(umask(), $umask, 'did not modify umask');

    remove_tree("$TEST_DIR/bar") or die;

    like(dies { Sbozyp::sbozyp_move("$TEST_DIR/foo", "$TEST_DIR/bar") },
         qr/^sbozyp: error: could not move '\Q$TEST_DIR\E\/foo' to '\Q$TEST_DIR\E\/bar': No such file or directory$/,
        'dies with useful error message if mv() fails'
    );
};

subtest 'sbozyp_readdir()' => sub {
    is([Sbozyp::sbozyp_readdir($TEST_DIR)], [], 'throws away . and ..');
    open my $fh, '>', "$TEST_DIR/foo" or die;
    close $fh or die;
    open $fh, '>', "$TEST_DIR/bar" or die;
    close $fh or die;
    is([Sbozyp::sbozyp_readdir($TEST_DIR)], ["$TEST_DIR/bar", "$TEST_DIR/foo"], 'returns full paths');
    unlink "$TEST_DIR/foo" or die;
    unlink "$TEST_DIR/bar" or die;

    open $fh, '>', "$TEST_DIR/.foo" or die;
    close $fh or die;
    is([Sbozyp::sbozyp_readdir($TEST_DIR)], ["$TEST_DIR/.foo"], 'keeps dotfiles');
    unlink "$TEST_DIR/.foo" or die;

    like(dies { Sbozyp::sbozyp_readdir("$TEST_DIR/foo") },
         qr/^sbozyp: error: could not opendir '\Q$TEST_DIR\E\/foo': No such file or directory$/,
         'dies with useful error message if cannot opendir()'
    );
};

subtest 'sbozyp_find_files_recursive()' => sub {
    make_path("$TEST_DIR/foo/bar/baz") or die;
    open my $fh, '>', "$TEST_DIR/foo/foo_f" or die;
    close $fh or die;
    open $fh, '>', "$TEST_DIR/foo/bar_f" or die;
    close $fh or die;
    open $fh, '>', "$TEST_DIR/foo/bar/foo_f" or die;
    close $fh or die;
    open $fh, '>', "$TEST_DIR/foo/bar/baz/baz_f" or die;
    close $fh or die;
    open $fh, '>', "$TEST_DIR/foo/bar/baz/quux_f" or die;
    close $fh or die;

    is([Sbozyp::sbozyp_find_files_recursive("$TEST_DIR/foo")],
       ["$TEST_DIR/foo/bar/baz/baz_f","$TEST_DIR/foo/bar/baz/quux_f","$TEST_DIR/foo/bar/foo_f","$TEST_DIR/foo/bar_f","$TEST_DIR/foo/foo_f"],
       'returns all files in directory recursively'
    );

    like(dies { Sbozyp::sbozyp_find_files_recursive("$TEST_DIR/bar") },
         qr/^sbozyp: error: could not opendir '\Q$TEST_DIR\E\/bar': No such file or directory$/,
         'dies with useful error message if cannot opendir()'
    );

    like(dies { Sbozyp::sbozyp_find_files_recursive("$TEST_DIR/foo/bar_f") },
         qr/^sbozyp: error: could not opendir '\Q$TEST_DIR\E\/foo\/bar_f': Not a directory$/,
         'dies with useful error message if passed a plain file'
    );

    remove_tree("$TEST_DIR/foo") or die;
};

subtest 'sbozyp_chdir()' => sub {
    my $orig_dir = getcwd(); # save this so we can switch back

    Sbozyp::sbozyp_chdir($TEST_DIR);
    is(getcwd(), "$TEST_DIR", 'successfully changes working directory');

    chdir $orig_dir or die;

    like(dies { Sbozyp::sbozyp_chdir("$TEST_DIR/foo") },
         qr/^sbozyp: error: could not chdir to '\Q$TEST_DIR\E\/foo': No such file or directory$/,
         'dies with useful error message if cannot chdir()'
     );
};

subtest 'sbozyp_mkdir()' => sub {
    my $dir = Sbozyp::sbozyp_mkdir("$TEST_DIR/foo/bar/baz");
    ok(-d "$TEST_DIR/foo/bar/baz", 'creates entire path');
    is($dir, "$TEST_DIR/foo/bar/baz", 'returns created path');

    remove_tree("$TEST_DIR/foo") or die;

    open my $fh, '>', "$TEST_DIR/foo" or die;
    close $fh or die;

    like(dies { Sbozyp::sbozyp_mkdir("$TEST_DIR/foo") },
         qr/^sbozyp: error: could not mkdir '\Q$TEST_DIR\E\/foo': File exists$/,
         'dies with useful error message if cannot make_path()'
    );

    unlink "$TEST_DIR/foo" or die;
};

subtest 'sbozyp_mkdir_empty()' => sub {
    my $dir = Sbozyp::sbozyp_mkdir_empty("$TEST_DIR/foo/bar");
    ok(-d "$TEST_DIR/foo/bar", 'creates entire path');
    is($dir, "$TEST_DIR/foo/bar", 'returns created path');

    Sbozyp::sbozyp_mkdir_empty("$TEST_DIR/foo");
    ok(! -d "$TEST_DIR/foo/bar", 'removes directory contents');
    ok(-d "$TEST_DIR/foo", 'leaves input dir');

    remove_tree("$TEST_DIR/foo") or die;

    open my $fh, '>', "$TEST_DIR/foo" or die;
    close $fh or die;

    like(dies { Sbozyp::sbozyp_mkdir_empty("$TEST_DIR/foo") },
         qr/^sbozyp: error: could not mkdir '\Q$TEST_DIR\E\/foo': File exists$/,
         'dies with useful error message if cannot make_path()'
    );

    unlink "$TEST_DIR/foo" or die;
};

subtest 'i_am_root_or_die()' => sub {
    if ($> == 0) {
        ok(lives { Sbozyp::i_am_root_or_die() }, 'lives if $> == 0');
    } else {
        like(dies { Sbozyp::i_am_root_or_die() }, qr/^sbozyp: error: must be root$/, 'dies if $> != 0');
    }
};

subtest 'parse_config_file()' => sub {
    is(\%Sbozyp::CONFIG,
       {TMPDIR=>'/tmp/sbozyp',CLEANUP=>1,REPO_ROOT=>'/var/lib/sbozyp/SBo',REPO_GIT_URL=>'git://git.slackbuilds.org/slackbuilds.git',REPO_GIT_BRANCH=>'15.0'},
       '%CONFIG has correct default values'
    );

    my $test_config = "$TEST_DIR/test_sbozyp.conf";

    open my $fh, '>', $test_config or die;
    close $fh or die;
    Sbozyp::parse_config_file($test_config);
    is(\%Sbozyp::CONFIG,
       {TMPDIR=>'/tmp/sbozyp',CLEANUP=>1,REPO_ROOT=>'/var/lib/sbozyp/SBo',REPO_GIT_URL=>'git://git.slackbuilds.org/slackbuilds.git',REPO_GIT_BRANCH=>'15.0'},
       'parsing empty config does not change %CONFIG'
    );

    open $fh, '>', $test_config or die;
    print $fh <<"END";
TMPDIR=foo
END
    close $fh or die;
    Sbozyp::parse_config_file($test_config);
    is(\%Sbozyp::CONFIG,
       {TMPDIR=>'foo',CLEANUP=>1,REPO_ROOT=>'/var/lib/sbozyp/SBo',REPO_GIT_URL=>'git://git.slackbuilds.org/slackbuilds.git',REPO_GIT_BRANCH=>'15.0'},
       'only modifies %CONFIG values specified in the config file'
    );

    open $fh, '>', $test_config or die;
    print $fh <<"END";
# CLEANUP=note_the_comment

TMPDIR = bar # eol comment

CLEANUP   =   bar # eol comment
END
    close $fh or die;
    Sbozyp::parse_config_file($test_config);
    is(\%Sbozyp::CONFIG,
       {TMPDIR=>'bar',CLEANUP=>'bar',REPO_ROOT=>'/var/lib/sbozyp/SBo',REPO_GIT_URL=>'git://git.slackbuilds.org/slackbuilds.git',REPO_GIT_BRANCH=>'15.0'},
       'ignores comments, eol comments, whitespace, and blank lines'
    );

    open $fh, '>', $test_config or die;
    print $fh <<'END';
TMPDIR=foo
CLEANUP=foo
REPO_ROOT=foo
REPO_GIT_URL=foo
REPO_GIT_BRANCH=foo
END
    close $fh or die;
    Sbozyp::parse_config_file($test_config);
    is(\%Sbozyp::CONFIG,
       {TMPDIR=>'foo',CLEANUP=>'foo',REPO_ROOT=>'foo',REPO_GIT_URL=>'foo',REPO_GIT_BRANCH=>'foo'},
       'successfully parses config file and updates %CONFIG'
    );

    open $fh, '>', $test_config or die;
    print $fh <<'END';
 =foo # no key
END
    close $fh or die;
    like(dies { Sbozyp::parse_config_file($test_config) },
         qr/^sbozyp: error: could not parse line 1 ' =foo # no key': '\Q$test_config\E'$/,
         'dies with useful error message if there is an empty key'
    );

    open $fh, '>', $test_config or die;
    print $fh <<'END';
TMPDIR= # no value
END
    close $fh or die;
    like(dies { Sbozyp::parse_config_file($test_config) },
         qr/^sbozyp: error: could not parse line 1 'TMPDIR= # no value': '\Q$test_config\E'$/,
         'dies with useful error message if there is an empty value'
    );

    open $fh, '>', $test_config or die;
    print $fh <<'END';
foo=bar
END
    close $fh or die;
    like(dies { Sbozyp::parse_config_file($test_config) },
         qr/^sbozyp: error: invalid setting on line 1 'foo': '\Q$test_config\E'$/,
         'dies with useful error message if config file contains invalid setting'
    );

    # Set %CONFIG to the value we want for the rest of our testing
    open $fh, '>', $test_config or die;
    print $fh <<"END";
TMPDIR=$TEST_DIR
CLEANUP=1
REPO_ROOT=$TEST_DIR/var/lib/sbozyp/SBo
REPO_GIT_URL=git://git.slackbuilds.org/slackbuilds.git
# SBo Version 14.1 is very unlikely to be updated, which means our tests should
# not start randomly failing due to updates to the packages we test against.
REPO_GIT_BRANCH=14.1
END
    close $fh or die;
    Sbozyp::parse_config_file($test_config);
    is(\%Sbozyp::CONFIG,
       {TMPDIR=>"$TEST_DIR", CLEANUP=>1,REPO_ROOT=>"$TEST_DIR/var/lib/sbozyp/SBo",REPO_GIT_URL=>'git://git.slackbuilds.org/slackbuilds.git',REPO_GIT_BRANCH=>'14.1'},
       '%CONFIG is properly set for use by the test of this test script'
    );

    unlink $test_config or die;
};

# the sbozyp_tee() subtest must come after the parse_config_file() subtest, as sbozyp_tee()'s implementation uses CONFIG{TMPDIR} which is set in the parse_config_file() subtest.
subtest 'sbozyp_tee()' => sub {
    my $teed_stdout;
    my ($real_stdout) = capture { $teed_stdout = Sbozyp::sbozyp_tee('echo -e "foo\nbar\nbaz"') };
    is($teed_stdout, $real_stdout, 'captures stdout');
    is(Sbozyp::sbozyp_tee('1>&2 echo foo'), '', 'returns empty string if command produces no output to STDOUT');
    ($real_stdout) = capture { $teed_stdout = Sbozyp::sbozyp_tee('echo foo && echo bar ; echo baz') };
    is($teed_stdout, $real_stdout, 'captures stdout of shell command with meta chars');
    is([Sbozyp::sbozyp_readdir($Sbozyp::CONFIG{TMPDIR})], [], 'cleans up tmp file from $CONFIG{TMPDIR}');
    like(dies { Sbozyp::sbozyp_tee('false') },
         qr/^sbozyp: error: system command 'bash -c set -o pipefail && \( false \) \| tee '[^']+'' exited with status 1$/,
         'dies with useful error message is system command fails'
    );
    is([Sbozyp::sbozyp_readdir($Sbozyp::CONFIG{TMPDIR})], [], 'cleans up tmp file from $CONFIG{TMPDIR} after a failed system command');
};

subtest 'sync_repo()' => sub {
    Sbozyp::sync_repo();
    ok(-d "$TEST_DIR/var/lib/sbozyp/SBo/.git",
       'clones SBo repo to $CONFIG{REPO_ROOT} if it has not yet been cloned'
    );
    ok(`git -C '$TEST_DIR/var/lib/sbozyp/SBo' branch --show-current` =~ /^14\.1$/,
       'clones branch specified by $CONFIG{REPO_GIT_BRANCH}'
    );

    system("git -C '$TEST_DIR/var/lib/sbozyp/SBo' checkout -b 14.2");
    Sbozyp::sync_repo();
    ok(`git -C '$TEST_DIR/var/lib/sbozyp/SBo' branch --show-current` =~ /^14\.1$/,
       're-clones if repo branch is not set to $CONFIG{REPO_GIT_BRANCH}'
    );

    # this is a fake test but there is no good way (that I can think of) to actually know if we are performing a git pull.
    Sbozyp::sync_repo(); pass('pulls repo if it is already cloned');
};

# add our mock packages to the SBo 14.1 repo we just cloned in the sync_repo() subtest
Sbozyp::sbozyp_copy("$FindBin::Bin/mock-packages", "$Sbozyp::CONFIG{REPO_ROOT}/misc");

subtest 'all_categories()' => sub {
    is([Sbozyp::all_categories()],
       ['academic','accessibility','audio','business','desktop','development','games','gis','graphics','ham','haskell','libraries','misc','multimedia','network','office','perl','python','ruby','system'],
       'returns correct package categories (sorted)'
    );
};

subtest 'all_pkgnames()' => sub {
    my @all_pkgnames = Sbozyp::all_pkgnames();
    ok(scalar(grep { $_ eq 'office/mu' } @all_pkgnames), 'returns list of pkgnames');
    ok(!scalar(grep /\.git/, @all_pkgnames), 'ignores .git');
};

subtest 'find_pkgname()' => sub {
    is(Sbozyp::find_pkgname('sbozyp-basic'), 'misc/sbozyp-basic', 'finds pkgname');
    is(Sbozyp::find_pkgname('misc/sbozyp-basic'), 'misc/sbozyp-basic', 'accepts full pkgname');
    ok(!defined Sbozyp::find_pkgname('NOTAPACKAGE'), 'returns undef if given non-existent prgnam');
    ok(!defined Sbozyp::find_pkgname('FOO/NOTAPACKAGE'), 'returns undef if given non-existent pkgname');
    ok(!defined Sbozyp::find_pkgname('perl/NOTAPACKAGE'), 'rejects pkgname with valid category');
    ok(!defined Sbozyp::find_pkgname('perl/mu'), 'rejects non-existent pkgname with valid category and valid prgnam');
    ok(!defined Sbozyp::find_pkgname('MU'), 'case sensitive');
    ok(!defined Sbozyp::find_pkgname(''), 'rejects empty string');
    ok(!defined Sbozyp::find_pkgname(' '), 'rejects blank string');
    ok(!defined Sbozyp::find_pkgname(), 'rejects undef');
};

subtest 'parse_info_file()' => sub {
    my $info_file = "$Sbozyp::CONFIG{REPO_ROOT}/misc/sbozyp-basic/sbozyp-basic.info";
    is({Sbozyp::parse_info_file($info_file)},
       {PRGNAM=>'sbozyp-basic',VERSION=>'1.0',HOMEPAGE=>'https://github.com/NicholasBHubbard/sbozyp/releases/tag/SbozypFakeRelease-1.0',DOWNLOAD=>'https://github.com/NicholasBHubbard/sbozyp/archive/refs/tags/SbozypFakeRelease-1.0.tar.gz',MD5SUM=>'1973a308d90831774a0922e9ec0085ff',DOWNLOAD_x86_64=>'',MD5SUM_x86_64=>'',REQUIRES=>'',MAINTAINER=>'Nicholas Hubbard',EMAIL=>'nicholashubbard@posteo.net'},
       'parses info file into correct hash'
    );

    $info_file = "$Sbozyp::CONFIG{REPO_ROOT}/misc/sbozyp-multiple-download/sbozyp-multiple-download.info";
    is({Sbozyp::parse_info_file($info_file)},
       {PRGNAM=>'sbozyp-multiple-download',VERSION=>'1.0',HOMEPAGE=>'https://github.com/NicholasBHubbard/sbozyp/releases/tag/SbozypFakeRelease-1.0',DOWNLOAD=>'https://github.com/NicholasBHubbard/sbozyp/archive/refs/tags/SbozypFakeRelease-1.0.tar.gz https://github.com/NicholasBHubbard/sbozyp/archive/refs/tags/SbozypFakeRelease-1.0.tar.gz https://github.com/NicholasBHubbard/sbozyp/archive/refs/tags/SbozypFakeRelease-1.0.tar.gz',MD5SUM=>'1973a308d90831774a0922e9ec0085ff 1973a308d90831774a0922e9ec0085ff 1973a308d90831774a0922e9ec0085ff',DOWNLOAD_x86_64=>'','MD5SUM_x86_64'=>'',REQUIRES=>'',MAINTAINER=>'Nicholas Hubbard',EMAIL=>'nicholashubbard@posteo.net'},
       'squishes newline-escapes into single spaces'
    );

    like(dies { Sbozyp::parse_info_file("$TEST_DIR/foo") },
         qr/^sbozyp: error: could not open file '\Q$TEST_DIR\E\/foo': No such file or directory$/,
         'dies with useful error if given non-existent info file'

    );
};

subtest 'pkg()' => sub {
    is({Sbozyp::pkg('misc/sbozyp-basic')},
       {PRGNAM=>'sbozyp-basic',DESC_FILE=>"$Sbozyp::CONFIG{REPO_ROOT}/misc/sbozyp-basic/slack-desc",INFO_FILE=>"$Sbozyp::CONFIG{REPO_ROOT}/misc/sbozyp-basic/sbozyp-basic.info",SLACKBUILD_FILE=>"$Sbozyp::CONFIG{REPO_ROOT}/misc/sbozyp-basic/sbozyp-basic.SlackBuild",README_FILE=>"$Sbozyp::CONFIG{REPO_ROOT}/misc/sbozyp-basic/README",PKGNAME=>'misc/sbozyp-basic',PKGDIR=>"$Sbozyp::CONFIG{REPO_ROOT}/misc/sbozyp-basic",VERSION=>'1.0',HOMEPAGE=>'https://github.com/NicholasBHubbard/sbozyp/releases/tag/SbozypFakeRelease-1.0',DOWNLOAD=>['https://github.com/NicholasBHubbard/sbozyp/archive/refs/tags/SbozypFakeRelease-1.0.tar.gz'],MD5SUM=>['1973a308d90831774a0922e9ec0085ff'],DOWNLOAD_x86_64=>[],MD5SUM_x86_64=>[],REQUIRES=>[],MAINTAINER=>'Nicholas Hubbard',EMAIL=>'nicholashubbard@posteo.net',ARCH_UNSUPPORTED=>0,HAS_EXTRA_DEPS=>0},
       'creates correct pkg hash'
    );

    is({Sbozyp::pkg('sbozyp-basic')},
       {PRGNAM=>'sbozyp-basic',DESC_FILE=>"$Sbozyp::CONFIG{REPO_ROOT}/misc/sbozyp-basic/slack-desc",INFO_FILE=>"$Sbozyp::CONFIG{REPO_ROOT}/misc/sbozyp-basic/sbozyp-basic.info",SLACKBUILD_FILE=>"$Sbozyp::CONFIG{REPO_ROOT}/misc/sbozyp-basic/sbozyp-basic.SlackBuild",README_FILE=>"$Sbozyp::CONFIG{REPO_ROOT}/misc/sbozyp-basic/README",PKGNAME=>'misc/sbozyp-basic',PKGDIR=>"$Sbozyp::CONFIG{REPO_ROOT}/misc/sbozyp-basic",VERSION=>'1.0',HOMEPAGE=>'https://github.com/NicholasBHubbard/sbozyp/releases/tag/SbozypFakeRelease-1.0',DOWNLOAD=>['https://github.com/NicholasBHubbard/sbozyp/archive/refs/tags/SbozypFakeRelease-1.0.tar.gz'],MD5SUM=>['1973a308d90831774a0922e9ec0085ff'],DOWNLOAD_x86_64=>[],MD5SUM_x86_64=>[],REQUIRES=>[],MAINTAINER=>'Nicholas Hubbard',EMAIL=>'nicholashubbard@posteo.net',ARCH_UNSUPPORTED=>0,HAS_EXTRA_DEPS=>0},
       'accepts just a prgnam'
    );

    is({Sbozyp::pkg('misc/sbozyp-readme-extra-deps')},
       {PRGNAM=>'sbozyp-readme-extra-deps',DESC_FILE=>"$Sbozyp::CONFIG{REPO_ROOT}/misc/sbozyp-readme-extra-deps/slack-desc",INFO_FILE=>"$Sbozyp::CONFIG{REPO_ROOT}/misc/sbozyp-readme-extra-deps/sbozyp-readme-extra-deps.info",SLACKBUILD_FILE=>"$Sbozyp::CONFIG{REPO_ROOT}/misc/sbozyp-readme-extra-deps/sbozyp-readme-extra-deps.SlackBuild",README_FILE=>"$Sbozyp::CONFIG{REPO_ROOT}/misc/sbozyp-readme-extra-deps/README",PKGNAME=>'misc/sbozyp-readme-extra-deps',PKGDIR=>"$Sbozyp::CONFIG{REPO_ROOT}/misc/sbozyp-readme-extra-deps",VERSION=>'1.0',HOMEPAGE=>'https://github.com/NicholasBHubbard/sbozyp/releases/tag/SbozypFakeRelease-1.0',DOWNLOAD=>['https://github.com/NicholasBHubbard/sbozyp/archive/refs/tags/SbozypFakeRelease-1.0.tar.gz'],MD5SUM=>['1973a308d90831774a0922e9ec0085ff'],DOWNLOAD_x86_64=>[],MD5SUM_x86_64=>[],REQUIRES=>['sbozyp-basic'],MAINTAINER=>'Nicholas Hubbard',EMAIL=>'nicholashubbard@posteo.net',ARCH_UNSUPPORTED=>0,HAS_EXTRA_DEPS=>1},
       'specifies HAS_EXTRA_DEPS=>1 if %README% is in .info files requires, and does not include %README% in the pkgs REQUIRES field'
    );

    my $is_x86_64 = Sbozyp::arch() eq 'x86_64';
    my $unsupported_pkgname = $is_x86_64 ? 'misc/sbozyp-unsupported-x86_64' : 'misc/sbozyp-unsupported-no-x86_64';
    my $unsupported_prgnam = basename($unsupported_pkgname);
    is({Sbozyp::pkg($unsupported_pkgname)},
       {PRGNAM=>$unsupported_prgnam,DESC_FILE=>"$Sbozyp::CONFIG{REPO_ROOT}/$unsupported_pkgname/slack-desc",INFO_FILE=>"$Sbozyp::CONFIG{REPO_ROOT}/$unsupported_pkgname/$unsupported_prgnam.info",SLACKBUILD_FILE=>"$Sbozyp::CONFIG{REPO_ROOT}/$unsupported_pkgname/$unsupported_prgnam.SlackBuild",README_FILE=>"$Sbozyp::CONFIG{REPO_ROOT}/$unsupported_pkgname/README",PKGNAME=>$unsupported_pkgname,PKGDIR=>"$Sbozyp::CONFIG{REPO_ROOT}/$unsupported_pkgname",VERSION=>'1.0',HOMEPAGE=>'https://github.com/NicholasBHubbard/sbozyp/releases/tag/SbozypFakeRelease-1.0',DOWNLOAD=> $is_x86_64 ? ['https://github.com/NicholasBHubbard/sbozyp/archive/refs/tags/SbozypFakeRelease-1.0.tar.gz'] : [],MD5SUM=> $is_x86_64 ? ['1973a308d90831774a0922e9ec0085ff'] : [],DOWNLOAD_x86_64=> $is_x86_64 ? ['UNSUPPORTED'] : ['https://github.com/NicholasBHubbard/sbozyp/archive/refs/tags/SbozypFakeRelease-1.0.tar.gz'],MD5SUM_x86_64=> $is_x86_64 ? [] : ['1973a308d90831774a0922e9ec0085ff'],REQUIRES=>[],MAINTAINER=>'Nicholas Hubbard',EMAIL=>'nicholashubbard@posteo.net',ARCH_UNSUPPORTED=>'unsupported',HAS_EXTRA_DEPS=>0},
       'creates correct pkg for package that is unsupported on this architecture'
    );

    is(ref(Sbozyp::pkg('system/password-store')), 'HASH', 'returns hashref in scalar context');

    like(dies { Sbozyp::pkg('FOO') },
         qr/^sbozyp: error: could not find a package named 'FOO'$/,
         'dies with useful error message if passed invalid prgnam'
    );
};

# subtest 'pkg_query()' => sub {
#     # used to mock STDIN
#     local *STDIN;
#     my $stdin;

#     open my $stdin, '<', \"1\n";

#     my ($stdout) = capture { Sbozyp::pkg_query(scalar(Sbozyp::pkg('office/mu'))) };

#     say "HERE:";
#     say "$stdout";

#     pass();
# };

subtest 'pkg_queue()' => sub {
    is([Sbozyp::pkg_queue(scalar(Sbozyp::pkg('misc/sbozyp-recursive-dep-E')))],
       [scalar(Sbozyp::pkg('misc/sbozyp-recursive-dep-E'))],
       'returns single elem list containing input package when it has no deps'
    );

    is([Sbozyp::pkg_queue(scalar(Sbozyp::pkg('misc/sbozyp-recursive-dep-B')))],
       [scalar(Sbozyp::pkg('misc/sbozyp-recursive-dep-D')), scalar(Sbozyp::pkg('misc/sbozyp-recursive-dep-B'))],
       'returns two elem list in correct order for pkg with single dependency'
    );

    is([Sbozyp::pkg_queue(scalar(Sbozyp::pkg('misc/sbozyp-recursive-dep-A')))],
       [scalar(Sbozyp::pkg('misc/sbozyp-recursive-dep-E')), scalar(Sbozyp::pkg('misc/sbozyp-recursive-dep-C')), scalar(Sbozyp::pkg('misc/sbozyp-recursive-dep-D')), scalar(Sbozyp::pkg('misc/sbozyp-recursive-dep-B')), scalar(Sbozyp::pkg('misc/sbozyp-recursive-dep-A'))],
       'resolves recursive dependencies'
    );

    is([Sbozyp::pkg_queue(scalar(Sbozyp::pkg('misc/sbozyp-readme-extra-deps')))],
       [scalar(Sbozyp::pkg('misc/sbozyp-basic')), scalar(Sbozyp::pkg('misc/sbozyp-readme-extra-deps'))],
       'does not trip up from %README% being in the .info files REQUIRES'
    );
};

subtest 'parse_slackware_pkgname()' => sub {
    is([Sbozyp::parse_slackware_pkgname('acpica-20220331-x86_64-1_SBo')],
       ['development/acpica', '20220331'],
       'parses non-hyphened pkgname'
    );

    is([Sbozyp::parse_slackware_pkgname('password-store-1.7.4-noarch-1_SBo')],
       ['system/password-store', '1.7.4'],
       'parses single-hyphened pkgname'
    );

    is([Sbozyp::parse_slackware_pkgname('perl-File-Copy-Recursive-0.2.3-x86_64-1_SBo')],
       ['perl/perl-File-Copy-Recursive', '0.2.3'],
       'parses many-hyphened pkgname'
    );

    is([Sbozyp::parse_slackware_pkgname('functools32-3.2.3_1-x86_64-1_SBo')],
       ['python/functools32', '3.2.3_1'],
       'parses pkgname containing numbers'
    );

    is([Sbozyp::parse_slackware_pkgname('python-e_dbus-12.2-x86_64-1_SBo')],
       ['libraries/python-e_dbus', '12.2'],
       'parses prgnam containing underscore'
    );

    is([Sbozyp::parse_slackware_pkgname('virtualbox-kernel-6.1.40_6.1.12-x86_64-1_SBo')],
       ['system/virtualbox-kernel', '6.1.40_6.1.12'],
       'parses version containing underscore'
    );

    is([Sbozyp::parse_slackware_pkgname('acpica-20220331-x86_64-1000_SBo')],
       ['development/acpica', '20220331'],
       'parses pkgname with multi-digit revision'
    );

    ok(!defined Sbozyp::parse_slackware_pkgname('acpica-20220331-x86_64-1'), q(rejects pkgname without '_SBo' tag));
};

subtest 'prepare_pkg()' => sub {
    my $pkg = Sbozyp::pkg('misc/sbozyp-basic');
    my $staging_dir = Sbozyp::prepare_pkg($pkg);
    is([Sbozyp::sbozyp_readdir($staging_dir)],
       ["$staging_dir/README","$staging_dir/SbozypFakeRelease-1.0.tar.gz","$staging_dir/sbozyp-basic.SlackBuild","$staging_dir/sbozyp-basic.info","$staging_dir/slack-desc"],
       'returns tmp dir containing all of the pkgs files and its downloaded source code'
    );

    $pkg = Sbozyp::pkg('misc/sbozyp-nested-dir');
    $staging_dir = Sbozyp::prepare_pkg($pkg);
    is([do { my @files; File::Find::find(sub { push @files, $File::Find::name if -f $File::Find::name }, "$staging_dir"); sort @files }],
       ["$staging_dir/README","$staging_dir/SbozypFakeRelease-1.0.tar.gz","$staging_dir/nested-dir/bar.txt","$staging_dir/nested-dir/foo.txt","$staging_dir/sbozyp-nested-dir.SlackBuild","$staging_dir/sbozyp-nested-dir.info","$staging_dir/slack-desc"],
       'includes files in nested directories of the package'
    );

    if (Sbozyp::arch() eq 'x86_64') {
        $pkg = Sbozyp::pkg('misc/sbozyp-unsupported-not-x86_64');
        $staging_dir = Sbozyp::prepare_pkg($pkg);
        is([Sbozyp::sbozyp_readdir($staging_dir)],
           ["$staging_dir/README","$staging_dir/SbozypFakeRelease-1.0.tar.gz","$staging_dir/sbozyp-unsupported-not-x86_64.SlackBuild","$staging_dir/sbozyp-unsupported-not-x86_64.info","$staging_dir/slack-desc"],
           'properly prepares package only supported on x86_64'
        );
    }

    $pkg = Sbozyp::pkg('misc/sbozyp-nonexistent-url');
    ok(dies { Sbozyp::prepare_pkg($pkg) },
       'dies if packages download url does not exist'
    );

    $pkg = Sbozyp::pkg('misc/sbozyp-md5sum-mismatch');
    like(dies { Sbozyp::prepare_pkg($pkg) },
         qr|^sbozyp: error: md5sum mismatch for 'https://github\.com/NicholasBHubbard/sbozyp/archive/refs/tags/SbozypFakeRelease-1\.0\.tar\.gz': expected '29b3a308d97831774aa926e94c00a59f': got '1973a308d90831774a0922e9ec0085ff'$|,
         'dies with useful error message if there is an md5sum mismatch'
    );
};

subtest 'build_slackware_pkg()' => sub {
    skip_all('build_slackware_pkg() requires root') unless $> == 0;
    url_exists_or_bail('http://download.savannah.gnu.org/releases/jcal/jcal-0.4.1.tar.gz');
    my $pkg = Sbozyp::pkg('libraries/jcal');
    is(Sbozyp::build_slackware_pkg($pkg),
       "$Sbozyp::CONFIG{TMPDIR}/jcal-0.4.1-x86_64-1_SBo.tgz",
       'successfully builds slackware pkg and outputs it to $CONFIG{TMPDIR}'
    );
};

subtest 'install_slackware_pkg()' => sub {
    skip_all('install_slackware_pkg() requires root') unless $> == 0;
    url_exists_or_bail('http://www.cpan.org/authors/id/A/AD/ADAMK/File-Which-1.09.tar.gz');

    my $pkg = Sbozyp::pkg('perl/perl-File-Which');
    my $slackware_pkg = Sbozyp::build_slackware_pkg($pkg);

    local $ENV{ROOT} = "$TEST_DIR/tmp_root"; # controls installpkg's install destination
    local $Sbozyp::CONFIG{CLEANUP} = 0;

    Sbozyp::install_slackware_pkg($slackware_pkg);
    ok(-f "$TEST_DIR/tmp_root/var/lib/pkgtools/packages/perl-File-Which-1.09-x86_64-1_SBo",
       'successfully installs slackware pkg'
    );
    ok(-f $slackware_pkg, 'does not remove the slackware package when $CONFIG{CLEANUP} is false');

    local $Sbozyp::CONFIG{CLEANUP} = 1;
    Sbozyp::install_slackware_pkg($slackware_pkg);
    ok(! -f $slackware_pkg, 'removes slackware package when $CONFIG{CLEANUP} is true');

    # update the slackbuild for perl-File-Which version 1.23 and install it to test that install_slackware_pkg() automatically upgrades old packages
    url_exists_or_bail('https://cpan.metacpan.org/authors/id/P/PL/PLICEASE/File-Which-1.23.tar.gz');
    open my $fh_r, '<', "$Sbozyp::CONFIG{REPO_ROOT}/perl/perl-File-Which/perl-File-Which.info" or die;
    open my $fh_w, '>', "$TEST_DIR/perl-File-Which.info.tmp" or die;
    while (<$fh_r>) {
        if    (/^VERSION=/)  { print $fh_w qq(VERSION="1.23"\n) }
        elsif (/^DOWNLOAD=/) { print $fh_w qq(DOWNLOAD="https://cpan.metacpan.org/authors/id/P/PL/PLICEASE/File-Which-1.23.tar.gz"\n) }
        elsif (/^MD5SUM=/)   { print $fh_w qq(MD5SUM="c8f054534c3c098dd7a0dada60aaae34"\n) }
        else                { print $fh_w $_ }
    }
    close $fh_r or die;
    close $fh_w or die;
    open $fh_r, '<', "$Sbozyp::CONFIG{REPO_ROOT}/perl/perl-File-Which/perl-File-Which.SlackBuild" or die;
    open $fh_w, '>', "$TEST_DIR/perl-File-Which.SlackBuild.tmp" or die;
    while (<$fh_r>) { if (/^VERSION=/) { print $fh_w 'VERSION=${VERSION:-1.23}',"\n" } else { print $fh_w $_ } }
    close $fh_r or die;
    close $fh_w or die;
    mv("$TEST_DIR/perl-File-Which.info.tmp","$Sbozyp::CONFIG{REPO_ROOT}/perl/perl-File-Which/perl-File-Which.info") or die;
    mv("$TEST_DIR/perl-File-Which.SlackBuild.tmp","$Sbozyp::CONFIG{REPO_ROOT}/perl/perl-File-Which/perl-File-Which.SlackBuild") or die;
    Sbozyp::install_slackware_pkg(Sbozyp::build_slackware_pkg(scalar(Sbozyp::pkg('perl/perl-File-Which', 'IGNORE_CACHE'))));
    ok(-f "$TEST_DIR/tmp_root/var/lib/pkgtools/packages/perl-File-Which-1.23-x86_64-1_SBo" && ! -f "$TEST_DIR/tmp_root/var/lib/pkgtools/packages/perl-File-Which-1.09-x86_64-1_SBo", 'upgrades pkg if we install a newer version of an existing pkg');
};

subtest 'remove_slackware_pkg()' => sub {
    skip_all('remove_slackware_pkg() requires root') unless $> == 0;

    local $ENV{ROOT} = "$TEST_DIR/tmp_root";

    # this slackware pkg is installed from the 'install_slackware_pkg()' subtest
    Sbozyp::remove_slackware_pkg('perl-File-Which-1.23-x86_64-1_SBo');
    ok(! -f "$TEST_DIR/tmp_root/var/lib/pkgtools/packages/perl-File-Which-1.23-x86_64-1_SBo",
       'successfully removes slackware pkg'
    );

    remove_tree("$TEST_DIR/tmp_root") or die;
};

subtest 'installed_sbo_pkgs()' => sub {
    skip_all('need root access so we can install pkgs with install_slackware_pkg()') unless $> == 0;

    url_exists_or_bail('www.cpan.org/authors/id/S/SA/SANKO/Readonly-2.00.tar.gz');
    url_exists_or_bail('http://search.cpan.org/CPAN/authors/id/E/ET/ETHER/Test-Pod-1.51.tar.gz');
    url_exists_or_bail('http://search.cpan.org/CPAN/authors/id/D/DO/DOY/Try-Tiny-0.22.tar.gz');

    local $ENV{ROOT} = "$TEST_DIR/tmp_root";

    Sbozyp::install_slackware_pkg(Sbozyp::build_slackware_pkg(scalar(Sbozyp::pkg('perl/perl-Readonly'))));
    Sbozyp::install_slackware_pkg(Sbozyp::build_slackware_pkg(scalar(Sbozyp::pkg('perl/perl-Test-Pod'))));
    Sbozyp::install_slackware_pkg(Sbozyp::build_slackware_pkg(scalar(Sbozyp::pkg('perl/perl-Try-Tiny'))));

    is({Sbozyp::installed_sbo_pkgs()},
       {'perl/perl-Readonly'=>'2.00','perl/perl-Test-Pod'=>'1.51','perl/perl-Try-Tiny'=>'0.22'},
       'finds all installed SBo pkgs (respecting $ENV{ROOT}) and returns a hash assocating their pkgname to their version'
    );

    mv("$TEST_DIR/tmp_root/var/lib/pkgtools/packages/perl-Try-Tiny-0.22-x86_64-1_SBo",
       "$TEST_DIR/tmp_root/var/lib/pkgtools/packages/perl-Try-Tiny-0.22-x86_64-1"
    ) or die;
    is({Sbozyp::installed_sbo_pkgs()},
       {'perl/perl-Readonly'=>'2.00','perl/perl-Test-Pod'=>'1.51'},
       q(only returns pkgs that have the '_SBo' tag)
    );
};

done_testing;
