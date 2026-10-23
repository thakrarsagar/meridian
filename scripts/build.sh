#!/bin/bash
set -euo pipefail
root="$(rtk proxy python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).resolve().parent.parent)' "$0")"
rustc="$(rtk proxy rustup which --toolchain stable rustc)"
cargo="$(rtk proxy rustup which --toolchain stable cargo)"
export PATH="$(rtk proxy dirname "$rustc"):$PATH"
build_dir="${1:-"$root/build"}"
rtk proxy env RUSTC="$rustc" "$cargo" build --release --locked --manifest-path "$root/Cargo.toml"
rtk proxy mkdir -p "$build_dir/Meridian.app/Contents/MacOS" "$build_dir/Meridian.app/Contents/Resources"
rtk proxy xcrun clang -fobjc-arc -fblocks -Os -mmacosx-version-min=14.0 -c "$root/native/NativeVPN.m" -o "$build_dir/NativeVPN.o"
rtk proxy xcrun swiftc -swift-version 5 -O -whole-module-optimization -target "$(rtk proxy uname -m)-apple-macosx14.0" \
  -import-objc-header "$root/native/Bridge.h" \
  "$root/native/Core.swift" "$root/native/Credentials.swift" "$root/native/NordAccount.swift" "$root/native/App.swift" \
  "$build_dir/NativeVPN.o" "$root/target/release/libmeridian_core.a" \
  -framework Cocoa -framework AuthenticationServices -framework NetworkExtension -framework Security -framework Network -framework SystemConfiguration \
  -Xlinker -dead_strip -o "$build_dir/Meridian.app/Contents/MacOS/Meridian"
rtk proxy cp "$root/native/Info.plist" "$build_dir/Meridian.app/Contents/Info.plist"
rtk proxy mkdir -p "$build_dir/AppIcon.iconset"
rtk proxy xcrun swift "$root/scripts/Icon.swift" "$build_dir/AppIcon.iconset"
rtk proxy xcrun iconutil -c icns "$build_dir/AppIcon.iconset" -o "$build_dir/Meridian.app/Contents/Resources/AppIcon.icns"
rtk proxy codesign --force --sign - --identifier io.github.thakrarsagar.nordlet --timestamp=none "$build_dir/Meridian.app"
rtk proxy codesign --verify --strict "$build_dir/Meridian.app"
