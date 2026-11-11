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
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wvc-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// Generates a short synthetic clip with FFmpeg's built-in test sources.
    private func makeSource(name: String, size: String, seconds: Int = 2, audio: Bool = true) async throws -> URL {
        let url = folder.appendingPathComponent(name)
        var args = ["-v", "error", "-f", "lavfi", "-i", "testsrc2=size=\(size):rate=30:duration=\(seconds)"]
        if audio { args += ["-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds)"] }
        args += ["-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv444p"]
        if audio { args += ["-c:a", "aac"] }
        args.append(url.path)
        let result = try await ProcessRunner.run(tools.ffmpeg, args)
        try #require(result.status == 0, "could not generate test clip: \(String(decoding: result.stderr, as: UTF8.self))")
        return url
    }

    @Test func encodesWebReadyH264() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let compressor = Compressor(tools: tools)
        let source = try await makeSource(name: "source.mkv", size: "1280x720")
        let info = try await compressor.probe(source)
        #expect(info.video?.width == 1280)
        #expect(info.audio != nil)

        let output = OutputNaming.uniqueURL(for: source, fileExtension: "mp4")
        let result = try await compressor.compress(input: source, output: output, info: info,
                                                   settings: EncodeSettings(quality: 50, maxResolution: .p480)) { _ in }
        #expect(result.outputSize > 0)

        let encoded = try await compressor.probe(output)
        #expect(encoded.video?.codec == "h264")
        #expect(encoded.video?.pixelFormat == "yuv420p")
        #expect(encoded.video?.width == 854)
        #expect(encoded.video?.height == 480)
        #expect(encoded.audio?.codec == "aac")
        #expect(abs(encoded.duration - 2) < 0.3)

        // faststart: the moov atom comes before the media data.
        let data = try Data(contentsOf: output)
        let moov = try #require(data.range(of: Data("moov".utf8)))
        let mdat = try #require(data.range(of: Data("mdat".utf8)))
        #expect(moov.lowerBound < mdat.lowerBound)
    }

    @Test func handlesOddDimensionsAndNoAudio() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let compressor = Compressor(tools: tools)
        let source = try await makeSource(name: "odd.mkv", size: "321x241", audio: false)
        let info = try await compressor.probe(source)
        #expect(info.audio == nil)

        let output = OutputNaming.uniqueURL(for: source, fileExtension: "mp4")
        _ = try await compressor.compress(input: source, output: output, info: info,
                                          settings: EncodeSettings(maxResolution: .original)) { _ in }
        let encoded = try await compressor.probe(output)
        #expect(encoded.video?.width == 322)
        #expect(encoded.video?.height == 242)
        #expect(encoded.audio == nil)
    }

    @Test func failureRemovesPartialOutputAndReportsLog() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let compressor = Compressor(tools: tools)
        let missing = folder.appendingPathComponent("does-not-exist.mov")
        let output = folder.appendingPathComponent("out.mp4")
        let fake = MediaInfo(duration: 1, video: VideoStream(codec: "h264", width: 640, height: 360))
        do {
            _ = try await compressor.compress(input: missing, output: output, info: fake,
                                              settings: EncodeSettings()) { _ in }
            Issue.record("expected the encode to fail")
        } catch CompressorError.ffmpegFailed(_, let summary, _) {
            #expect(!summary.isEmpty)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }
}
