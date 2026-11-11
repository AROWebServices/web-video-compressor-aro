# Web Video Compressor

A macOS app that compresses videos for use on websites.

- Drop in one or many videos and compress them as a batch
- Output: MP4 (H.264, HEVC or AV1), WebM (VP9 or AV1), or animated GIF
- Presets (hero background, standard, small/mobile) plus quality, maximum size,
  frame rate cap, audio handling and metadata stripping
- Optional fast hardware encoding for H.264 and HEVC
- HDR sources (iPhone HLG, HDR10) are converted to SDR; variable frame rate is
  made constant; output is always 8-bit 4:2:0 with faststart for MP4
- Web bundle: WebM + MP4 + poster image in one go, with matching file names
- Aim for a file size instead of a quality level (two-pass where the encoder allows)
- Trim a start and end point per video; optional poster image
- Copy HTML: a ready `<video>` tag with sources, codecs, size and poster
- Settings apply to the whole batch, or select a video to give it its own
- Originals are never overwritten: results get a `-web` suffix

## Requirements

- macOS 14 or later, Apple Silicon
- Swift 6 toolchain: Xcode, or just the Command Line Tools (`xcode-select --install`)
- FFmpeg and ffprobe (see below)

## Build, test, run

    ./Scripts/test.sh                  # unit tests, plus real encodes when FFmpeg is installed
    ./Scripts/build-app.sh             # creates dist/Web Video Compressor.app
    ./Scripts/build-app.sh --install   # also copies it to /Applications
    ./Scripts/make-icon.sh             # only if you change the icon drawing

Build products go to `~/Library/Caches/WebVideoCompressor-build` so the project
folder stays small (it lives in a synced folder). Override with `WVC_BUILD_DIR`.

The scripts detect a Command Line Tools-only setup and work around two gaps
there (see `Scripts/common.sh`). With full Xcode installed you can also open
`Package.swift` directly.

## Installing on another Mac

The app is signed ad hoc (no Apple Developer account), so the reliable way to
get it onto another Mac is to build it there:

1. Install the Command Line Tools: `xcode-select --install`
2. Install Homebrew (https://brew.sh), then `brew install ffmpeg`
3. Get this folder onto that Mac (it syncs with OneDrive, or copy it)
4. In the folder, run `./Scripts/build-app.sh --install`

Or make a disk image and carry that across (Apple Silicon Macs only):

1. Here, run `./Scripts/make-dmg.sh`. It writes `dist/Web Video Compressor <version>.dmg`.
2. On the other Mac, open the `.dmg` and drag the app onto Applications.
3. Install Homebrew (https://brew.sh), then `brew install ffmpeg`.
4. If macOS refuses to open the app because it arrived from elsewhere, use
   System Settings → Privacy & Security → Open Anyway, or clear the flag once:
   `xattr -dr com.apple.quarantine "/Applications/Web Video Compressor.app"`.

## Where FFmpeg comes from

The app runs `ffmpeg` and `ffprobe` as subprocesses; nothing is bundled yet.
It looks for both programs, side by side, in this order:

1. The folder of a binary chosen with Video > Locate FFmpeg…
2. `~/Library/Application Support/WebVideoCompressor/bin`
3. `/opt/homebrew/bin`, `/usr/local/bin`, `/opt/local/bin`

The simplest install is Homebrew: `brew install ffmpeg`. At launch the app asks
FFmpeg which encoders it has and only offers the formats that build supports.

To queue videos at launch: `open "dist/Web Video Compressor.app" --args clip.mov`

## Licensing

FFmpeg is not bundled. Homebrew's FFmpeg includes libx264 and libx265, which
makes that FFmpeg binary GPL. Running it from this app for your own use places
no obligations on you. If the app is ever given to other people with FFmpeg
inside it, the GPL's terms apply to that FFmpeg binary (licence text and source
offer), or FFmpeg must be rebuilt without `--enable-gpl`, which leaves H.264
and HEVC to the hardware encoder only.

## Layout

- `Sources/CompressorCore`: all non-UI logic (probe parsing, the pure
  `FFmpegCommandBuilder`, process runner, output naming)
- `Sources/WebVideoCompressor`: the SwiftUI app
- `Tests/CompressorCoreTests`: unit tests and FFmpeg integration tests
- `Scripts`: build, test and icon scripts
- `Resources`: the app icon
