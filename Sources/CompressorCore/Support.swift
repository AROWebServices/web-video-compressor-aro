import Foundation

// MARK: - Finding FFmpeg

public struct FFmpegTools: Sendable, Equatable {
    public let ffmpeg: URL
    public let ffprobe: URL
    public init(ffmpeg: URL, ffprobe: URL) {
        self.ffmpeg = ffmpeg
        self.ffprobe = ffprobe
    }
}

public enum FFmpegLocator {
    /// Apps launched from Finder do not inherit the shell PATH, so look in the
    /// usual install locations directly (Homebrew on Apple Silicon, Homebrew on
    /// Intel, MacPorts).
    public static let standardDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]

    /// - Parameters:
    ///   - override: path to an `ffmpeg` binary chosen by the user; its folder is tried first.
    ///   - directories: folders to search, in order. Both `ffmpeg` and `ffprobe` must be in the same one.
    public static func locate(
        override: String? = nil,
        directories: [String] = standardDirectories,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> FFmpegTools? {
        var candidates: [String] = []
        if let override, !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override).deletingLastPathComponent().path)
        }
        candidates += directories
        for dir in candidates {
            let base = URL(fileURLWithPath: dir, isDirectory: true)
            let ffmpeg = base.appendingPathComponent("ffmpeg")
            let ffprobe = base.appendingPathComponent("ffprobe")
            if isExecutable(ffmpeg.path) && isExecutable(ffprobe.path) {
                return FFmpegTools(ffmpeg: ffmpeg, ffprobe: ffprobe)
            }
        }
        return nil
    }
}

// MARK: - Progress

public enum ProgressParser {
    /// Reads one `key=value` line from `ffmpeg -progress` and returns 0...1, or
    /// nil if the line says nothing about progress.
    public static func fraction(fromLine line: String, duration: Double) -> Double? {
        let parts = line.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let key = parts[0].trimmingCharacters(in: .whitespaces)
        let value = parts[1].trimmingCharacters(in: .whitespaces)
        switch key {
        case "progress":
            return value == "end" ? 1 : nil
        case "out_time_us", "out_time_ms":
            // Despite its name, out_time_ms is also in microseconds.
            guard duration > 0, let micros = Double(value), micros >= 0 else { return nil }
            return min(1, micros / 1_000_000 / duration)
        default:
            return nil
        }
    }
}

// MARK: - Output naming

public enum OutputNaming {
    /// `clip.mov` -> `clip-web.mp4` next to the source (or in `directory`). If that
    /// name is taken, `clip-web-2.mp4`, `clip-web-3.mp4`, ... so nothing is overwritten.
    public static func uniqueURL(
        for source: URL, suffix: String = "-web", fileExtension: String,
        in directory: URL? = nil,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        let folder = directory ?? source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent + suffix
        var candidate = folder.appendingPathComponent(base).appendingPathExtension(fileExtension)
        var n = 2
        while exists(candidate) {
            candidate = folder.appendingPathComponent("\(base)-\(n)").appendingPathExtension(fileExtension)
            n += 1
        }
        return candidate
    }
}

// MARK: - Error logs

public enum LogSummary {
    /// The last few meaningful lines of FFmpeg's stderr, which is where the
    /// actual cause of a failure is reported.
    public static func relevantLines(from log: String, limit: Int = 5) -> String {
        let lines = log.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.suffix(limit).joined(separator: "\n")
    }
}
