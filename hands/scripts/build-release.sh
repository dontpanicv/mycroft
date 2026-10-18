#!/bin/sh
# Build release binaries of hands into dist/ as hands-<os>-<arch> (the names install.sh looks for), with
# SHA256SUMS. Builds what this machine can and says how to get the rest. Publishes nothing.
#
#   macOS hosts: darwin-arm64 and darwin-x86_64, for each rustup target that is installed.
#   Linux (static, musl): linux-x86_64 and linux-aarch64, with `cargo zigbuild` or `cross` if either is installed.
set -eu

cd "$(dirname "$0")/.."
dist=dist
mkdir -p "$dist"
installed=$(rustup target list --installed 2>/dev/null || true)
built=0
missing=""

has_target() {
	printf '%s\n' "$installed" | grep -qx "$1"
}

place() { # target name
	cp "target/$1/release/hands" "$dist/hands-$2"
	chmod 755 "$dist/hands-$2"
	echo "built $dist/hands-$2"
	built=$((built + 1))
}

if [ "$(uname -s)" = Darwin ]; then
	for pair in aarch64-apple-darwin:darwin-arm64 x86_64-apple-darwin:darwin-x86_64; do
		target=${pair%%:*}
		name=${pair#*:}
		if has_target "$target"; then
			cargo build --release --locked --target "$target"
			place "$target" "$name"
		else
			missing="$missing
  $name: rustup target add $target"
		fi
	done
else
	echo "not on macOS: skipping darwin builds (they need the macOS SDK)"
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
	elif [ "$(uname -s)" = Linux ] && [ "$(uname -m)" = "${target%%-*}" ] && has_target "$target"; then
		cargo build --release --locked --target "$target"
		place "$target" "$name"
	else
		missing="$missing
  $name: install zig and cargo-zigbuild (brew install zig && cargo install --locked cargo-zigbuild),
         then rustup target add $target; or install cross (cargo install cross) with Docker running"
	fi
done

if [ "$built" -gt 0 ]; then
	(
		cd "$dist"
		if command -v sha256sum >/dev/null 2>&1; then
			sha256sum hands-* >SHA256SUMS
		else
			shasum -a 256 hands-* >SHA256SUMS
		fi
	)
	echo "wrote $dist/SHA256SUMS"
fi
if [ -n "$missing" ]; then
	echo "not built:$missing"
fi
