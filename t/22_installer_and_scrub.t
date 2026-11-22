#!/usr/bin/env perl
use strict;
use warnings;

use Config ();
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use File::Spec ();
use File::Temp qw(tempdir);
use FindBin ();
use Test::More;

my $ROOT = abs_path(File::Spec->catdir($FindBin::RealBin, File::Spec->updir));
my $INSTALL_SH = File::Spec->catfile($ROOT, 'install.sh');
my $APP_SH     = File::Spec->catfile($ROOT, 'scripts', 'make-macos-app.sh');
my $DB2_SH     = File::Spec->catfile($ROOT, 'scripts', 'setup-db2-container.sh');
my $MANIFEST   = File::Spec->catfile($ROOT, 'MANIFEST');

my $BASH_BIN = ($^O eq 'darwin' && -x '/bin/bash') ? '/bin/bash' : 'bash';

sub run_cmd {
    my ($cmd_ref, %opts) = @_;
    my $tmp = tempdir(CLEANUP => 1);
    my $out_f = File::Spec->catfile($tmp, 'stdout.txt');
    my $err_f = File::Spec->catfile($tmp, 'stderr.txt');

    my $pid = fork();
    die "fork failed: $!" unless defined $pid;
    if ($pid == 0) {
        if (ref($opts{env}) eq 'HASH') {
            for my $k (keys %{ $opts{env} }) {
                if (defined $opts{env}{$k}) {
                    $ENV{$k} = $opts{env}{$k};
                }
                else {
                    delete $ENV{$k};
                }
            }
        }
        open STDIN,  '<', File::Spec->devnull() or exit 126;
        open STDOUT, '>', $out_f                or exit 126;
        open STDERR, '>', $err_f                or exit 126;
        { no warnings 'exec'; exec @$cmd_ref; }
        exit 127;
    }
    waitpid($pid, 0);
    my $exit_code = ($? == -1) ? -1 : ($? >> 8);
    my $stdout = _slurp($out_f);
    my $stderr = _slurp($err_f);
    return {
        ok        => ($exit_code == 0) ? 1 : 0,
        exit_code => $exit_code,
        stdout    => $stdout,
        stderr    => $stderr,
    };
}

sub _slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return '';
    local $/;
    my $data = <$fh>;
    close $fh;
    return defined($data) ? $data : '';
}

# =========================================================================
# Subtest 1: Bash 3.2 syntax & BSD/GNU portability checks
# =========================================================================
subtest 'bash syntax and bash 3.2 / BSD portability' => sub {
    for my $pair (
        [ 'install.sh',                 $INSTALL_SH ],
        [ 'scripts/make-macos-app.sh',  $APP_SH ],
        [ 'scripts/setup-db2-container.sh', $DB2_SH ],
    ) {
        my ($label, $path) = @$pair;
        ok(-f $path, "$label exists");
        ok(-x $path, "$label is executable");

        my $r = run_cmd([ $BASH_BIN, '-n', $path ]);
        ok($r->{ok}, "$label passes $BASH_BIN -n")
            or diag("stderr: $r->{stderr}");
        is($r->{stderr}, '', "$label has zero bash -n warnings");

        my $src = _slurp($path);
        my $code = join("\n", grep { !/^\s*#/ } split(/\r?\n/, $src));
        like($src,  qr/Author:\s*stratum42/, "$label carries stratum42 attribution");
        unlike($code, qr/\bdeclare\s+-A\b/,   "$label avoids bash 4+ associative arrays");
        unlike($code, qr/\$\{[A-Za-z0-9_]+(?:,,|\^\^)\}/, "$label avoids bash 4+ case conversion");
        unlike($code, qr/\breadlink\s+-f\b/,  "$label avoids GNU-only readlink -f");
        unlike($code, qr/\bstat\s+-c\b/,      "$label avoids GNU-only stat -c");
        unlike($code, qr/\bdate\s+-d\b/,      "$label avoids GNU-only date -d");
        unlike($code, qr/\bsed\s+-i\b/,       "$label avoids non-portable sed -i");
        unlike($code, qr/\b(?:mapfile|readarray)\b/, "$label avoids bash 4+ mapfile/readarray");
    }
};

# =========================================================================
# Subtest 2: install.sh --help, --version, and --dry-run across 4 OS/arch profiles
# =========================================================================
subtest 'install.sh --help and --dry-run across 4 OS/arch profiles' => sub {
    my $help = run_cmd([ $BASH_BIN, $INSTALL_SH, '--help' ]);
    ok($help->{ok}, 'install.sh --help exits 0') or diag($help->{stderr});
    for my $flag (qw(
        --prefix --source-dir --repo-base --components --use-existing-perl
        --no-pgo --power-cpu --path-mode --install-app --install-agy
        --setup-db2 --with-cpan-tools --with-fonts --uninstall --dry-run
    )) {
        like($help->{stdout}, qr/\Q$flag\E/, "--help documents $flag");
    }

    my $ver = run_cmd([ $BASH_BIN, $INSTALL_SH, '--version' ]);
    ok($ver->{ok}, 'install.sh --version exits 0');
    like($ver->{stdout}, qr/neoperl-mt install\.sh \d+\.\d+/, '--version format valid');

    # Profile A: macOS arm64 (Clang 2-stage PGO, Metal, .app, agy, Db2)
    my $mac = run_cmd(
        [
            $BASH_BIN, $INSTALL_SH, '--dry-run', '--yes',
            '--target-os=darwin', '--target-arch=arm64',
            '--prefix=/tmp/npl-test-mac',
            '--install-app', '--app-dir=/tmp/npl-test-apps',
            '--install-agy', '--setup-db2',
        ],
        env => { CC => undef },
    );
    ok($mac->{ok}, 'darwin/arm64 --dry-run exits 0') or diag($mac->{stderr});
    like($mac->{stdout}, qr/Target:\s+darwin\/arm64/,               'darwin/arm64 target detected');
    like($mac->{stdout}, qr/family=clang/,                          'darwin/arm64 uses Clang');
    like($mac->{stdout}, qr/-fprofile-instr-generate=<dir>\/%p\.profraw/, 'darwin/arm64 Clang stage-1 PGO flag');
    like($mac->{stdout}, qr/llvm-profdata merge -output=<dir>\/merged\.profdata/, 'darwin/arm64 llvm-profdata merge');
    like($mac->{stdout}, qr/-fprofile-instr-use=<dir>\/merged\.profdata -Wno-profile-instr-unprofiled -Wno-profile-instr-out-of-date/, 'darwin/arm64 Clang stage-2 PGO flags');
    like($mac->{stdout}, qr/Local AI:\s+enabled \(metal accelerator detected\)/, 'darwin/arm64 detects Metal accelerator');
    like($mac->{stdout}, qr/agy CLI:\s+yes/,                        'darwin/arm64 honors --install-agy');
    like($mac->{stdout}, qr/Db2 container:\s+yes/,                  'darwin/arm64 honors --setup-db2');
    like($mac->{stdout}, qr/App launcher:\s+yes \(\/tmp\/npl-test-apps\/NeoPerl\.app\)/, 'darwin/arm64 honors --install-app');

    # --no-pgo fallback check
    my $nopgo = run_cmd(
        [
            $BASH_BIN, $INSTALL_SH, '--dry-run', '--yes', '--no-pgo',
            '--target-os=darwin', '--target-arch=arm64',
        ],
        env => { CC => undef },
    );
    ok($nopgo->{ok}, '--no-pgo --dry-run exits 0');
    like($nopgo->{stdout}, qr/disabled \(--no-pgo\); compiling with -O3/, '--no-pgo falls back cleanly to -O3');

    # PATH modes check
    for my $pm (qw(local usr-local shell-rc none)) {
        my $r = run_cmd([
            $BASH_BIN, $INSTALL_SH, '--dry-run', '--yes',
            '--target-os=linux', '--target-arch=amd64',
            "--path-mode=$pm",
        ]);
        ok($r->{ok}, "--path-mode=$pm accepted");
        like($r->{stdout}, qr/PATH mode:\s+\Q$pm\E\b/, "--path-mode=$pm reported");
    }
    my $bad_pm = run_cmd([ $BASH_BIN, $INSTALL_SH, '--dry-run', '--path-mode=invalid' ]);
    ok(!$bad_pm->{ok}, 'invalid --path-mode rejected');

    # Profile B: Linux amd64 (GCC 2-stage PGO + CC=clang override)
    my $lin_amd = run_cmd(
        [
            $BASH_BIN, $INSTALL_SH, '--dry-run', '--yes',
            '--target-os=linux', '--target-arch=amd64',
            '--install-app', '--path-mode=shell-rc',
        ],
        env => { CC => undef },
    );
    ok($lin_amd->{ok}, 'linux/amd64 --dry-run exits 0') or diag($lin_amd->{stderr});
    like($lin_amd->{stdout}, qr/Target:\s+linux\/amd64/,            'linux/amd64 target detected');
    like($lin_amd->{stdout}, qr/family=gcc/,                        'linux/amd64 defaults to GCC');
    like($lin_amd->{stdout}, qr/-fprofile-generate=<dir>/,          'linux/amd64 GCC stage-1 PGO flag');
    like($lin_amd->{stdout}, qr/-fprofile-use=<dir> -fprofile-correction -Wno-missing-profile/, 'linux/amd64 GCC stage-2 PGO flags');
    like($lin_amd->{stdout}, qr/neoperl\.desktop/,                  'linux/amd64 reports .desktop launcher');

    my $lin_clang = run_cmd(
        [
            $BASH_BIN, $INSTALL_SH, '--dry-run', '--yes',
            '--target-os=linux', '--target-arch=amd64',
        ],
        env => { CC => 'clang' },
    );
    ok($lin_clang->{ok}, 'linux/amd64 with CC=clang --dry-run exits 0') or diag($lin_clang->{stderr});
    like($lin_clang->{stdout}, qr/Compiler:\s+clang \(family=clang/, 'CC=clang switches Linux compiler family to clang');

    # Profile C: Linux arm64 (--components subset + --use-existing-perl)
    my $lin_arm = run_cmd(
        [
            $BASH_BIN, $INSTALL_SH, '--dry-run', '--yes',
            '--target-os=linux', '--target-arch=arm64',
            '--components=mojo,neoperl',
            "--use-existing-perl=$^X",
        ],
        env => { CC => undef },
    );
    ok($lin_arm->{ok}, 'linux/arm64 --dry-run exits 0') or diag($lin_arm->{stderr});
    like($lin_arm->{stdout}, qr/Target:\s+linux\/arm64/,            'linux/arm64 target detected');
    like($lin_arm->{stdout}, qr/Components:\s+mojo neoperl\b/,      'linux/arm64 respects component subset order');
    like($lin_arm->{stdout}, qr/--use-existing-perl/,               'linux/arm64 honors --use-existing-perl');

    # Profile D: Linux ppc64le (POWER8 default + POWER10 -mmma + Local AI skipped)
    my $ppc8 = run_cmd(
        [
            $BASH_BIN, $INSTALL_SH, '--dry-run', '--yes',
            '--target-os=linux', '--target-arch=ppc64le',
        ],
        env => { CC => undef },
    );
    ok($ppc8->{ok}, 'linux/ppc64le --dry-run exits 0') or diag($ppc8->{stderr});
    like($ppc8->{stdout}, qr/Target:\s+linux\/ppc64le \(page_size=65536\)/, 'ppc64le detects 64 KiB page size');
    like($ppc8->{stdout}, qr/NEOPERL_POWER_CPU=power8 \(-mcpu=power8 -mvsx\)/, 'ppc64le defaults to power8 -mvsx');
    like($ppc8->{stdout}, qr/Local AI:\s+skipped \(POWER \(ppc64le\) host/, 'ppc64le skips local AI cleanly');
    like($ppc8->{stdout}, qr/NEOPERL_EMBED_URL.*NEOPERL_HYMEM_URL/s,        'ppc64le prints remote inference URLs');

    my $ppc10 = run_cmd(
        [
            $BASH_BIN, $INSTALL_SH, '--dry-run', '--yes',
            '--target-os=linux', '--target-arch=ppc64le',
            '--power-cpu=power10',
        ],
        env => { CC => undef },
    );
    ok($ppc10->{ok}, 'linux/ppc64le --power-cpu=power10 exits 0');
    like($ppc10->{stdout}, qr/NEOPERL_POWER_CPU=power10 \(-mcpu=power10 -mvsx -mmma\)/, 'power10 enables -mmma');

    # Uninstall dry-run and safety guard
    my $un_dry = run_cmd([
        $BASH_BIN, $INSTALL_SH, '--uninstall', '--dry-run', '--yes',
        '--prefix=/tmp/neoperl-dry-uninstall-check',
    ]);
    ok($un_dry->{ok}, '--uninstall --dry-run exits 0');
    like($un_dry->{stdout}, qr/rm -rf \/tmp\/neoperl-dry-uninstall-check/, '--uninstall --dry-run plans prefix removal');

    my $un_bad = run_cmd([ $BASH_BIN, $INSTALL_SH, '--uninstall', '--dry-run', '--yes', '--prefix=/' ]);
    ok(!$un_bad->{ok}, '--uninstall refuses unsafe prefix /');
};

# =========================================================================
# Subtest 3: LIVE scripts/make-macos-app.sh into a temporary directory
# =========================================================================
subtest 'make-macos-app.sh live bundle creation and launcher check' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    my $prefix = File::Spec->catdir($tmp, 'prefix');
    my $apps   = File::Spec->catdir($tmp, 'apps');
    mkdir $prefix or die "mkdir $prefix: $!";
    mkdir File::Spec->catdir($prefix, 'bin') or die "mkdir bin: $!";

    # Create stub npl binary to verify launcher argument forwarding & -psn_* stripping
    my $stub_npl = File::Spec->catfile($prefix, 'bin', 'npl');
    open my $sfh, '>', $stub_npl or die "write $stub_npl: $!";
    print {$sfh} "#!/bin/sh\nfor a in \"\$@\"; do printf '[%s]\\n' \"\$a\"; done\n";
    close $sfh;
    chmod 0755, $stub_npl;

    my $r = run_cmd([ $BASH_BIN, $APP_SH, "--prefix=$prefix", "--app-dir=$apps" ]);
    ok($r->{ok}, 'make-macos-app.sh live run exits 0') or diag($r->{stderr});

    my $bundle   = File::Spec->catdir($apps, 'NeoPerl.app');
    my $plist    = File::Spec->catfile($bundle, 'Contents', 'Info.plist');
    my $launcher = File::Spec->catfile($bundle, 'Contents', 'MacOS', 'NeoPerl');
    my $icns     = File::Spec->catfile($bundle, 'Contents', 'Resources', 'NeoPerl.icns');
    my $png_fb   = File::Spec->catfile($bundle, 'Contents', 'Resources', 'NeoPerl.png');

    ok(-f $plist,    'Info.plist created');
    ok(-f $launcher, 'Contents/MacOS/NeoPerl created');
    ok(-x $launcher, 'Contents/MacOS/NeoPerl is executable');

    my $plist_txt = _slurp($plist);
    like($plist_txt, qr/<key>CFBundleName<\/key>\s*<string>NeoPerl<\/string>/s, 'CFBundleName=NeoPerl');
    like($plist_txt, qr/<key>CFBundleDisplayName<\/key>\s*<string>NeoPerl<\/string>/s, 'CFBundleDisplayName=NeoPerl');
    like($plist_txt, qr/<key>CFBundleIdentifier<\/key>\s*<string>org\.stratum42\.neoperl-mt<\/string>/s, 'CFBundleIdentifier set');
    like($plist_txt, qr/<key>CFBundleExecutable<\/key>\s*<string>NeoPerl<\/string>/s, 'CFBundleExecutable=NeoPerl');
    like($plist_txt, qr/<key>CFBundleIconFile<\/key>\s*<string>NeoPerl<\/string>/s, 'CFBundleIconFile=NeoPerl');
    like($plist_txt, qr/<key>NSHighResolutionCapable<\/key>\s*<true\/>/s, 'NSHighResolutionCapable=true');
    like($plist_txt, qr/<key>CFBundleDocumentTypes<\/key>/, 'CFBundleDocumentTypes declared');

    if ($^O eq 'darwin') {
        my $lint = run_cmd([ 'plutil', '-lint', $plist ]);
        ok($lint->{ok}, 'plutil -lint validates Info.plist on macOS') or diag($lint->{stdout} . $lint->{stderr});

        ok(-f $icns, 'NeoPerl.icns generated on macOS via iconutil');
        my $icns_bytes = _slurp($icns);
        cmp_ok(length($icns_bytes), '>', 1024, 'NeoPerl.icns is non-trivial');
        is(substr($icns_bytes, 0, 4), 'icns', 'NeoPerl.icns starts with valid icns magic header');
    }
    else {
        ok(-f $icns || -f $png_fb, 'icon asset generated (icns or PNG fallback)');
        if (-f $icns) {
            is(substr(_slurp($icns), 0, 4), 'icns', 'NeoPerl.icns starts with icns magic');
        }
        else {
            is(substr(_slurp($png_fb), 0, 8), "\x89PNG\r\n\x1a\n", 'fallback NeoPerl.png starts with valid PNG magic');
        }
    }

    my $sh_chk = run_cmd([ '/bin/sh', '-n', $launcher ]);
    ok($sh_chk->{ok}, 'Contents/MacOS/NeoPerl passes /bin/sh -n');

    my $launch_test = run_cmd([ $launcher, '-psn_0_98765', 'hello world.pl', '--theme=aix_amber' ]);
    ok($launch_test->{ok}, 'launcher invokes prefix npl cleanly') or diag($launch_test->{stderr});
    is(
        $launch_test->{stdout},
        "[--gpu]\n[hello world.pl]\n[--theme=aix_amber]\n",
        'launcher strips -psn_* and forwards --gpu and spaced file args intact',
    );
};

# =========================================================================
# Subtest 4: scripts/setup-db2-container.sh --dry-run across 3 profiles
# =========================================================================
subtest 'setup-db2-container.sh --dry-run across darwin/arm64, linux/amd64, linux/ppc64le' => sub {
    my $help = run_cmd([ $BASH_BIN, $DB2_SH, '--help' ]);
    ok($help->{ok}, 'setup-db2-container.sh --help exits 0');

    my $src = _slurp($DB2_SH);
    unlike($src, qr/DB2INST1_PASSWORD=(?!\$\{DB2_PASSWORD\}|<generated>|"\$\{DB2_PASSWORD\}")[^\s"]+/, 'no hardcoded Db2 password');

    # Profile 1: darwin/arm64
    my $mac = run_cmd([
        $BASH_BIN, $DB2_SH, '--dry-run',
        '--target-os=darwin', '--target-arch=arm64',
        '--prefix=/tmp/npl-db2-test',
        '--port=50000', '--db-name=NEOPERL',
    ]);
    ok($mac->{ok}, 'setup-db2-container.sh darwin/arm64 --dry-run exits 0') or diag($mac->{stderr});
    like($mac->{stdout}, qr/--platform linux\/amd64/,          'darwin/arm64 adds --platform linux/amd64');
    like($mac->{stdout}, qr/Rosetta/i,                         'darwin/arm64 notes Rosetta emulation');
    like($mac->{stdout}, qr/icr\.io\/db2_community\/db2/,      'uses official Db2 Community image');
    like($mac->{stdout}, qr/LICENSE=accept/,                   'passes LICENSE=accept');
    like($mac->{stdout}, qr/db2_memory\.sql/,                  'plans db2_memory.sql schema apply');
    like($mac->{stdout}, qr/db2\.env \(mode 0600\)/,           'plans mode 0600 db2.env');
    like($mac->{stdout}, qr/odbc\.ini \(\[NEOPERL_MEM\]/,      'plans [NEOPERL_MEM] odbc.ini');
    like($mac->{stdout}, qr/npl-db2-ctl/,                      'plans npl-db2-ctl control helper');

    # Profile 2: linux/amd64
    my $lin = run_cmd([
        $BASH_BIN, $DB2_SH, '--dry-run',
        '--target-os=linux', '--target-arch=amd64',
        '--prefix=/tmp/npl-db2-test',
    ]);
    ok($lin->{ok}, 'setup-db2-container.sh linux/amd64 --dry-run exits 0') or diag($lin->{stderr});
    like($lin->{stdout},   qr/native linux\/amd64/,            'linux/amd64 runs natively');
    unlike($lin->{stdout}, qr/--platform linux\/amd64/,        'linux/amd64 omits unnecessary emulation flag');
    like($lin->{stdout},   qr/neoperl-db2-data:\/database/,    'mounts persistent neoperl-db2-data volume');

    # Profile 3: linux/ppc64le
    my $ppc = run_cmd([
        $BASH_BIN, $DB2_SH, '--dry-run',
        '--target-os=linux', '--target-arch=ppc64le',
        '--prefix=/tmp/npl-db2-test',
    ]);
    ok($ppc->{ok}, 'setup-db2-container.sh linux/ppc64le exits 0 cleanly') or diag($ppc->{stderr});
    like($ppc->{stdout}, qr/linux\/amd64/,                     'ppc64le explains linux/amd64 image limitation');
    like($ppc->{stdout}, qr/NEOPERL_DB2_DSN/,                  'ppc64le prints remote DSN setup instructions');
    like($ppc->{stdout}, qr/\[NEOPERL_MEM\]/,                  'ppc64le prints [NEOPERL_MEM] ODBC template');
};

# =========================================================================
# Subtest 5: Deep-scrub hygiene audit across MANIFEST tracked files
# =========================================================================
subtest 'deep-scrub hygiene audit across MANIFEST' => sub {
    ok(-f $MANIFEST, 'MANIFEST file exists');

    my %seen;
    my @files;
    if (open my $mfh, '<', $MANIFEST) {
        while (my $line = <$mfh>) {
            $line =~ s/\r?\n$//;
            $line =~ s/\s+.*$//;
            next unless length $line;
            next if $seen{$line}++;
            push @files, $line;
        }
        close $mfh;
    }

    # Always include the new installer/helper scripts even before MANIFEST update
    for my $extra ('install.sh', 'scripts/make-macos-app.sh', 'scripts/setup-db2-container.sh') {
        next if $seen{$extra}++;
        push @files, $extra if -f File::Spec->catfile($ROOT, $extra);
    }

    my @rules = (
        [ 'hardcoded_users_path', qr{/Users/[A-Za-z0-9_.-]+} ],
        [ 'hardcoded_home_path',  qr{/home/[A-Za-z0-9_.-]+/(?:dev|src|work|Developer)\b} ],
        [ 'private_rfc1918_ip',   qr/\b(?:192\.168\.\d+\.\d+|10\.\d+\.\d+\.\d+)\b/ ],
        [ 'personal_email',       qr/\b[A-Za-z0-9._%+-]+\@(?:gmail|yahoo|hotmail|icloud|outlook|proton)\.[A-Za-z]{2,}\b/i ],
        [ 'ai_bleedthrough',      qr/\b(?:phase\s+[0-9]+|wave\s+[0-9]+|subagent|swarm|coordinator|as\s+requested|upgraded\s+from\s+stub)\b/i ],
        [ 'marketing_hype',       qr/\b(?:blazing|revolutionary|ultimate|next-gen|world-class|game-changing|supercharged|rock-solid|zero-compromise|cutting-edge|insane)\b/i ],
        [ 'hype_aaa',             qr/\bAAA\b/ ],
    );

    my @violations;
    my $scanned = 0;

    for my $rel (@files) {
        # Exclude this test file (contains the audit regex definitions above)
        next if $rel eq 't/22_installer_and_scrub.t';
        my $abs = File::Spec->catfile($ROOT, $rel);
        next unless -f $abs && -T $abs;
        $scanned++;

        open my $fh, '<', $abs or next;
        my $lineno = 0;
        while (my $line = <$fh>) {
            $lineno++;
            for my $rule (@rules) {
                my ($name, $re) = @$rule;
                if ($line =~ $re) {
                    my $snippet = $line;
                    $snippet =~ s/^\s+|\s+$//g;
                    $snippet = substr($snippet, 0, 100) if length($snippet) > 100;
                    push @violations, "$rel:$lineno [$name] $snippet";
                }
            }
        }
        close $fh;
    }

    cmp_ok($scanned, '>', 50, "scanned $scanned tracked text files");
    is(scalar(@violations), 0, 'zero PII, internal hostnames/IPs, hardcoded paths, AI bleedthrough, or marketing hype')
        or diag("Remaining scrub hits (" . scalar(@violations) . "):\n  " . join("\n  ", @violations[0 .. ($#violations > 39 ? 39 : $#violations)]));
};

done_testing();
