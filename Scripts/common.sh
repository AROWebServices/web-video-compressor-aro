#!/bin/bash
# Shared settings. Build products live outside the project folder so that
# OneDrive does not try to sync gigabytes of intermediate files.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${WVC_BUILD_DIR:-$HOME/Library/Caches/WebVideoCompressor-build}"
APP_NAME="Web Video Compressor ARO"

# Without full Xcode (Command Line Tools only) two things need help:
#  - the macOS 27 SDK turns SwiftUI's @State into a macro whose compiler plugin
#    ships only with Xcode, so build against the newest macOS 26 SDK instead;
#  - the Swift Testing macro plugin is installed but not on the default plugin path.
TEST_FLAGS=()
DEV_DIR="$(xcode-select -p)"
if [[ "$DEV_DIR" == */CommandLineTools ]]; then
    OLDER_SDK="$(ls -d "$DEV_DIR"/SDKs/MacOSX26.*.sdk 2>/dev/null | sort -V | tail -1 || true)"
    if [[ -n "$OLDER_SDK" && -z "${SDKROOT:-}" ]]; then export SDKROOT="$OLDER_SDK"; fi
    if [[ -d "$DEV_DIR/usr/lib/swift/host/plugins/testing" ]]; then
        TEST_FLAGS=(-Xswiftc -plugin-path -Xswiftc "$DEV_DIR/usr/lib/swift/host/plugins/testing")
    fi
fi
