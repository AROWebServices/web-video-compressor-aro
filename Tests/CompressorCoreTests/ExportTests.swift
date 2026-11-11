import Foundation
import Testing
@testable import CompressorCore

private let input = URL(fileURLWithPath: "/videos/clip.mov")
private let logBase = URL(fileURLWithPath: "/tmp/wvc/pass-0")

private let caps = FFmpegCapabilities(
    encoders: ["libx264", "libx265", "libvpx-vp9", "libsvtav1", "gif", "aac", "libopus", "mjpeg",
               "h264_videotoolbox", "hevc_videotoolbox"],
    hdrConversion: .scaleFilter)

private func source(duration: Double = 10, audio: Bool = true, transfer: String? = nil) -> MediaInfo {
    MediaInfo(duration: duration,
              video: VideoStream(codec: "h264", width: 1920, height: 1080, frameRate: 30, baseFrameRate: 30,
                                 colorTransfer: transfer),
              audio: audio ? AudioStream(codec: "aac", channels: 2) : nil)
}

private func passes(_ settings: EncodeSettings, _ info: MediaInfo = source(),
                    trim: TrimRange? = nil) throws -> [[String]] {
    try FFmpegCommandBuilder.passes(
        input: input, output: URL(fileURLWithPath: "/videos/clip-web.\(settings.format.fileExtension)"),
        info: info, settings: settings, trim: trim, capabilities: caps, passLogBase: logBase)
}

private func value(after flag: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

@Suite struct TargetSizeTests {
    @Test func bitrateArithmetic() {
        // 10 MB over 10 s is 8000 kbps; minus 3% overhead and 128 kbps of audio.
        #expect(FFmpegCommandBuilder.videoBitrateKbps(targetMB: 10, duration: 10, audioKbps: 128) == 7632)
        #expect(FFmpegCommandBuilder.videoBitrateKbps(targetMB: 10, duration: 10, audioKbps: 0) == 7760)
        // Impossible targets stop at a floor instead of going to zero or negative.
        #expect(FFmpegCommandBuilder.videoBitrateKbps(targetMB: 0.01, duration: 600, audioKbps: 128) == 50)
    }

    @Test func qualityModeIsASinglePass() throws {
        let runs = try passes(EncodeSettings())
        #expect(runs.count == 1)
        #expect(runs[0].contains("-crf"))
        #expect(!runs[0].contains("-pass"))
    }

    @Test func x264TargetSizeUsesTwoPasses() throws {
        let runs = try passes(EncodeSettings(useTargetSize: true, targetSizeMB: 10))
        try #require(runs.count == 2)
        let (first, second) = (runs[0], runs[1])
        #expect(value(after: "-pass", in: first) == "1")
        #expect(value(after: "-pass", in: second) == "2")
        #expect(value(after: "-passlogfile", in: first) == logBase.path)
        #expect(value(after: "-b:v", in: second) == "7632k")
        #expect(!second.contains("-crf"))
        // The analysis pass writes nothing and skips audio.
        #expect(first.suffix(3) == ["-f", "null", "-"])
        #expect(first.contains("-an"))
        #expect(!first.contains("-c:a"))
        #expect(!first.contains("/videos/clip-web.mp4"))
        #expect(second.last == "/videos/clip-web.mp4")
        #expect(value(after: "-c:a", in: second) == "aac")
    }

    @Test func x265PassesGoThroughItsOwnParameters() throws {
        let runs = try passes(EncodeSettings(format: .mp4HEVC, useTargetSize: true, targetSizeMB: 5))
        try #require(runs.count == 2)
        #expect(value(after: "-x265-params", in: runs[0]) == "log-level=error:pass=1:stats=\(logBase.path)")
        #expect(value(after: "-x265-params", in: runs[1]) == "log-level=error:pass=2:stats=\(logBase.path)")
        #expect(!runs[1].contains("-pass"))
    }

    @Test func vp9TargetSizeDropsConstantQuality() throws {
        let runs = try passes(EncodeSettings(format: .webmVP9, useTargetSize: true, targetSizeMB: 10))
        try #require(runs.count == 2)
        #expect(!runs[1].contains("-crf"))
        #expect(value(after: "-b:v", in: runs[1]) == "7664k")   // 7760 - 96 kbps Opus
    }

    @Test func encodersWithoutAnAnalysisPassUseOne() throws {
        for settings in [EncodeSettings(format: .webmAV1, useTargetSize: true),
                         EncodeSettings(format: .mp4H264, useHardware: true, useTargetSize: true)] {
            let runs = try passes(settings)
            #expect(runs.count == 1)
            #expect(runs[0].contains("-b:v"))
            #expect(!runs[0].contains("-crf"))
            #expect(!runs[0].contains("-q:v"))
        }
    }

    @Test func aSourceAlreadyUnderTheTargetIsEncodedByQuality() {
        let settings = EncodeSettings(useTargetSize: true, targetSizeMB: 10)
        #expect(settings.adjusted(forSourceBytes: 4_000_000).effectiveTargetSizeMB == nil)
        #expect(settings.adjusted(forSourceBytes: 40_000_000).effectiveTargetSizeMB == 10)
        #expect(settings.adjusted(forSourceBytes: nil).effectiveTargetSizeMB == 10)
    }

    @Test func gifIgnoresTheSizeTarget() throws {
        let settings = EncodeSettings(format: .gif, useTargetSize: true)
        #expect(settings.effectiveTargetSizeMB == nil)
        #expect(try passes(settings).count == 1)
    }

    @Test func removedAudioGivesItsBitsToTheVideo() throws {
        let runs = try passes(EncodeSettings(audio: .remove, useTargetSize: true, targetSizeMB: 10))
        #expect(value(after: "-b:v", in: runs[1]) == "7760k")
    }

    @Test func targetUsesTheTrimmedLength() throws {
        // Half the video at the same target size means double the bitrate.
        let runs = try passes(EncodeSettings(audio: .remove, useTargetSize: true, targetSizeMB: 10),
                              trim: TrimRange(start: 2, end: 7))
        #expect(value(after: "-b:v", in: runs[1]) == "15520k")
    }
}

@Suite struct TrimTests {
    @Test func resolvingRanges() {
        #expect(TrimRange().resolved(duration: 10) == nil)
        #expect(TrimRange(start: 0, end: 10).resolved(duration: 10) == nil)
        #expect(TrimRange(start: 2).resolved(duration: 10)! == (2, 8))
        #expect(TrimRange(end: 4).resolved(duration: 10)! == (0, 4))
        #expect(TrimRange(start: 2, end: 99).resolved(duration: 10)! == (2, 8))
        #expect(TrimRange(start: 5, end: 3).resolved(duration: 10) == nil)
        #expect(TrimRange(start: 12).resolved(duration: 10) == nil)
        #expect(TrimRange(start: -3, end: 4).resolved(duration: 10)! == (0, 4))
    }

    @Test func trimSeeksBeforeTheInputAndLimitsAfterIt() throws {
        let args = try passes(EncodeSettings(), trim: TrimRange(start: 1.5, end: 4))[0]
        let ss = try #require(args.firstIndex(of: "-ss"))
        let i = try #require(args.firstIndex(of: "-i"))
        let t = try #require(args.firstIndex(of: "-t"))
        #expect(ss < i && i < t)
        #expect(args[ss + 1] == "1.500")
        #expect(args[t + 1] == "2.500")
    }

    @Test func trimFromTheStartNeedsNoSeek() throws {
        let args = try passes(EncodeSettings(), trim: TrimRange(end: 4))[0]
        #expect(!args.contains("-ss"))
        #expect(value(after: "-t", in: args) == "4.000")
    }

    @Test func noTrimMeansNoTimeFlags() throws {
        let args = try passes(EncodeSettings())[0]
        #expect(!args.contains("-ss"))
        #expect(!args.contains("-t"))
    }
}

@Suite struct PosterTests {
    @Test func posterIsOneFrameAtTheVideoSize() throws {
        let args = try FFmpegCommandBuilder.posterArguments(
            input: input, output: URL(fileURLWithPath: "/videos/clip-web.jpg"), info: source(),
            settings: EncodeSettings(maxResolution: .p720), trim: TrimRange(start: 3), capabilities: caps)
        #expect(value(after: "-frames:v", in: args) == "1")
        #expect(value(after: "-vf", in: args) == "scale=1280:720:flags=lanczos")
        #expect(value(after: "-ss", in: args) == "3.000")
        #expect(value(after: "-c:v", in: args) == "mjpeg")
        #expect(args.last == "/videos/clip-web.jpg")
        #expect(args.contains("-n"))
    }

    @Test func posterOfAnHDRVideoIsConvertedToo() throws {
        let args = try FFmpegCommandBuilder.posterArguments(
            input: input, output: URL(fileURLWithPath: "/videos/p.jpg"), info: source(transfer: "arib-std-b67"),
            settings: EncodeSettings(), capabilities: caps)
        #expect(value(after: "-vf", in: args)?.contains("out_transfer=bt709") == true)
    }

    @Test func whenAPosterIsWanted() {
        #expect(!EncodeSettings().wantsPoster)
        #expect(EncodeSettings(exportPoster: true).wantsPoster)
        #expect(EncodeSettings(format: .webBundle).wantsPoster)
        #expect(!EncodeSettings(format: .gif, exportPoster: true).wantsPoster)
    }
}

@Suite struct BundleTests {
    private let clip = URL(fileURLWithPath: "/v/My Clip.mov")

    @Test func bundleIsWebMThenMP4() {
        #expect(OutputFormat.webBundle.components == [.webmVP9, .mp4H264])
        #expect(OutputFormat.mp4HEVC.components == [.mp4HEVC])
        #expect(caps.supports(.webBundle))
        #expect(!FFmpegCapabilities(encoders: ["libx264", "aac", "mjpeg"], hdrConversion: .unavailable)
            .supports(.webBundle))
    }

    @Test func bundleFilesShareOneBaseName() {
        let d = OutputNaming.destinations(for: clip, settings: EncodeSettings(format: .webBundle)) { _ in false }
        #expect(d.videos.map(\.url.path) == ["/v/My Clip-web.webm", "/v/My Clip-web.mp4"])
        #expect(d.poster?.path == "/v/My Clip-web.jpg")
    }

    @Test func anyTakenNameMovesTheWholeSet() {
        // Only the poster name is taken, but all three files move to "-2" together.
        let d = OutputNaming.destinations(for: clip, settings: EncodeSettings(format: .webBundle)) {
            $0.path == "/v/My Clip-web.jpg"
        }
        #expect(d.all.map(\.lastPathComponent) == ["My Clip-web-2.webm", "My Clip-web-2.mp4", "My Clip-web-2.jpg"])
    }

    @Test func singleFormatHasNoPosterUnlessAsked() {
        let plain = OutputNaming.destinations(for: clip, settings: EncodeSettings()) { _ in false }
        #expect(plain.videos.count == 1)
        #expect(plain.poster == nil)
        let withPoster = OutputNaming.destinations(for: clip, settings: EncodeSettings(exportPoster: true),
                                                   in: URL(fileURLWithPath: "/out")) { _ in false }
        #expect(withPoster.videos[0].url.path == "/out/My Clip-web.mp4")
        #expect(withPoster.poster?.path == "/out/My Clip-web.jpg")
    }
}

@Suite struct HTMLSnippetTests {
    private let size = PixelSize(width: 1280, height: 720)

    @Test func bundleListsWebMFirstAndMP4Last() {
        let html = HTMLSnippet.make(files: [("clip-web.webm", .webmVP9), ("clip-web.mp4", .mp4H264)],
                                    poster: "clip-web.jpg", size: size, hasAudio: true, background: false)
        #expect(html == """
        <video width="1280" height="720" controls preload="metadata" poster="clip-web.jpg">
          <source src="clip-web.webm" type='video/webm; codecs="vp9, opus"'>
          <source src="clip-web.mp4" type='video/mp4; codecs="avc1.640028, mp4a.40.2"'>
        </video>
        """)
    }

    @Test func heroVideoAutoplaysSilently() {
        let html = HTMLSnippet.make(files: [("hero-web.mp4", .mp4H264)], poster: nil, size: size,
                                    hasAudio: false, background: true)
        #expect(html.hasPrefix(#"<video width="1280" height="720" autoplay muted loop playsinline>"#))
        #expect(!html.contains("controls"))
        #expect(html.contains(#"type='video/mp4; codecs="avc1.640028"'"#))
    }

    @Test func silentNonHeroVideoIsMarkedMuted() {
        let html = HTMLSnippet.make(files: [("a.mp4", .mp4H264)], poster: nil, size: size,
                                    hasAudio: false, background: false)
        #expect(html.contains("controls"))
        #expect(html.contains("muted playsinline"))
        #expect(!html.contains("autoplay"))
    }

    @Test func fileNamesAreMadeURLSafe() {
        let html = HTMLSnippet.make(files: [("My Clip & more-web.mp4", .mp4H264)], poster: "My Clip-web.jpg",
                                    size: size, hasAudio: true, background: false)
        #expect(html.contains(#"src="My%20Clip%20&amp;%20more-web.mp4""#))
        #expect(html.contains(#"poster="My%20Clip-web.jpg""#))
    }

    @Test func codecStringsPerFormat() {
        #expect(HTMLSnippet.mimeType(for: .mp4HEVC, hasAudio: true) == #"video/mp4; codecs="hvc1.1.6.L123.B0, mp4a.40.2""#)
        #expect(HTMLSnippet.mimeType(for: .mp4AV1, hasAudio: false) == #"video/mp4; codecs="av01.0.08M.08""#)
        #expect(HTMLSnippet.mimeType(for: .webmAV1, hasAudio: true) == #"video/webm; codecs="av01.0.08M.08, opus""#)
    }

    @Test func gifBecomesAnImageTag() {
        let html = HTMLSnippet.make(files: [("a-web.gif", .gif)], poster: nil, size: size,
                                    hasAudio: false, background: false)
        #expect(html == #"<img src="a-web.gif" width="1280" height="720" alt="">"#)
    }
}
