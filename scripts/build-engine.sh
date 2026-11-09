#!/bin/sh
set -eu
export PATH="${CARGO_HOME:-$HOME/.cargo}/bin:/opt/homebrew/opt/rustup/bin:/usr/local/opt/rustup/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
export CARGO_TARGET_DIR="$PROJECT_TEMP_DIR/cargo"
profile=debug
if [ "$CONFIGURATION" = Release ]; then profile=release; fi
set --
for arch in $ARCHS; do
    case "$arch" in
        arm64) triple=aarch64-apple-darwin ;;
        x86_64) triple=x86_64-apple-darwin ;;
        *) echo "Architecture inconnue : $arch" >&2; exit 1 ;;
    esac
    if [ "$profile" = release ]; then
        cargo build --release --locked --manifest-path "$SRCROOT/Engine/Cargo.toml" --target "$triple"
    else
        cargo build --locked --manifest-path "$SRCROOT/Engine/Cargo.toml" --target "$triple"
    fi
    set -- "$@" "$CARGO_TARGET_DIR/$triple/$profile/libmterm_engine.a"
done
mkdir -p "$BUILT_PRODUCTS_DIR"
lipo -create "$@" -output "$BUILT_PRODUCTS_DIR/libmterm_engine.a"
