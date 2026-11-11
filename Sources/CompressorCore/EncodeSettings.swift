import Foundation

public enum OutputFormat: String, CaseIterable, Sendable, Identifiable {
    case mp4H264, mp4HEVC, webmVP9, webmAV1, mp4AV1, gif

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .mp4H264: "MP4 (H.264)"
        case .mp4HEVC: "MP4 (HEVC / H.265)"
        case .webmVP9: "WebM (VP9)"
        case .webmAV1: "WebM (AV1)"
        case .mp4AV1: "MP4 (AV1)"
        case .gif: "Animated GIF"
        }
    }

    public var note: String {
        switch self {
        case .mp4H264: "Plays everywhere. The safe default."
        case .mp4HEVC: "Smaller than H.264. Safari and recent Chrome and Edge; not Firefox on every system."
        case .webmVP9: "Smaller than H.264. Chrome, Firefox, Edge and recent Safari."
        case .webmAV1: "Smallest files, slowest to encode. Chrome, Firefox, Edge."
        case .mp4AV1: "Smallest files, slowest to encode. Safari plays it only on newer Apple devices."
        case .gif: "No sound, 15 frames per second, large files. Only for very short clips."
        }
    }

    public var fileExtension: String {
        switch self {
        case .mp4H264, .mp4HEVC, .mp4AV1: "mp4"
        case .webmVP9, .webmAV1: "webm"
        case .gif: "gif"
        }
    }

    public var isMP4: Bool { fileExtension == "mp4" }
    public var hasAudio: Bool { self != .gif }
    public var hasQualitySetting: Bool { self != .gif }

    public var softwareEncoder: String {
        switch self {
        case .mp4H264: "libx264"
        case .mp4HEVC: "libx265"
        case .webmVP9: "libvpx-vp9"
        case .webmAV1, .mp4AV1: "libsvtav1"
        case .gif: "gif"
        }
    }

    /// Apple's VideoToolbox encoder, where one exists for the codec.
    public var hardwareEncoder: String? {
        switch self {
        case .mp4H264: "h264_videotoolbox"
        case .mp4HEVC: "hevc_videotoolbox"
        default: nil
        }
    }

    /// AAC in MP4 and Opus in WebM are the pairings every browser accepts.
    public var audioEncoder: String? {
        switch self {
        case .mp4H264, .mp4HEVC, .mp4AV1: "aac"
        case .webmVP9, .webmAV1: "libopus"
        case .gif: nil
        }
    }
}

public enum MaxResolution: Int, CaseIterable, Sendable, Identifiable {
    case original = 0
    case p1080 = 1080
    case p720 = 720
    case p480 = 480

    public var id: Int { rawValue }
    public var label: String { self == .original ? "Original" : "\(rawValue)p" }
}

public enum FrameRateCap: Int, CaseIterable, Sendable, Identifiable {
    case original = 0
    case fps30 = 30
    case fps24 = 24

    public var id: Int { rawValue }
    public var label: String { self == .original ? "Original" : "\(rawValue) fps" }
}

public enum AudioMode: String, CaseIterable, Sendable, Identifiable {
    case keep, low, remove

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .keep: "Keep"
        case .low: "Smaller"
        case .remove: "Remove"
        }
    }
}

public enum Preset: String, CaseIterable, Sendable, Identifiable {
    case hero, standard, small, custom

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .hero: "Hero background video"
        case .standard: "Standard web video"
        case .small: "Small / mobile"
        case .custom: "Custom"
        }
    }
}

public struct EncodeSettings: Sendable, Equatable {
    public var format: OutputFormat
    /// 0 (smallest file) ... 100 (highest quality).
    public var quality: Int
    public var maxResolution: MaxResolution
    public var frameRateCap: FrameRateCap
    public var audio: AudioMode
    /// Use VideoToolbox where the format allows it: much faster, larger files.
    public var useHardware: Bool
    public var stripMetadata: Bool

    public init(format: OutputFormat = .mp4H264, quality: Int = 50, maxResolution: MaxResolution = .p1080,
                frameRateCap: FrameRateCap = .original, audio: AudioMode = .keep,
                useHardware: Bool = false, stripMetadata: Bool = true) {
        self.format = format
        self.quality = quality
        self.maxResolution = maxResolution
        self.frameRateCap = frameRateCap
        self.audio = audio
        self.useHardware = useHardware
        self.stripMetadata = stripMetadata
    }

    public var qualityLabel: String {
        switch quality {
        case 67...: "High"
        case 34...66: "Balanced"
        default: "Small"
        }
    }

    /// True when this job will actually run on the hardware encoder.
    public var usesHardwareEncoder: Bool { useHardware && format.hardwareEncoder != nil }

    // MARK: Presets

    /// Presets set quality, size, frame rate and audio. Format, encoder choice
    /// and metadata handling are left as they are.
    public mutating func apply(_ preset: Preset) {
        switch preset {
        case .hero:
            quality = 45; maxResolution = .p1080; frameRateCap = .fps30; audio = .remove
        case .standard:
            quality = 50; maxResolution = .p1080; frameRateCap = .original; audio = .keep
        case .small:
            quality = 30; maxResolution = .p720; frameRateCap = .fps30; audio = .low
        case .custom:
            break
        }
    }

    /// The preset these settings currently correspond to, or `.custom`.
    public var preset: Preset {
        for candidate in [Preset.hero, .standard, .small] {
            var copy = self
            copy.apply(candidate)
            if copy == self { return candidate }
        }
        return .custom
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
