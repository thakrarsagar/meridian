#!/bin/bash
set -euo pipefail
root="$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).resolve().parent.parent)' "$0")"
rustc="$(rustup which --toolchain stable rustc)"
cargo="$(rustup which --toolchain stable cargo)"
export PATH="$(dirname "$rustc"):$PATH"
build_dir="${1:-"$root/build"}"
env RUSTC="$rustc" "$cargo" fmt --check --manifest-path "$root/Cargo.toml"
env RUSTC="$rustc" "$cargo" test --locked --manifest-path "$root/Cargo.toml"
env RUSTC="$rustc" "$cargo" clippy --locked --manifest-path "$root/Cargo.toml" -- -D warnings
bash "$root/scripts/build.sh" "$build_dir"
"$build_dir/Meridian.app/Contents/MacOS/Meridian" --self-check
xcrun swiftc -swift-version 5 -O -import-objc-header "$root/native/Bridge.h" \
  "$root/native/Core.swift" "$root/native/Credentials.swift" "$root/native/NordAccount.swift" "$root/tests/AccountTests.swift" \
  "$root/target/release/libmeridian_core.a" -framework Cocoa -framework Security -framework AuthenticationServices \
  -o "$build_dir/AccountTests"
"$build_dir/AccountTests"
xcrun clang -fobjc-arc -fblocks -Os "$root/tests/NativeVPNTests.m" \
  -framework Foundation -framework NetworkExtension -framework Security -o "$build_dir/NativeVPNTests"
"$build_dir/NativeVPNTests"
