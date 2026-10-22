#!/bin/sh
# Build the release binaries of hands into dist/ as hands-<os>-<arch>, the names the phone serves and install.sh
# looks for, with SHA256SUMS. Publishes nothing.
#
#   darwin-arm64, darwin-x86_64     cargo build, on macOS (they need the macOS SDK), signed as dev.mycroft.hands
#                                   with an Apple Development identity (or CODESIGN_IDENTITY), so macOS keeps the
#                                   permissions granted to hands (Accessibility, Screen Recording, folders, Local
#                                   Network, Full Disk Access) across updates. Ad hoc when there is none: those are
#                                   then asked for again after each update.
#   linux-x86_64, linux-aarch64     static musl binaries, with cargo zigbuild (or cross)
#
# Usage: build-release.sh [--partial]
#   --partial   build what this machine can and list the rest, instead of failing when a target can't be built
#
# Setup on a Mac:
#   rustup target add aarch64-apple-darwin x86_64-apple-darwin x86_64-unknown-linux-musl aarch64-unknown-linux-musl
#   brew install zig && cargo install --locked cargo-zigbuild
set -eu

cd "$(dirname "$0")/.."
partial=false
case "${1:-}" in
--partial) partial=true ;;
"") ;;
*) echo "usage: build-release.sh [--partial]" >&2; exit 2 ;;
esac

dist=dist
mkdir -p "$dist"
rm -f "$dist"/hands-* "$dist/SHA256SUMS"
installed=$(rustup target list --installed 2>/dev/null || true)
missing=""

has_target() {
	printf '%s\n' "$installed" | grep -qx "$1"
}

place() { # target name
	cp "target/$1/release/hands" "$dist/hands-$2"
	chmod 755 "$dist/hands-$2"
}

signed_with=""
# sign FILE: as dev.mycroft.hands, with CODESIGN_IDENTITY or the first Apple Development identity that isn't revoked.
sign() {
	if [ -n "${CODESIGN_IDENTITY:-}" ] && [ "$CODESIGN_IDENTITY" != - ]; then
		codesign --force --sign "$CODESIGN_IDENTITY" --identifier dev.mycroft.hands "$1"
		signed_with="$CODESIGN_IDENTITY (CODESIGN_IDENTITY)"
		return
	fi
	if [ "${CODESIGN_IDENTITY:-}" != - ]; then
		for hash in $(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development: / { print $2 }'); do
			codesign --force --sign "$hash" --identifier dev.mycroft.hands "$1" 2>/dev/null || continue
			case $(spctl --assess -vv "$1" 2>&1 || true) in
			*REVOKED*) continue ;;
			esac
			signed_with=$(security find-identity -v -p codesigning | awk -v id="$hash" '$2 == id { sub(/^[^"]*/, ""); print; exit }')
			return
		done
	fi
	codesign --force --sign - --identifier dev.mycroft.hands "$1"
	signed_with="ad hoc (macOS asks for hands' permissions again after each update)"
}

if [ "$(uname -s)" = Darwin ]; then
	for pair in aarch64-apple-darwin:darwin-arm64 x86_64-apple-darwin:darwin-x86_64; do
		target=${pair%%:*}
		name=${pair#*:}
		if has_target "$target"; then
			cargo build --release --locked --target "$target"
			place "$target" "$name"
			sign "$dist/hands-$name"
		else
			missing="$missing
  $name: rustup target add $target"
		fi
	done
else
	missing="$missing
  darwin-arm64, darwin-x86_64: build on macOS (they need the macOS SDK)"
fi

for pair in x86_64-unknown-linux-musl:linux-x86_64 aarch64-unknown-linux-musl:linux-aarch64; do
	target=${pair%%:*}
	name=${pair#*:}
	if command -v cargo-zigbuild >/dev/null 2>&1 && has_target "$target"; then
		cargo zigbuild --release --locked --target "$target"
		place "$target" "$name"
	elif command -v cross >/dev/null 2>&1; then
		cross build --release --locked --target "$target"
		place "$target" "$name"
	else
		missing="$missing
  $name: brew install zig && cargo install --locked cargo-zigbuild && rustup target add $target
         (or install cross with Docker running)"
	fi
done

if [ -n "$missing" ] && [ "$partial" = false ]; then
	echo "build-release.sh: cannot build:$missing" >&2
	echo "(--partial builds the rest)" >&2
	exit 1
fi

if ls "$dist"/hands-* >/dev/null 2>&1; then
	(
		cd "$dist"
		if command -v sha256sum >/dev/null 2>&1; then
			sha256sum hands-* >SHA256SUMS
		else
			shasum -a 256 hands-* >SHA256SUMS
		fi
	)
	echo "built into $dist/:"
	for file in "$dist"/hands-*; do
		printf '  %-22s %9s bytes\n' "$(basename "$file")" "$(wc -c <"$file" | tr -d ' ')"
	done
	echo "wrote $dist/SHA256SUMS"
	if [ -n "$signed_with" ]; then
		echo "macOS binaries signed: $signed_with"
	fi
fi
if [ -n "$missing" ]; then
	echo "not built:$missing"
fi
