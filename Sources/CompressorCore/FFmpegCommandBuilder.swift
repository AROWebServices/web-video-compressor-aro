import Foundation

public enum MaxResolution: Int, CaseIterable, Sendable, Identifiable {
    case original = 0
    case p1080 = 1080
    case p720 = 720
    case p480 = 480

    public var id: Int { rawValue }
    public var label: String {
        self == .original ? "Original" : "\(rawValue)p"
    }
}

public struct EncodeSettings: Sendable, Equatable {
    /// 0 (smallest file) ... 100 (highest quality).
    public var quality: Int
    public var maxResolution: MaxResolution

    public init(quality: Int = 50, maxResolution: MaxResolution = .p1080) {
        self.quality = quality
        self.maxResolution = maxResolution
    }

    public var qualityLabel: String {
        switch quality {
        case 67...: "High"
        case 34...66: "Balanced"
        default: "Small"
        }
    }
}

public struct PixelSize: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public enum CommandBuilderError: Error, Equatable {
    case noVideoStream
}

/// Turns settings plus probe data into an FFmpeg argument list. Pure: no I/O.
public enum FFmpegCommandBuilder {
    /// x264 CRF: 30 at quality 0 (small), 24 at 50 (balanced), 18 at 100 (high).
    public static func crf(forQuality quality: Int) -> Int {
        let q = Double(min(max(quality, 0), 100))
        return Int((30 - q * 12 / 100).rounded())
    }

    /// Output dimensions: the short side is capped at the chosen resolution, the
    /// aspect ratio is kept, nothing is upscaled, and both sides are even
    /// (H.264 with 4:2:0 chroma requires that).
    public static func outputSize(displayWidth: Int, displayHeight: Int, max: MaxResolution) -> PixelSize {
        let w = Double(displayWidth), h = Double(displayHeight)
        var scale = 1.0
        if max != .original {
            scale = Swift.min(1.0, Double(max.rawValue) / Swift.min(w, h))
        }
        func even(_ v: Double) -> Int { Swift.max(2, Int((v / 2).rounded()) * 2) }
        return PixelSize(width: even(w * scale), height: even(h * scale))
    }

    public static func arguments(input: URL, output: URL, info: MediaInfo,
                                 settings: EncodeSettings) throws -> [String] {
        guard let video = info.video else { throw CommandBuilderError.noVideoStream }

        var args = [
            "-hide_banner", "-nostdin",
            "-n",                       // never overwrite an existing file
            "-v", "error",
            "-progress", "pipe:1", "-nostats",
            "-i", input.path,
            "-map", "0:v:0",
        ]
        if info.audio != nil { args += ["-map", "0:a:0"] }

        let target = outputSize(displayWidth: video.displayWidth, displayHeight: video.displayHeight,
                                max: settings.maxResolution)
        if target.width != video.displayWidth || target.height != video.displayHeight {
            args += ["-vf", "scale=\(target.width):\(target.height):flags=lanczos"]
        }

        args += [
            "-c:v", "libx264",
            "-preset", "medium",
            "-crf", String(crf(forQuality: settings.quality)),
            "-profile:v", "high",
            "-pix_fmt", "yuv420p",      // 8-bit 4:2:0 plays everywhere
        ]

        if info.audio != nil {
            args += ["-c:a", "aac", "-b:a", "128k", "-ac", "2"]
        } else {
            args += ["-an"]
        }

        args += [
            "-sn", "-dn",               // drop subtitle and data tracks
            "-movflags", "+faststart",  // playback can start before the download finishes
            output.path,
        ]
        return args
    }
}
