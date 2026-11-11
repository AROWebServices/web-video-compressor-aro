import Foundation

public struct CompressionResult: Sendable, Equatable {
    public let outputURL: URL
    public let outputSize: Int64
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

    /// Encodes `input` to `output`. `output` must not exist yet; on failure or
    /// cancellation any partial file is removed.
    public func compress(
        input: URL, output: URL, info: MediaInfo, settings: EncodeSettings,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> CompressionResult {
        let arguments: [String]
        do {
            arguments = try FFmpegCommandBuilder.arguments(input: input, output: output,
                                                           info: info, settings: settings)
        } catch {
            throw CompressorError.noVideoStream
        }

        // FFmpeg is run with -n, so a file already at `output` is never ours to delete.
        let existedBefore = FileManager.default.fileExists(atPath: output.path)
        func removePartial() {
            if !existedBefore { try? FileManager.default.removeItem(at: output) }
        }

        let duration = info.duration
        let result: ProcessOutput
        do {
            result = try await ProcessRunner.run(tools.ffmpeg, arguments) { line in
                if let fraction = ProgressParser.fraction(fromLine: line, duration: duration) {
                    progress(fraction)
                }
            }
        } catch {
            removePartial()
            throw error
        }

        if Task.isCancelled {
            removePartial()
            throw CancellationError()
        }
        guard result.status == 0 else {
            removePartial()
            let log = String(decoding: result.stderr, as: UTF8.self)
            throw CompressorError.ffmpegFailed(status: result.status,
                                               summary: LogSummary.relevantLines(from: log),
                                               fullLog: log)
        }
        guard let size = (try? FileManager.default.attributesOfItem(atPath: output.path))?[.size] as? NSNumber
        else { throw CompressorError.outputMissing }
        return CompressionResult(outputURL: output, outputSize: size.int64Value)
    }
}
