import Foundation
import Testing
@testable import CompressorCore

private let input = URL(fileURLWithPath: "/videos/My Clip.mov")
private let output = URL(fileURLWithPath: "/videos/My Clip-web.mp4")

private func info(width: Int = 1920, height: Int = 1080, rotation: Int = 0, audio: Bool = true) -> MediaInfo {
    MediaInfo(duration: 10,
              video: VideoStream(codec: "h264", width: width, height: height, rotation: rotation),
              audio: audio ? AudioStream(codec: "aac", channels: 2) : nil)
}

private func value(after flag: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

@Suite struct CommandBuilderTests {
    @Test func h264DefaultsAreWebSafe() throws {
        let args = try FFmpegCommandBuilder.arguments(input: input, output: output, info: info(),
                                                      settings: EncodeSettings())
        #expect(value(after: "-c:v", in: args) == "libx264")
        #expect(value(after: "-pix_fmt", in: args) == "yuv420p")
        #expect(value(after: "-movflags", in: args) == "+faststart")
        #expect(value(after: "-c:a", in: args) == "aac")
        #expect(value(after: "-i", in: args) == input.path)
        #expect(args.last == output.path)
        #expect(args.contains("-n"))
        #expect(!args.contains("-y"))
        #expect(value(after: "-progress", in: args) == "pipe:1")
    }

    @Test func pathsWithSpacesStaySingleArguments() throws {
        let args = try FFmpegCommandBuilder.arguments(input: input, output: output, info: info(),
                                                      settings: EncodeSettings())
        #expect(args.contains("/videos/My Clip.mov"))
    }

    @Test func noScaleFilterWhenAlreadyWithinLimit() throws {
        let args = try FFmpegCommandBuilder.arguments(input: input, output: output, info: info(),
                                                      settings: EncodeSettings(maxResolution: .p1080))
        #expect(!args.contains("-vf"))
    }

    @Test func downscalesTo720p() throws {
        let args = try FFmpegCommandBuilder.arguments(input: input, output: output, info: info(),
                                                      settings: EncodeSettings(maxResolution: .p720))
        #expect(value(after: "-vf", in: args) == "scale=1280:720:flags=lanczos")
    }

    @Test func oddDimensionsAreMadeEvenEvenAtOriginalSize() throws {
        let args = try FFmpegCommandBuilder.arguments(input: input, output: output,
                                                      info: info(width: 853, height: 479),
                                                      settings: EncodeSettings(maxResolution: .original))
        #expect(value(after: "-vf", in: args) == "scale=854:480:flags=lanczos")
    }

    @Test func noAudioTrackMeansNoAudioMapping() throws {
        let args = try FFmpegCommandBuilder.arguments(input: input, output: output, info: info(audio: false),
                                                      settings: EncodeSettings())
        #expect(args.contains("-an"))
        #expect(!args.contains("-c:a"))
        #expect(!args.contains("0:a:0"))
    }

    @Test func missingVideoStreamThrows() {
        let audioOnly = MediaInfo(duration: 5, audio: AudioStream(codec: "mp3"))
        #expect(throws: CommandBuilderError.noVideoStream) {
            try FFmpegCommandBuilder.arguments(input: input, output: output, info: audioOnly,
                                               settings: EncodeSettings())
        }
    }

    @Test func qualityMapsToCRF() {
        #expect(FFmpegCommandBuilder.crf(forQuality: 0) == 30)
        #expect(FFmpegCommandBuilder.crf(forQuality: 50) == 24)
        #expect(FFmpegCommandBuilder.crf(forQuality: 100) == 18)
        #expect(FFmpegCommandBuilder.crf(forQuality: 500) == 18)
        #expect(FFmpegCommandBuilder.crf(forQuality: -5) == 30)
    }

    @Test func qualityLabels() {
        #expect(EncodeSettings(quality: 90).qualityLabel == "High")
        #expect(EncodeSettings(quality: 50).qualityLabel == "Balanced")
        #expect(EncodeSettings(quality: 10).qualityLabel == "Small")
    }
}

@Suite struct OutputSizeTests {
    @Test func neverUpscales() {
        let size = FFmpegCommandBuilder.outputSize(displayWidth: 640, displayHeight: 360, max: .p1080)
        #expect(size == PixelSize(width: 640, height: 360))
    }

    @Test func fourKDownTo1080p() {
        let size = FFmpegCommandBuilder.outputSize(displayWidth: 3840, displayHeight: 2160, max: .p1080)
        #expect(size == PixelSize(width: 1920, height: 1080))
    }

    @Test func portraitCapsTheShortSide() {
        let size = FFmpegCommandBuilder.outputSize(displayWidth: 1080, displayHeight: 1920, max: .p720)
        #expect(size == PixelSize(width: 720, height: 1280))
    }

    @Test func unusualAspectRatioStaysEven() {
        let size = FFmpegCommandBuilder.outputSize(displayWidth: 1000, displayHeight: 563, max: .p480)
        #expect(size.height == 480)
        #expect(size.width % 2 == 0)
        #expect(abs(Double(size.width) / Double(size.height) - 1000.0 / 563.0) < 0.01)
    }

    @Test func rotatedPhoneVideoUsesDisplayOrientation() throws {
        // Stored 1920x1080 with a 90 degree rotation is shown as 1080x1920.
        let rotated = info(width: 1920, height: 1080, rotation: -90)
        #expect(rotated.video?.displayWidth == 1080)
        #expect(rotated.video?.displayHeight == 1920)
        let args = try FFmpegCommandBuilder.arguments(input: input, output: output, info: rotated,
                                                      settings: EncodeSettings(maxResolution: .p720))
        #expect(value(after: "-vf", in: args) == "scale=720:1280:flags=lanczos")
    }
}

@Suite struct MediaInfoParsingTests {
    @Test func parsesTypicalPhoneVideo() throws {
        let json = """
        {
          "streams": [
            {"codec_type": "video", "codec_name": "hevc", "width": 3840, "height": 2160,
             "r_frame_rate": "30/1", "avg_frame_rate": "30000/1001", "pix_fmt": "yuv420p10le",
             "color_transfer": "arib-std-b67", "disposition": {"attached_pic": 0},
             "side_data_list": [{"side_data_type": "Display Matrix", "rotation": -90}]},
            {"codec_type": "audio", "codec_name": "aac", "channels": 2, "bit_rate": "192000"}
          ],
          "format": {"duration": "12.345000", "size": "45678901", "bit_rate": "29600000"}
        }
        """
        let info = try MediaInfo.parse(ffprobeJSON: Data(json.utf8))
        #expect(info.duration == 12.345)
        #expect(info.fileSize == 45_678_901)
        #expect(info.video?.codec == "hevc")
        #expect(info.video?.rotation == -90)
        #expect(info.video?.displayWidth == 2160)
        #expect(info.video?.pixelFormat == "yuv420p10le")
        #expect(info.video?.colorTransfer == "arib-std-b67")
        #expect(abs((info.video?.frameRate ?? 0) - 29.97) < 0.01)
        #expect(info.audio?.channels == 2)
        #expect(info.audio?.bitRate == 192_000)
    }

    @Test func legacyRotateTagIsRead() throws {
        let json = """
        {"streams": [{"codec_type": "video", "codec_name": "h264", "width": 1280, "height": 720,
                      "tags": {"rotate": "90"}}], "format": {"duration": "3.0"}}
        """
        let info = try MediaInfo.parse(ffprobeJSON: Data(json.utf8))
        #expect(info.video?.rotation == 90)
        #expect(info.audio == nil)
    }

    @Test func coverArtIsNotTreatedAsVideo() throws {
        let json = """
        {"streams": [
          {"codec_type": "video", "codec_name": "mjpeg", "width": 600, "height": 600,
           "disposition": {"attached_pic": 1}},
          {"codec_type": "audio", "codec_name": "mp3", "channels": 2}],
         "format": {"duration": "200.0"}}
        """
        let info = try MediaInfo.parse(ffprobeJSON: Data(json.utf8))
        #expect(info.video == nil)
        #expect(info.audio?.codec == "mp3")
    }

    @Test func garbageThrows() {
        #expect(throws: MediaInfoError.unreadableProbeOutput) {
            try MediaInfo.parse(ffprobeJSON: Data("not json".utf8))
        }
    }

    @Test func frameRateParsing() {
        #expect(MediaInfo.parseRate("25/1") == 25)
        #expect(MediaInfo.parseRate("0/0") == nil)
        #expect(MediaInfo.parseRate(nil) == nil)
    }
}

@Suite struct SupportTests {
    @Test func progressLines() {
        #expect(ProgressParser.fraction(fromLine: "out_time_us=5000000", duration: 10) == 0.5)
        #expect(ProgressParser.fraction(fromLine: "out_time_ms=2500000", duration: 10) == 0.25)
        #expect(ProgressParser.fraction(fromLine: "out_time_us=99000000", duration: 10) == 1)
        #expect(ProgressParser.fraction(fromLine: "progress=end", duration: 10) == 1)
        #expect(ProgressParser.fraction(fromLine: "progress=continue", duration: 10) == nil)
        #expect(ProgressParser.fraction(fromLine: "out_time_us=N/A", duration: 10) == nil)
        #expect(ProgressParser.fraction(fromLine: "out_time_us=5000000", duration: 0) == nil)
        #expect(ProgressParser.fraction(fromLine: "frame=12", duration: 10) == nil)
    }

    @Test func outputNameGetsSuffixAndNeverCollides() {
        let source = URL(fileURLWithPath: "/v/clip.final.mov")
        let free = OutputNaming.uniqueURL(for: source, fileExtension: "mp4") { _ in false }
        #expect(free.path == "/v/clip.final-web.mp4")

        let taken: Set<String> = ["/v/clip.final-web.mp4", "/v/clip.final-web-2.mp4"]
        let next = OutputNaming.uniqueURL(for: source, fileExtension: "mp4") { taken.contains($0.path) }
        #expect(next.path == "/v/clip.final-web-3.mp4")
    }

    @Test func mp4SourceDoesNotOverwriteItself() {
        let source = URL(fileURLWithPath: "/v/clip.mp4")
        let out = OutputNaming.uniqueURL(for: source, fileExtension: "mp4") { $0.path == "/v/clip.mp4" }
        #expect(out.path == "/v/clip-web.mp4")
    }

    @Test func locatorNeedsBothToolsInOneFolder() {
        let present: Set<String> = ["/a/ffmpeg", "/b/ffmpeg", "/b/ffprobe"]
        let tools = FFmpegLocator.locate(directories: ["/a", "/b"]) { present.contains($0) }
        #expect(tools?.ffmpeg.path == "/b/ffmpeg")
        #expect(tools?.ffprobe.path == "/b/ffprobe")
        #expect(FFmpegLocator.locate(directories: ["/a"]) { present.contains($0) } == nil)
    }

    @Test func locatorPrefersUserOverride() {
        let present: Set<String> = ["/custom/ffmpeg", "/custom/ffprobe", "/b/ffmpeg", "/b/ffprobe"]
        let tools = FFmpegLocator.locate(override: "/custom/ffmpeg", directories: ["/b"]) { present.contains($0) }
        #expect(tools?.ffmpeg.path == "/custom/ffmpeg")
    }

    @Test func logSummaryKeepsTheTail() {
        let log = "one\n\n two \nthree\nfour\nfive\nsix\n"
        #expect(LogSummary.relevantLines(from: log, limit: 3) == "four\nfive\nsix")
        #expect(LogSummary.relevantLines(from: "") == "")
    }
}

@Suite struct ProcessRunnerTests {
    @Test func capturesOutputLinesAndStatus() async throws {
        final class Lines: @unchecked Sendable {
            private let lock = NSLock()
            private var storage: [String] = []
            func add(_ s: String) { lock.withLock { storage.append(s) } }
            var all: [String] { lock.withLock { storage } }
        }
        let lines = Lines()
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"),
                                                 ["-c", "echo a; echo b; printf c; echo oops >&2; exit 3"]) {
            lines.add($0)
        }
        #expect(result.status == 3)
        #expect(lines.all == ["a", "b", "c"])
        #expect(String(decoding: result.stderr, as: UTF8.self) == "oops\n")
    }

    @Test func cancellationTerminatesTheProcess() async throws {
        let started = Date()
        let task = Task {
            try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sleep"), ["30"])
        }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let result = try await task.value
        #expect(result.status != 0)
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func missingExecutableThrows() async {
        await #expect(throws: (any Error).self) {
            try await ProcessRunner.run(URL(fileURLWithPath: "/nonexistent/tool"), [])
        }
    }
}
