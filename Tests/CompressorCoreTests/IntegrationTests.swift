import Foundation
import Testing
@testable import CompressorCore

/// Real encodes. These run only when FFmpeg is installed; otherwise they are
/// reported as skipped.
private let installedTools: FFmpegTools? = {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first?.appendingPathComponent("WebVideoCompressor/bin").path
    return FFmpegLocator.locate(override: ProcessInfo.processInfo.environment["FFMPEG_PATH"],
                                directories: [appSupport].compactMap { $0 } + FFmpegLocator.standardDirectories)
}()

@Suite(.enabled(if: installedTools != nil, "FFmpeg is not installed"), .serialized)
struct IntegrationTests {
    let tools = installedTools!
    let compressor: Compressor
    let folder: URL

    init() throws {
        compressor = Compressor(tools: tools)
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wvc-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Generates a short synthetic clip with FFmpeg's built-in test sources.
    /// `crop` trims the picture afterwards; the test source itself only produces even sizes.
    private func makeSource(name: String, size: String, crop: String? = nil, rate: Int = 30,
                            seconds: Int = 1, audio: Bool = true) async throws -> URL {
        let url = folder.appendingPathComponent(name)
        var args = ["-v", "error", "-f", "lavfi", "-i", "testsrc2=size=\(size):rate=\(rate):duration=\(seconds)"]
        if audio { args += ["-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds)"] }
        if let crop { args += ["-vf", "format=yuv444p,crop=\(crop):exact=1"] }
        args += ["-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv444p"]
        if audio { args += ["-c:a", "aac"] }
        args.append(url.path)
        let result = try await ProcessRunner.run(tools.ffmpeg, args)
        try #require(result.status == 0, "could not generate test clip: \(String(decoding: result.stderr, as: UTF8.self))")
        return url
    }

    private func encode(_ source: URL, _ settings: EncodeSettings) async throws -> (MediaInfo, CompressionResult) {
        let info = try await compressor.probe(source)
        let capabilities = try await compressor.capabilities()
        let output = OutputNaming.uniqueURL(for: source, fileExtension: settings.format.fileExtension)
        let result = try await compressor.compress(input: source, output: output, info: info,
                                                   settings: settings, capabilities: capabilities) { _ in }
        return (try await compressor.probe(output), result)
    }

    @Test func detectsThisBuildsCapabilities() async throws {
        defer { cleanUp() }
        let capabilities = try await compressor.capabilities()
        #expect(capabilities.supports(.mp4H264))
        #expect(capabilities.encoders.contains("aac"))
    }

    @Test func encodesWebReadyH264() async throws {
        defer { cleanUp() }
        let source = try await makeSource(name: "source.mkv", size: "1280x720", seconds: 2)
        let (encoded, result) = try await encode(source, EncodeSettings(quality: 50, maxResolution: .p480))
        #expect(result.outputSize > 0)
        #expect(encoded.video?.codec == "h264")
        #expect(encoded.video?.pixelFormat == "yuv420p")
        #expect(encoded.video?.width == 854)
        #expect(encoded.video?.height == 480)
        #expect(encoded.audio?.codec == "aac")
        #expect(abs(encoded.duration - 2) < 0.3)

        // faststart: the moov atom comes before the media data.
        let data = try Data(contentsOf: result.outputURL)
        let moov = try #require(data.range(of: Data("moov".utf8)))
        let mdat = try #require(data.range(of: Data("mdat".utf8)))
        #expect(moov.lowerBound < mdat.lowerBound)
    }

    @Test(arguments: [
        (OutputFormat.mp4HEVC, "hevc", "aac"),
        (.webmVP9, "vp9", "opus"),
        (.webmAV1, "av1", "opus"),
        (.mp4AV1, "av1", "aac"),
    ])
    func encodesEachFormat(format: OutputFormat, videoCodec: String, audioCodec: String) async throws {
        defer { cleanUp() }
        let capabilities = try await compressor.capabilities()
        try #require(capabilities.supports(format), "this FFmpeg build lacks \(format.softwareEncoder)")
        let source = try await makeSource(name: "source.mkv", size: "640x360")
        let (encoded, result) = try await encode(source, EncodeSettings(format: format))
        #expect(result.outputURL.pathExtension == format.fileExtension)
        #expect(encoded.video?.codec == videoCodec)
        #expect(encoded.video?.pixelFormat == "yuv420p")
        #expect(encoded.audio?.codec == audioCodec)
        if format == .mp4HEVC { #expect(encoded.video?.codecTag == "hvc1") }
    }

    @Test(arguments: [OutputFormat.mp4H264, .mp4HEVC])
    func encodesWithHardware(format: OutputFormat) async throws {
        defer { cleanUp() }
        let capabilities = try await compressor.capabilities()
        try #require(capabilities.supportsHardware(format), "no VideoToolbox encoder for \(format.label)")
        let source = try await makeSource(name: "source.mkv", size: "1280x720")
        let (encoded, _) = try await encode(source, EncodeSettings(format: format, useHardware: true))
        #expect(encoded.video?.codec == (format == .mp4H264 ? "h264" : "hevc"))
        #expect(encoded.video?.pixelFormat == "yuv420p")
        if format == .mp4HEVC { #expect(encoded.video?.codecTag == "hvc1") }
    }

    @Test func encodesGIF() async throws {
        defer { cleanUp() }
        let source = try await makeSource(name: "source.mkv", size: "640x360")
        let (encoded, _) = try await encode(source, EncodeSettings(format: .gif, maxResolution: .original))
        #expect(encoded.video?.codec == "gif")
        #expect(encoded.audio == nil)
        // GIF frame delays are whole hundredths of a second, so the average
        // rate reads as 16.67; the nominal rate is the reliable figure.
        #expect(encoded.video?.baseFrameRate == 15)
    }

    @Test func heroPresetRemovesAudioAndCapsFrameRate() async throws {
        defer { cleanUp() }
        let source = try await makeSource(name: "source.mkv", size: "640x360", rate: 60)
        var settings = EncodeSettings()
        settings.apply(.hero)
        let (encoded, _) = try await encode(source, settings)
        #expect(encoded.audio == nil)
        #expect(abs((encoded.video?.frameRate ?? 0) - 30) < 0.5)
    }

    @Test func convertsHDRToSDR() async throws {
        defer { cleanUp() }
        let capabilities = try await compressor.capabilities()
        try #require(capabilities.hdrConversion != .unavailable, "this FFmpeg build cannot convert HDR")
        try #require(capabilities.encoders.contains("libx265"))

        // A 10-bit PQ (HDR10-style) clip.
        let source = folder.appendingPathComponent("hdr.mp4")
        let made = try await ProcessRunner.run(tools.ffmpeg, [
            "-v", "error", "-f", "lavfi", "-i", "smptehdbars=size=640x360:rate=30:duration=1",
            "-c:v", "libx265", "-pix_fmt", "yuv420p10le", "-tag:v", "hvc1",
            "-x265-params", "log-level=error:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc",
            source.path,
        ])
        try #require(made.status == 0)
        let info = try await compressor.probe(source)
        #expect(info.video?.isHDR == true)

        let (encoded, _) = try await encode(source, EncodeSettings())
        #expect(encoded.video?.isHDR == false)
        #expect(encoded.video?.colorTransfer == "bt709")
        #expect(encoded.video?.pixelFormat == "yuv420p")
    }

    private func export(_ source: URL, _ settings: EncodeSettings,
                        trim: TrimRange? = nil) async throws -> ExportResult {
        let info = try await compressor.probe(source)
        let capabilities = try await compressor.capabilities()
        let destinations = OutputNaming.destinations(for: source, settings: settings)
        return try await compressor.export(input: source, info: info, settings: settings, trim: trim,
                                           capabilities: capabilities, destinations: destinations) { _ in }
    }

    @Test(arguments: [OutputFormat.mp4H264, .mp4HEVC, .webmVP9])
    func twoPassLandsNearTheTargetSize(format: OutputFormat) async throws {
        defer { cleanUp() }
        // Noise is incompressible, so the encoder really has to ration bits.
        let source = folder.appendingPathComponent("noisy.mkv")
        let made = try await ProcessRunner.run(tools.ffmpeg, [
            "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30:duration=6",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=6",
            "-vf", "noise=alls=40:allf=t", "-c:v", "libx264", "-preset", "ultrafast", "-crf", "10",
            "-c:a", "aac", source.path,
        ])
        try #require(made.status == 0)
        let sourceSize = try #require((try FileManager.default.attributesOfItem(atPath: source.path))[.size] as? Int64)
        try #require(sourceSize > 2_000_000, "test clip is too small to be a meaningful target-size test")

        let result = try await export(source, EncodeSettings(format: format, useTargetSize: true, targetSizeMB: 1))
        let size = try #require(result.videos.first?.size)
        #expect(size > 700_000 && size < 1_100_000, "got \(size) bytes for a 1 MB target")
        // Encoder statistics files must not be left next to the video.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.contains(".log") || $0.contains("stats") || $0.contains("tree") }
        #expect(leftovers.isEmpty)
    }

    @Test func trimKeepsOnlyTheChosenPart() async throws {
        defer { cleanUp() }
        let source = try await makeSource(name: "source.mkv", size: "640x360", seconds: 6)
        let result = try await export(source, EncodeSettings(), trim: TrimRange(start: 1, end: 3.5))
        let encoded = try await compressor.probe(try #require(result.videos.first?.url))
        #expect(abs(encoded.duration - 2.5) < 0.15)
        #expect(encoded.audio != nil)
    }

    @Test func webBundleProducesBothVideosAPosterAndMarkup() async throws {
        defer { cleanUp() }
        let source = try await makeSource(name: "My Clip.mkv", size: "1280x720", seconds: 2)
        var settings = EncodeSettings(format: .webBundle, maxResolution: .p480)
        settings.apply(.hero)
        settings.maxResolution = .p480
        settings.audio = .remove
        let result = try await export(source, settings)

        #expect(result.videos.map(\.url.lastPathComponent) == ["My Clip-web.webm", "My Clip-web.mp4"])
        let webm = try await compressor.probe(result.videos[0].url)
        let mp4 = try await compressor.probe(result.videos[1].url)
        #expect(webm.video?.codec == "vp9")
        #expect(mp4.video?.codec == "h264")
        #expect(webm.audio == nil && mp4.audio == nil)

        let poster = try #require(result.poster)
        #expect(poster.lastPathComponent == "My Clip-web.jpg")
        let still = try await compressor.probe(poster)
        #expect(still.video?.codec == "mjpeg")
        #expect(still.video?.width == 854)
        #expect(still.video?.height == 480)

        #expect(result.html.contains(#"<source src="My%20Clip-web.webm" type='video/webm; codecs="vp9"'>"#))
        #expect(result.html.contains(#"poster="My%20Clip-web.jpg""#))
        #expect(result.html.contains(#"width="854" height="480""#))

        // Running it again must not overwrite: the whole set gets a new name.
        let again = try await export(source, settings)
        #expect(again.allURLs.map(\.lastPathComponent)
                == ["My Clip-web-2.webm", "My Clip-web-2.mp4", "My Clip-web-2.jpg"])
    }

    @Test func aFailedBundleLeavesNoFilesBehind() async throws {
        defer { cleanUp() }
        let source = try await makeSource(name: "source.mkv", size: "640x360")
        let info = try await compressor.probe(source)
        let capabilities = try await compressor.capabilities()
        // The poster goes to a folder that does not exist, so the last step fails
        // after both videos have been written.
        let good = OutputNaming.destinations(for: source, settings: EncodeSettings(format: .webBundle))
        let broken = ExportDestinations(videos: good.videos,
                                        poster: folder.appendingPathComponent("missing/poster.jpg"))
        await #expect(throws: (any Error).self) {
            try await compressor.export(input: source, info: info, settings: EncodeSettings(format: .webBundle),
                                        capabilities: capabilities, destinations: broken) { _ in }
        }
        for video in good.videos {
            #expect(!FileManager.default.fileExists(atPath: video.url.path))
        }
    }

    @Test func handlesOddDimensionsAndNoAudio() async throws {
        defer { cleanUp() }
        let source = try await makeSource(name: "odd.mkv", size: "322x242", crop: "321:241", audio: false)
        let info = try await compressor.probe(source)
        #expect(info.video?.width == 321)
        #expect(info.video?.height == 241)
        #expect(info.audio == nil)

        let (encoded, _) = try await encode(source, EncodeSettings(maxResolution: .original))
        #expect(encoded.video?.width == 322)
        #expect(encoded.video?.height == 242)
        #expect(encoded.audio == nil)
    }

    @Test func failureRemovesPartialOutputAndReportsLog() async throws {
        defer { cleanUp() }
        let missing = folder.appendingPathComponent("does-not-exist.mov")
        let output = folder.appendingPathComponent("out.mp4")
        let fake = MediaInfo(duration: 1, video: VideoStream(codec: "h264", width: 640, height: 360))
        let capabilities = try await compressor.capabilities()
        do {
            _ = try await compressor.compress(input: missing, output: output, info: fake,
                                              settings: EncodeSettings(), capabilities: capabilities) { _ in }
            Issue.record("expected the encode to fail")
        } catch CompressorError.ffmpegFailed(_, let summary, _) {
            #expect(!summary.isEmpty)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }
}
