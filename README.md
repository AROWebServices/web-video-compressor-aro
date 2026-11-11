# Web Video Compressor

A macOS app that compresses videos for use on websites.

- Drop in one or many videos and compress them as a batch
- Output: MP4 (H.264, HEVC or AV1), WebM (VP9 or AV1), or animated GIF
- Presets (hero background, standard, small/mobile) plus quality, maximum size,
  frame rate cap, audio handling and metadata stripping
- Optional fast hardware encoding for H.264 and HEVC
- HDR sources (iPhone HLG, HDR10) are converted to SDR; variable frame rate is
  made constant; output is always 8-bit 4:2:0 with faststart for MP4
- Settings apply to the whole batch, or select a video to give it its own
- Originals are never overwritten: results get a `-web` suffix

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

The simplest install is Homebrew: `brew install ffmpeg`. At launch the app asks
FFmpeg which encoders it has and only offers the formats that build supports.

To queue videos at launch: `open "dist/Web Video Compressor.app" --args clip.mov`

## Layout

- `Sources/CompressorCore`: all non-UI logic (probe parsing, the pure
  `FFmpegCommandBuilder`, process runner, output naming)
- `Sources/WebVideoCompressor`: the SwiftUI app
- `Tests/CompressorCoreTests`: unit tests and FFmpeg integration tests
