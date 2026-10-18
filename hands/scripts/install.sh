#!/bin/sh
# Install hands on this machine: pick the binary for this OS and architecture, check it against SHA256SUMS when
# that file is next to it, and run `hands install`, which copies it to ~/.local/bin/hands and sets up the
# supervisor service (systemd user unit on Linux, LaunchAgent on macOS).
#
# Usage: install.sh [--dir DIR | --binary FILE] [--dry-run] [--uninstall]
#   --dir DIR      where the hands-<os>-<arch> binaries are (default: ../dist next to this script, else this
#                  script's own directory)
#   --binary FILE  use this binary as is
#   --dry-run      print what `hands install` would do, change nothing
#   --uninstall    reverse `hands install` (keeps the state dir)
set -eu

die() {
	echo "install.sh: $*" >&2
	exit 1
}

here=$(cd "$(dirname "$0")" && pwd)
dir=""
binary=""
flags=""
while [ $# -gt 0 ]; do
	case "$1" in
	--dir) [ $# -ge 2 ] || die "--dir needs a directory"; dir=$2; shift 2 ;;
	--binary) [ $# -ge 2 ] || die "--binary needs a file"; binary=$2; shift 2 ;;
	--dry-run | --uninstall) flags="$flags $1"; shift ;;
	*) die "unknown argument $1" ;;
	esac
done

case "$(uname -s)" in
Darwin) os=darwin ;;
Linux) os=linux ;;
*) die "unsupported system $(uname -s); hands runs on macOS and Linux" ;;
esac
case "$(uname -m)" in
x86_64 | amd64) arch=x86_64 ;;
arm64 | aarch64) if [ "$os" = darwin ]; then arch=arm64; else arch=aarch64; fi ;;
*) die "unsupported architecture $(uname -m)" ;;
esac
name="hands-$os-$arch"

if [ -z "$binary" ]; then
	if [ -z "$dir" ]; then
		if [ -f "$here/../dist/$name" ]; then dir=$(cd "$here/../dist" && pwd); else dir=$here; fi
	fi
	binary="$dir/$name"
fi
[ -f "$binary" ] || die "no $name at $binary; build it with scripts/build-release.sh or pass --binary"

sums="$(dirname "$binary")/SHA256SUMS"
if [ -f "$sums" ] && grep -q " $(basename "$binary")\$" "$sums"; then
	expected=$(grep " $(basename "$binary")\$" "$sums" | cut -d' ' -f1)
	if command -v sha256sum >/dev/null 2>&1; then
		actual=$(sha256sum "$binary" | cut -d' ' -f1)
	else
		actual=$(shasum -a 256 "$binary" | cut -d' ' -f1)
	fi
	[ "$expected" = "$actual" ] || die "$binary does not match $sums"
	echo "verified $name against SHA256SUMS"
fi

[ -x "$binary" ] || chmod 755 "$binary"
echo "using $binary ($("$binary" version))"
# shellcheck disable=SC2086 # flags holds only --dry-run and --uninstall
exec "$binary" install $flags
