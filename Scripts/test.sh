#!/bin/bash
source "$(dirname "$0")/common.sh"
cd "$ROOT"
swift test --scratch-path "$BUILD_DIR" ${TEST_FLAGS[@]+"${TEST_FLAGS[@]}"} "$@"
