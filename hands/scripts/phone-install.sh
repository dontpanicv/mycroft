#!/bin/sh
# Mycroft: install hands on this machine and pair it with the phone that served this script (hands/docs/pairing.md).
# The app fills in the BASE, PIN and SHA-256 placeholders and serves it to:
#
#   curl -fsSLk --pinnedpubkey sha256//PIN https://IP:P/S | sh
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
	curl -fsSLk --pinnedpubkey "sha256//$PIN" -o "$tmp/hands" "$BASE/$name" </dev/null ||
		fail "could not download $name from the phone"

	if command -v shasum >/dev/null 2>&1; then
		actual=$(shasum -a 256 "$tmp/hands")
	elif command -v sha256sum >/dev/null 2>&1; then
		actual=$(sha256sum "$tmp/hands")
	else
		fail "neither shasum nor sha256sum is available to verify the download"
	fi
	actual=${actual%% *}
	[ "$actual" = "$sum" ] || fail "$name does not match its SHA-256 (got $actual); nothing was installed"

	chmod 755 "$tmp/hands"
	# Copies hands to ~/.local/bin, starts its service and pairs; prints the one line saying so.
	"$tmp/hands" install --pair "$BASE" --pin "$PIN" </dev/null || fail "installing hands failed"
}

main "$@"
