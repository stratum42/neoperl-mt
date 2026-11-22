#!/usr/bin/env bash
# make-macos-app.sh - Build native macOS NeoPerl.app bundle
# Author: stratum42

set -euo pipefail

APP_NAME="NeoPerl"
PREFIX="${HOME}/.local/neoperl"
APP_DIR="/Applications"
DRY_RUN=0

usage() {
    cat <<'EOF'
Usage: make-macos-app.sh [options]

Build a macOS NeoPerl.app launcher bundle with Info.plist, amber-on-black
NPL terminal iconset (NeoPerl.icns), and Contents/MacOS/NeoPerl launcher.

Options:
  --prefix=DIR     NeoPerl installation prefix (default: $HOME/.local/neoperl)
  --app-dir=DIR    Target directory for NeoPerl.app (default: /Applications)
  --name=NAME      Application bundle base name (default: NeoPerl)
  -n, --dry-run    Show planned actions without writing files
  -h, --help       Show this help message
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --prefix=*)
            PREFIX="${1#*=}"
            ;;
        --prefix)
            shift
            [ "$#" -gt 0 ] || { printf 'error: --prefix requires a directory\n' >&2; exit 1; }
            PREFIX="$1"
            ;;
        --app-dir=*)
            APP_DIR="${1#*=}"
            ;;
        --app-dir)
            shift
            [ "$#" -gt 0 ] || { printf 'error: --app-dir requires a directory\n' >&2; exit 1; }
            APP_DIR="$1"
            ;;
        --name=*)
            APP_NAME="${1#*=}"
            ;;
        --name)
            shift
            [ "$#" -gt 0 ] || { printf 'error: --name requires a value\n' >&2; exit 1; }
            APP_NAME="$1"
            ;;
        -n|--dry-run)
            DRY_RUN=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'error: unknown option: %s\n' "$1" >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

# Strip trailing slashes (except root '/')
while [ "${#PREFIX}" -gt 1 ] && [ "${PREFIX%/}" != "$PREFIX" ]; do
    PREFIX="${PREFIX%/}"
done
while [ "${#APP_DIR}" -gt 1 ] && [ "${APP_DIR%/}" != "$APP_DIR" ]; do
    APP_DIR="${APP_DIR%/}"
done

APP_BUNDLE="${APP_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
PLIST_PATH="${CONTENTS_DIR}/Info.plist"
LAUNCHER_PATH="${MACOS_DIR}/${APP_NAME}"
ICNS_PATH="${RESOURCES_DIR}/${APP_NAME}.icns"

if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] macOS app bundle plan:\n'
    printf '  Bundle:      %s\n' "$APP_BUNDLE"
    printf '  Prefix:      %s\n' "$PREFIX"
    printf '  Info.plist:  %s (CFBundleIdentifier=org.stratum42.neoperl-mt)\n' "$PLIST_PATH"
    printf '  Launcher:    %s -> exec "%s/bin/npl" --gpu "$@"\n' "$LAUNCHER_PATH" "$PREFIX"
    if command -v iconutil >/dev/null 2>&1; then
        printf '  Icon:        %s (pure-Perl PNG iconset + iconutil -c icns)\n' "$ICNS_PATH"
    else
        printf '  Icon:        %s/NeoPerl.png (iconutil unavailable; skipping .icns conversion)\n' "$RESOURCES_DIR"
    fi
    exit 0
fi

# Verify perl is available for pure-Perl PNG iconset generation
PERL_GEN=""
if [ -x "${PREFIX}/bin/perl" ]; then
    PERL_GEN="${PREFIX}/bin/perl"
elif command -v perl >/dev/null 2>&1; then
    PERL_GEN="$(command -v perl)"
else
    printf 'error: perl is required to generate the NeoPerl iconset\n' >&2
    exit 1
fi

if [ ! -d "$APP_DIR" ]; then
    if ! mkdir -p "$APP_DIR" 2>/dev/null; then
        printf 'error: cannot create %s (try --app-dir="%s/Applications")\n' "$APP_DIR" "$HOME" >&2
        exit 1
    fi
fi

if [ ! -w "$APP_DIR" ]; then
    printf 'error: %s is not writable (try --app-dir="%s/Applications" or run with elevated privileges)\n' "$APP_DIR" "$HOME" >&2
    exit 1
fi

TMP_WORK="$(mktemp -d "${TMPDIR:-/tmp}/neoperl-app.XXXXXX")"
cleanup() {
    rm -rf "$TMP_WORK"
}
trap cleanup EXIT

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

# 1. Write Contents/Info.plist
cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>org.stratum42.neoperl-mt</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.01</string>
    <key>CFBundleVersion</key>
    <string>0.01</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Source Code</string>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.source-code</string>
                <string>public.plain-text</string>
                <string>public.perl-script</string>
                <string>public.shell-script</string>
            </array>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>pl</string>
                <string>pm</string>
                <string>t</string>
                <string>xs</string>
                <string>c</string>
                <string>h</string>
                <string>sql</string>
                <string>md</string>
                <string>sh</string>
                <string>cob</string>
                <string>cbl</string>
                <string>s</string>
                <string>asm</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Folder</string>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.folder</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
EOF

# 2. Generate pure-black (#000000) + amber phosphor (#ffb000) retro terminal NPL iconset
ICONSET_DIR="${TMP_WORK}/${APP_NAME}.iconset"
mkdir -p "$ICONSET_DIR"

( unset PERL5LIB PERL5OPT; "$PERL_GEN" - "$ICONSET_DIR" ) <<'PERL_ICON_EOF'
use strict;
use warnings;
use Compress::Zlib ();

my $out_dir = shift @ARGV or die "missing iconset directory\n";

# Standard IEEE 802.3 CRC-32 table for PNG chunks
my @CRC_TABLE;
for my $n (0 .. 255) {
    my $c = $n;
    for (0 .. 7) {
        $c = ($c & 1) ? (0xedb88320 ^ ($c >> 1)) : ($c >> 1);
    }
    $CRC_TABLE[$n] = $c;
}

sub png_crc32 {
    my ($bytes) = @_;
    my $c = 0xffffffff;
    for my $b (unpack('C*', $bytes)) {
        $c = $CRC_TABLE[($c ^ $b) & 0xff] ^ ($c >> 8);
    }
    return ($c ^ 0xffffffff) & 0xffffffff;
}

sub png_chunk {
    my ($type, $data) = @_;
    my $crc = png_crc32($type . $data);
    return pack('N', length($data)) . $type . $data . pack('N', $crc);
}

sub write_rgba_png {
    my ($path, $w, $h, $rows_ref) = @_;
    my $raw = '';
    for my $r (@$rows_ref) {
        $raw .= "\x00" . $r;
    }
    my $ihdr = pack('NNCCCCC', $w, $h, 8, 6, 0, 0, 0);
    my $idat = Compress::Zlib::compress($raw, 6);
    my $png  = "\x89PNG\r\n\x1a\n"
             . png_chunk('IHDR', $ihdr)
             . png_chunk('IDAT', $idat)
             . png_chunk('IEND', '');
    open my $fh, '>:raw', $path or die "cannot write $path: $!\n";
    print {$fh} $png;
    close $fh or die "close $path: $!\n";
}

# 5x7 pixel font for N, P, L
my %GLYPH = (
    N => [
        '10001',
        '11001',
        '10101',
        '10011',
        '10001',
        '10001',
        '10001',
    ],
    P => [
        '11110',
        '10001',
        '10001',
        '11110',
        '10000',
        '10000',
        '10000',
    ],
    L => [
        '10000',
        '10000',
        '10000',
        '10000',
        '10000',
        '10000',
        '11111',
    ],
);

# Palette (R, G, B, A)
my $C_TRANS  = pack('CCCC', 0x00, 0x00, 0x00, 0x00);
my $C_BLACK  = pack('CCCC', 0x00, 0x00, 0x00, 0xff);
my $C_SCAN   = pack('CCCC', 0x0a, 0x07, 0x00, 0xff);
my $C_BEZEL  = pack('CCCC', 0x4a, 0x30, 0x00, 0xff);
my $C_GLOW   = pack('CCCC', 0x7a, 0x52, 0x00, 0xff);
my $C_AMBER  = pack('CCCC', 0xff, 0xb0, 0x00, 0xff);
my $C_BRIGHT = pack('CCCC', 0xff, 0xc9, 0x40, 0xff);

# Render a 128x128 master icon grid
my $M = 128;
my @grid = map { [ ($C_TRANS) x $M ] } (0 .. $M - 1);

my $pad = 8;
my $rad = 22;
my $x0  = $pad;
my $y0  = $pad;
my $x1  = $M - 1 - $pad;
my $y1  = $M - 1 - $pad;

sub inside_rounded {
    my ($x, $y, $lx, $ly, $rx, $ry, $r) = @_;
    return 0 if $x < $lx || $x > $rx || $y < $ly || $y > $ry;
    my $dx = 0;
    my $dy = 0;
    if ($x < $lx + $r)    { $dx = ($lx + $r) - $x; }
    elsif ($x > $rx - $r) { $dx = $x - ($rx - $r); }
    if ($y < $ly + $r)    { $dy = ($ly + $r) - $y; }
    elsif ($y > $ry - $r) { $dy = $y - ($ry - $r); }
    return ($dx * $dx + $dy * $dy) <= ($r * $r);
}

# Base rounded pure-black terminal body + bezel + phosphor border + scanlines
for my $y (0 .. $M - 1) {
    for my $x (0 .. $M - 1) {
        next unless inside_rounded($x, $y, $x0, $y0, $x1, $y1, $rad);
        if (!inside_rounded($x, $y, $x0 + 2, $y0 + 2, $x1 - 2, $y1 - 2, $rad - 2)) {
            $grid[$y][$x] = $C_BEZEL;
        }
        elsif (!inside_rounded($x, $y, $x0 + 5, $y0 + 5, $x1 - 5, $y1 - 5, $rad - 4)) {
            $grid[$y][$x] = $C_AMBER;
        }
        elsif (!inside_rounded($x, $y, $x0 + 7, $y0 + 7, $x1 - 7, $y1 - 7, $rad - 6)) {
            $grid[$y][$x] = $C_GLOW;
        }
        else {
            $grid[$y][$x] = (($y % 4) == 0) ? $C_SCAN : $C_BLACK;
        }
    }
}

# Terminal top title bar divider & three amber phosphor status dots
for my $x (($x0 + 9) .. ($x1 - 9)) {
    $grid[$y0 + 20][$x] = $C_BEZEL;
    $grid[$y0 + 21][$x] = $C_AMBER;
}
for my $dot_x ($x0 + 18, $x0 + 28, $x0 + 38) {
    for my $dy (-2 .. 2) {
        for my $dx (-2 .. 2) {
            next if $dx * $dx + $dy * $dy > 5;
            $grid[$y0 + 13 + $dy][$dot_x + $dx] = $C_AMBER;
        }
    }
}

# Build foreground mask for "NPL" (3 glyphs x 5 cols + 2 cols spacing = 19 cols, 7 rows)
# Cell size = 4x4 => 76x28 px centered horizontally inside 128x128
my $cell = 4;
my $start_x = int(($M - (19 * $cell)) / 2);
my $start_y = 48;
my @fg = map { [ (0) x $M ] } (0 .. $M - 1);

my @letters = ('N', 'P', 'L');
for my $li (0 .. $#letters) {
    my $g = $GLYPH{ $letters[$li] };
    my $gx0 = $start_x + $li * (7 * $cell);
    for my $gy (0 .. 6) {
        my $row = $g->[$gy];
        for my $gx (0 .. 4) {
            next unless substr($row, $gx, 1) eq '1';
            for my $py (0 .. $cell - 1) {
                for my $px (0 .. $cell - 1) {
                    $fg[$start_y + $gy * $cell + $py][$gx0 + $gx * $cell + $px] = 1;
                }
            }
        }
    }
}

# Bottom prompt bar + amber block cursor
my $bar_y = 88;
for my $y ($bar_y .. $bar_y + 5) {
    for my $x ($start_x .. $start_x + 42) {
        $fg[$y][$x] = 2;
    }
    for my $x ($start_x + 50 .. $start_x + 75) {
        $fg[$y][$x] = 1;
    }
}

# Subtle 1px phosphor glow around bright glyphs
for my $y (1 .. $M - 2) {
    for my $x (1 .. $M - 2) {
        next if $fg[$y][$x];
        if ($fg[$y - 1][$x] == 1 || $fg[$y + 1][$x] == 1
         || $fg[$y][$x - 1] == 1 || $fg[$y][$x + 1] == 1) {
            $grid[$y][$x] = $C_GLOW if $grid[$y][$x] eq $C_BLACK || $grid[$y][$x] eq $C_SCAN;
        }
    }
}

for my $y (0 .. $M - 1) {
    for my $x (0 .. $M - 1) {
        if ($fg[$y][$x] == 1) {
            $grid[$y][$x] = (($y % 2) == 0) ? $C_BRIGHT : $C_AMBER;
        }
        elsif ($fg[$y][$x] == 2) {
            $grid[$y][$x] = $C_BEZEL;
        }
    }
}

sub render_scaled {
    my ($size) = @_;
    my @rows;
    if ($size >= $M) {
        my $factor = int($size / $M);
        for my $y (0 .. $M - 1) {
            my $line = '';
            for my $x (0 .. $M - 1) {
                $line .= ($grid[$y][$x] x $factor);
            }
            for (1 .. $factor) {
                push @rows, $line;
            }
        }
    }
    else {
        my $step = int($M / $size);
        my $area = $step * $step;
        for my $y (0 .. $size - 1) {
            my $line = '';
            for my $x (0 .. $size - 1) {
                my ($sr, $sg, $sb, $sa) = (0, 0, 0, 0);
                for my $dy (0 .. $step - 1) {
                    for my $dx (0 .. $step - 1) {
                        my ($r, $g, $b, $a) = unpack('CCCC', $grid[$y * $step + $dy][$x * $step + $dx]);
                        $sr += $r;
                        $sg += $g;
                        $sb += $b;
                        $sa += $a;
                    }
                }
                $line .= pack('CCCC',
                    int($sr / $area + 0.5),
                    int($sg / $area + 0.5),
                    int($sb / $area + 0.5),
                    int($sa / $area + 0.5),
                );
            }
            push @rows, $line;
        }
    }
    return \@rows;
}

my @SPECS = (
    [ 'icon_16x16.png',      16 ],
    [ 'icon_16x16@2x.png',   32 ],
    [ 'icon_32x32.png',      32 ],
    [ 'icon_32x32@2x.png',   64 ],
    [ 'icon_128x128.png',   128 ],
    [ 'icon_128x128@2x.png',256 ],
    [ 'icon_256x256.png',   256 ],
    [ 'icon_256x256@2x.png',512 ],
    [ 'icon_512x512.png',   512 ],
    [ 'icon_512x512@2x.png',1024],
);

my %cache;
for my $sp (@SPECS) {
    my ($fname, $sz) = @$sp;
    $cache{$sz} ||= render_scaled($sz);
    write_rgba_png("$out_dir/$fname", $sz, $sz, $cache{$sz});
}
PERL_ICON_EOF

if command -v iconutil >/dev/null 2>&1; then
    iconutil -c icns "$ICONSET_DIR" -o "$ICNS_PATH"
    printf 'Generated %s\n' "$ICNS_PATH"
else
    cp "${ICONSET_DIR}/icon_512x512.png" "${RESOURCES_DIR}/${APP_NAME}.png"
    printf 'Note: iconutil not available on this platform; saved PNG icon to %s/%s.png\n' "$RESOURCES_DIR" "$APP_NAME"
fi

# 3. Write Contents/MacOS/NeoPerl launcher
# Escape single quotes in PREFIX for safe single-quoted shell assignment
SAFE_PREFIX="$(printf '%s' "$PREFIX" | sed "s/'/'\\\\''/g")"

cat > "$LAUNCHER_PATH" <<EOF
#!/bin/sh
# Native macOS application bundle launcher for NeoPerl::MT
# Author: stratum42

set -e

NEOPERL_PREFIX='${SAFE_PREFIX}'
PATH="\${NEOPERL_PREFIX}/bin:\${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:\${PATH}"
export PATH

# Strip macOS LaunchServices / Finder -psn_* process serial number arguments
_n=\$#
while [ "\$_n" -gt 0 ]; do
    _arg=\$1
    shift
    case "\$_arg" in
        -psn_*)
            ;;
        *)
            set -- "\$@" "\$_arg"
            ;;
    esac
    _n=\$(( _n - 1 ))
done

NPL_BIN="\${NEOPERL_PREFIX}/bin/npl"
if [ ! -x "\$NPL_BIN" ]; then
    printf 'NeoPerl launcher error: %s not found or not executable\n' "\$NPL_BIN" >&2
    exit 1
fi

exec "\$NPL_BIN" --gpu "\$@"
EOF
chmod 755 "$LAUNCHER_PATH"

printf 'Installed macOS launcher bundle: %s\n' "$APP_BUNDLE"
