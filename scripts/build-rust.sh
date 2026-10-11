#!/bin/sh
# Builds the Rust text engine as a static library for the platform Xcode is
# building. Run as a pre-build script phase; also works standalone.
set -eu

cd "$(dirname "$0")/../core"

case "${PLATFORM_NAME:-iphoneos}" in
  iphonesimulator) target=aarch64-apple-ios-sim ;;
  *) target=aarch64-apple-ios ;;
esac

# Xcode exports SDKROOT and friends for the iOS SDK, which confuses cargo's own
# toolchain discovery, so start from a clean environment.
exec env -i \
  HOME="$HOME" \
  PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/bin:/bin" \
  IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-26.0}" \
  cargo build --release --target "$target"
