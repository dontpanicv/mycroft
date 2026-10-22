#!/bin/sh
# Mycroft: install hands on this machine and pair it with the phone that served this script (hands/docs/pairing.md).
# The app fills in the BASE, PIN and SHA-256 placeholders and serves it to either of:
#
#   curl -fsS IP:8484/S | sh
#   curl -fsSLk --pinnedpubkey sha256//PIN https://IP:8485/S | sh
#
# Either way, BASE is the pinned HTTPS address, so the downloads and the pairing below are pinned to the phone.
#
# POSIX sh: dash, bash, zsh and macOS sh. Quiet unless something fails. The work happens in main, so a script
# cut short in transit runs nothing.

set -eu

tmp=
cleanup() {
	if [ -n "$tmp" ]; then rm -rf "$tmp"; fi
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

fail() {
	echo "mycroft: $*" >&2
	exit 1
}

# sha256 FILE: prints the file's SHA-256 in lowercase hex.
sha256() {
	if command -v shasum >/dev/null 2>&1; then
		set -- "$(shasum -a 256 "$1")"
	elif command -v sha256sum >/dev/null 2>&1; then
		set -- "$(sha256sum "$1")"
	else
		fail "neither shasum nor sha256sum is available to verify the download"
	fi
	echo "${1%% *}"
}

main() {
	BASE='@BASE@'
	PIN='@PIN@'

	case $(uname -s) in
	Darwin) os=darwin ;;
	Linux) os=linux ;;
	*) fail "$(uname -s) is not supported; hands runs on macOS and Linux" ;;
	esac
	machine=$(uname -m)
	# A shell under Rosetta reports x86_64 on Apple silicon: take the native binary.
	if [ "$os" = darwin ] && [ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" = 1 ]; then
		machine=arm64
	fi
	case $os-$machine in
	darwin-arm64 | darwin-aarch64) arch=arm64 sum='@SHA256_darwin_arm64@' ;;
	darwin-x86_64) arch=x86_64 sum='@SHA256_darwin_x86_64@' ;;
	linux-x86_64 | linux-amd64) arch=x86_64 sum='@SHA256_linux_x86_64@' ;;
	linux-aarch64 | linux-arm64) arch=aarch64 sum='@SHA256_linux_aarch64@' ;;
	*) fail "$machine is not supported on $os" ;;
	esac
	name=hands-$os-$arch

	tmp=$(mktemp -d 2>/dev/null || mktemp -d -t mycroft) || fail "cannot create a temporary directory"
	curl -fsSLk --retry 3 --retry-all-errors --pinnedpubkey "sha256//$PIN" -o "$tmp/hands" "$BASE/$name" </dev/null ||
		fail "could not download $name from the phone"

	actual=$(sha256 "$tmp/hands") || exit 1
	[ "$actual" = "$sum" ] || fail "$name does not match its SHA-256 (got $actual); nothing was installed"

	chmod 755 "$tmp/hands"
	# Copies hands to ~/.local/bin, starts its service and pairs; prints the one line saying so. On macOS it then
	# walks through the permissions Mycroft needs, one at a time, on the terminal (/dev/tty: stdin here is this script).
	"$tmp/hands" install --pair "$BASE" --pin "$PIN" </dev/null || fail "installing hands failed"
}

main "$@"
