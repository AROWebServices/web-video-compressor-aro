import Foundation

public struct CompressionResult: Sendable, Equatable {
    public let outputURL: URL
    public let outputSize: Int64
}

public struct ExportedFile: Sendable, Equatable {
    public let format: OutputFormat
    public let url: URL
    public let size: Int64
}

/// Everything one export produced.
public struct ExportResult: Sendable, Equatable {
    public let videos: [ExportedFile]
    public let poster: URL?
    /// Ready-to-paste markup for the files above.
    public let html: String

    public var allURLs: [URL] { videos.map(\.url) + [poster].compactMap { $0 } }
    public var largestSize: Int64 { videos.map(\.size).max() ?? 0 }
}

public enum CompressorError: Error, Sendable {
    case probeFailed(summary: String)
    case noVideoStream
    case ffmpegFailed(status: Int32, summary: String, fullLog: String)
    case outputMissing
}

/// Probes and encodes files by running ffprobe / ffmpeg as subprocesses.
public struct Compressor: Sendable {
    public let tools: FFmpegTools

    public init(tools: FFmpegTools) {
        self.tools = tools
    }

    public func probe(_ url: URL) async throws -> MediaInfo {
        let output = try await ProcessRunner.run(tools.ffprobe, [
            "-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path,
        ])
        try Task.checkCancellation()
        guard output.status == 0 else {
            let log = String(decoding: output.stderr, as: UTF8.self)
            throw CompressorError.probeFailed(summary: LogSummary.relevantLines(from: log))
        }
        do {
            return try MediaInfo.parse(ffprobeJSON: output.stdout)
        } catch {
            throw CompressorError.probeFailed(summary: "Could not read the file's details.")
        }
    }

    /// Asks the installed FFmpeg which encoders and colour conversions it has.
    public func capabilities() async throws -> FFmpegCapabilities {
        func text(_ arguments: [String]) async throws -> String {
            let output = try await ProcessRunner.run(tools.ffmpeg, ["-hide_banner"] + arguments)
            return String(decoding: output.stdout, as: UTF8.self)
        }
        return FFmpegCapabilities.parse(encodersOutput: try await text(["-encoders"]),
                                        filtersOutput: try await text(["-filters"]),
                                        scaleHelp: try await text(["-h", "filter=scale"]))
    }

    /// Runs FFmpeg once and turns a non-zero exit or a cancellation into an error.
    private func runFFmpeg(_ arguments: [String], onLine: (@Sendable (String) -> Void)? = nil) async throws {
        let result = try await ProcessRunner.run(tools.ffmpeg, arguments, onStdoutLine: onLine)
        try Task.checkCancellation()
        guard result.status == 0 else {
            let log = String(decoding: result.stderr, as: UTF8.self)
            throw CompressorError.ffmpegFailed(status: result.status,
                                               summary: LogSummary.relevantLines(from: log), fullLog: log)
        }
    }

    private static func fileSize(_ url: URL) throws -> Int64 {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
        else { throw CompressorError.outputMissing }
        return size.int64Value
    }

    /// Produces every file an export needs: one video per format (two passes
    /// each when aiming for a size), then the poster. None of the destination
    /// files may exist yet. On failure or cancellation everything written so
    /// far is removed.
    public func export(
        input: URL, info: MediaInfo, settings: EncodeSettings, trim: TrimRange? = nil,
        capabilities: FFmpegCapabilities, destinations: ExportDestinations,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ExportResult {
        guard let video = info.video else { throw CompressorError.noVideoStream }
        let settings = settings.adjusted(forSourceBytes: info.fileSize)
        let fileManager = FileManager.default
        // FFmpeg is run with -n, so a file that is already there is never ours to delete.
        let ours = destinations.all.filter { !fileManager.fileExists(atPath: $0.path) }
        let scratch = fileManager.temporaryDirectory.appendingPathComponent("wvc-\(UUID().uuidString)")
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }

        let duration = trim?.resolved(duration: info.duration)?.length ?? info.duration
        do {
            // Work out every FFmpeg run first so progress can cover all of them.
            var runs: [[String]] = []
            for (index, destination) in destinations.videos.enumerated() {
                var perFormat = settings
                perFormat.format = destination.format
                runs += try FFmpegCommandBuilder.passes(
                    input: input, output: destination.url, info: info, settings: perFormat, trim: trim,
                    capabilities: capabilities, passLogBase: scratch.appendingPathComponent("pass-\(index)"))
            }
            for (index, arguments) in runs.enumerated() {
                let done = Double(index), total = Double(runs.count)
                try await runFFmpeg(arguments) { line in
                    if let fraction = ProgressParser.fraction(fromLine: line, duration: duration) {
                        progress((done + fraction) / total)
                    }
                }
            }
            if let poster = destinations.poster {
                try await runFFmpeg(try FFmpegCommandBuilder.posterArguments(
                    input: input, output: poster, info: info, settings: settings, trim: trim,
                    capabilities: capabilities))
            }

            let files = try destinations.videos.map {
                ExportedFile(format: $0.format, url: $0.url, size: try Self.fileSize($0.url))
            }
            let keepsAudio = info.audio != nil && settings.audio != .remove
            let html = HTMLSnippet.make(
                files: files.map { ($0.url.lastPathComponent, $0.format) },
                poster: destinations.poster?.lastPathComponent,
                size: FFmpegCommandBuilder.outputSize(displayWidth: video.displayWidth,
                                                      displayHeight: video.displayHeight,
                                                      max: settings.maxResolution),
                hasAudio: keepsAudio,
                background: settings.preset == .hero)
            return ExportResult(videos: files, poster: destinations.poster, html: html)
        } catch {
            for url in ours { try? fileManager.removeItem(at: url) }
            if error is CommandBuilderError { throw CompressorError.noVideoStream }
            throw error
        }
    }

    /// Encodes `input` to a single `output` file. `output` must not exist yet;
    /// on failure or cancellation any partial file is removed.
    public func compress(
        input: URL, output: URL, info: MediaInfo, settings: EncodeSettings, trim: TrimRange? = nil,
        capabilities: FFmpegCapabilities,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> CompressionResult {
        var single = settings
        single.format = settings.format.components.last ?? settings.format
        single.exportPoster = false
        let result = try await export(
            input: input, info: info, settings: single, trim: trim, capabilities: capabilities,
            destinations: ExportDestinations(videos: [VideoDestination(format: single.format, url: output)],
                                             poster: nil),
            progress: progress)
        guard let file = result.videos.first else { throw CompressorError.outputMissing }
        return CompressionResult(outputURL: file.url, outputSize: file.size)
    }
}
