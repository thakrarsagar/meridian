#!/bin/bash
set -euo pipefail
root="$(rtk proxy python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).resolve().parent.parent)' "$0")"
rustc="$(rtk proxy rustup which --toolchain stable rustc)"
cargo="$(rtk proxy rustup which --toolchain stable cargo)"
export PATH="$(rtk proxy dirname "$rustc"):$PATH"
rtk proxy env RUSTC="$rustc" "$cargo" fmt --check --manifest-path "$root/Cargo.toml"
rtk proxy env RUSTC="$rustc" "$cargo" test --locked --manifest-path "$root/Cargo.toml"
rtk proxy env RUSTC="$rustc" "$cargo" clippy --locked --manifest-path "$root/Cargo.toml" -- -D warnings
rtk proxy bash "$root/scripts/build.sh"
rtk proxy "$root/build/Meridian.app/Contents/MacOS/Meridian" --self-check
