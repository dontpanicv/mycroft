#!/bin/sh
# Mycroft: install hands on this machine and pair it with the phone that served this script (hands/docs/pairing.md).
# The app fills in the BASE, PIN and SHA-256 placeholders and serves it to:
#
#   curl -fsSLk --pinnedpubkey sha256//PIN https://IP:P/S | sh
#
# On macOS it also fetches MycroftHands.zip, the desktop helper, when the phone serves it, and hands it to
# `hands install --desktop-zip`. A phone that does not (its desktop SHA-256 is left unfilled) installs hands alone.
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

	# The desktop helper, Mycroft Hands.app (macOS only). The phone fills in its SHA-256 when it serves the zip.
	desktop=
	if [ "$os" = darwin ]; then
		dsum='@SHA256_desktop@'
		case $dsum in
		*[!0-9a-f]* | '') ;; # not filled in: this phone does not serve the desktop helper
		*)
			if curl -fsSLk --retry 3 --retry-all-errors --pinnedpubkey "sha256//$PIN" -o "$tmp/MycroftHands.zip" "$BASE/MycroftHands.zip" \
				</dev/null 2>/dev/null; then
				actual=$(sha256 "$tmp/MycroftHands.zip") || exit 1
				[ "$actual" = "$dsum" ] ||
					fail "MycroftHands.zip does not match its SHA-256 (got $actual); nothing was installed"
				desktop=$tmp/MycroftHands.zip
			else
				echo "mycroft: could not download MycroftHands.zip from the phone; installing hands without desktop control" >&2
			fi
			;;
		esac
	fi

	chmod 755 "$tmp/hands"
	# Copies hands to ~/.local/bin, starts its service and pairs; prints the one line saying so. With the desktop
	# helper, it also installs Mycroft Hands.app and prints one more line asking to approve its permissions.
	if [ -n "$desktop" ]; then
		"$tmp/hands" install --pair "$BASE" --pin "$PIN" --desktop-zip "$desktop" </dev/null ||
			fail "installing hands failed"
	else
		"$tmp/hands" install --pair "$BASE" --pin "$PIN" </dev/null || fail "installing hands failed"
	fi
}

main "$@"
