# Web Video Compressor

A macOS app that compresses videos for use on websites. Phase 1 (MVP): one file
at a time, MP4 (H.264 + AAC), quality slider, maximum resolution, progress, and
the resulting size.

## Requirements

- macOS 14 or later, Apple Silicon
- Swift 6 toolchain: Xcode, or just the Command Line Tools (`xcode-select --install`)
- FFmpeg and ffprobe (see below)

## Build, test, run

    ./Scripts/test.sh         # unit tests, plus real encodes when FFmpeg is installed
    ./Scripts/build-app.sh    # creates dist/Web Video Compressor.app
    open "dist/Web Video Compressor.app"

Build products go to `~/Library/Caches/WebVideoCompressor-build` so the project
folder stays small (it lives in a synced folder). Override with `WVC_BUILD_DIR`.

The scripts detect a Command Line Tools-only setup and work around two gaps
there (see `Scripts/common.sh`). With full Xcode installed you can also open
`Package.swift` directly.

## Where FFmpeg comes from

The app runs `ffmpeg` and `ffprobe` as subprocesses; nothing is bundled yet.
It looks for both programs, side by side, in this order:

1. The folder of a binary chosen with Video > Locate FFmpeg…
2. `~/Library/Application Support/WebVideoCompressor/bin`
3. `/opt/homebrew/bin`, `/usr/local/bin`, `/opt/local/bin`

The simplest install is Homebrew: `brew install ffmpeg`. The build needs libx264.

## Layout

- `Sources/CompressorCore`: all non-UI logic (probe parsing, the pure
  `FFmpegCommandBuilder`, process runner, output naming)
- `Sources/WebVideoCompressor`: the SwiftUI app
- `Tests/CompressorCoreTests`: unit tests and FFmpeg integration tests
