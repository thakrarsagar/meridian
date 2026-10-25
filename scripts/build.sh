#!/bin/bash
set -euo pipefail
root="$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).resolve().parent.parent)' "$0")"
rustc="$(rustup which --toolchain stable rustc)"
cargo="$(rustup which --toolchain stable cargo)"
export PATH="$(dirname "$rustc"):$PATH"
build_dir="${1:-"$root/build"}"
env RUSTC="$rustc" "$cargo" build --release --locked --manifest-path "$root/Cargo.toml"
mkdir -p "$build_dir/Meridian.app/Contents/MacOS" "$build_dir/Meridian.app/Contents/Resources"
xcrun clang -fobjc-arc -fblocks -Os -mmacosx-version-min=14.0 -c "$root/native/NativeVPN.m" -o "$build_dir/NativeVPN.o"
xcrun swiftc -swift-version 5 -O -whole-module-optimization -target "$(uname -m)-apple-macosx14.0" \
  -import-objc-header "$root/native/Bridge.h" \
  "$root/native/Core.swift" "$root/native/Credentials.swift" "$root/native/NordAccount.swift" "$root/native/App.swift" \
  "$build_dir/NativeVPN.o" "$root/target/release/libmeridian_core.a" \
  -framework Cocoa -framework AuthenticationServices -framework NetworkExtension -framework Security -framework Network -framework SystemConfiguration \
  -Xlinker -dead_strip -o "$build_dir/Meridian.app/Contents/MacOS/Meridian"
cp "$root/native/Info.plist" "$build_dir/Meridian.app/Contents/Info.plist"
mkdir -p "$build_dir/AppIcon.iconset"
xcrun swift "$root/scripts/Icon.swift" "$build_dir/AppIcon.iconset"
iconutil -c icns "$build_dir/AppIcon.iconset" -o "$build_dir/Meridian.app/Contents/Resources/AppIcon.icns"
codesign --force --sign - --identifier io.github.thakrarsagar.nordlet --timestamp=none "$build_dir/Meridian.app"
codesign --verify --strict "$build_dir/Meridian.app"
