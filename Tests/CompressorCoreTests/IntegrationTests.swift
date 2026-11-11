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
