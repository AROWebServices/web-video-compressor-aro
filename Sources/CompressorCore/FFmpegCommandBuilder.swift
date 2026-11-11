import Foundation

/// What the installed FFmpeg build can do. Builds differ a lot, so the app asks.
public struct FFmpegCapabilities: Sendable, Equatable {
    public enum HDRConversion: Sendable, Equatable {
        /// zscale + tonemap filters (needs FFmpeg built with zimg).
        case zscaleTonemap
        /// The scale filter's own transfer conversion (FFmpeg 7.1 and later).
        case scaleFilter
        /// No way to convert; HDR sources will look washed out.
        case unavailable
    }

    public var encoders: Set<String>
    public var hdrConversion: HDRConversion

    public init(encoders: Set<String>, hdrConversion: HDRConversion) {
        self.encoders = encoders
        self.hdrConversion = hdrConversion
    }

    /// - Parameters:
    ///   - encodersOutput: text printed by `ffmpeg -encoders`
    ///   - filtersOutput: text printed by `ffmpeg -filters`
    ///   - scaleHelp: text printed by `ffmpeg -h filter=scale`
    public static func parse(encodersOutput: String, filtersOutput: String, scaleHelp: String) -> FFmpegCapabilities {
        // Both listings are " FLAGS name description"; the name is the second word.
        func names(_ text: String) -> Set<String> {
            Set(text.split(whereSeparator: \.isNewline).compactMap { line in
                let words = line.split(separator: " ", omittingEmptySubsequences: true)
                return words.count >= 2 ? String(words[1]) : nil
            })
        }
        let filters = names(filtersOutput)
        let hdr: HDRConversion
        if filters.contains("zscale") && filters.contains("tonemap") {
            hdr = .zscaleTonemap
        } else if scaleHelp.contains("out_transfer") {
            hdr = .scaleFilter
        } else {
            hdr = .unavailable
        }
        return FFmpegCapabilities(encoders: names(encodersOutput), hdrConversion: hdr)
    }

    public func supports(_ format: OutputFormat) -> Bool {
        guard encoders.contains(format.softwareEncoder) else { return false }
        if let audio = format.audioEncoder { return encoders.contains(audio) }
        return true
    }

    public func supportsHardware(_ format: OutputFormat) -> Bool {
        format.hardwareEncoder.map(encoders.contains) ?? false
    }
}

public enum CommandBuilderError: Error, Equatable {
    case noVideoStream
}

/// Turns settings plus probe data into an FFmpeg argument list. Pure: no I/O.
public enum FFmpegCommandBuilder {
    public static let gifFrameRate = 15.0

    // MARK: Quality

    /// The number handed to the encoder for a 0...100 quality setting. Every
    /// encoder has its own scale, so "Balanced" lands on each one's sensible middle.
    public static func qualityValue(forQuality quality: Int, encoder: String) -> Int {
        let q = Double(min(max(quality, 0), 100)) / 100
        func lerp(_ small: Double, _ high: Double) -> Int { Int((small + (high - small) * q).rounded()) }
        switch encoder {
        case "libx264": return lerp(30, 18)          // CRF, lower is better
        case "libx265": return lerp(34, 22)          // CRF
        case "libvpx-vp9": return lerp(42, 24)       // CRF
        case "libsvtav1": return lerp(48, 24)        // CRF
        case "h264_videotoolbox", "hevc_videotoolbox":
            return lerp(35, 75)                      // -q:v, higher is better
        default: return lerp(30, 18)
        }
    }

    // MARK: Geometry and timing

    /// Output dimensions: the short side is capped at the chosen resolution, the
    /// aspect ratio is kept, nothing is upscaled, and both sides are even
    /// (4:2:0 video requires that).
    public static func outputSize(displayWidth: Int, displayHeight: Int, max: MaxResolution) -> PixelSize {
        let w = Double(displayWidth), h = Double(displayHeight)
        var scale = 1.0
        if max != .original {
            scale = Swift.min(1.0, Double(max.rawValue) / Swift.min(w, h))
        }
        func even(_ v: Double) -> Int { Swift.max(2, Int((v / 2).rounded()) * 2) }
        return PixelSize(width: even(w * scale), height: even(h * scale))
    }

    /// The constant frame rate to force, or nil to leave timing alone.
    /// A cap never raises the rate. Variable frame rate input is always made constant.
    public static func outputFrameRate(video: VideoStream, settings: EncodeSettings) -> Double? {
        var limit: Double? = settings.frameRateCap == .original ? nil : Double(settings.frameRateCap.rawValue)
        if settings.format == .gif {
            limit = Swift.min(limit ?? gifFrameRate, gifFrameRate)
        }
        guard let source = video.frameRate else {
            return limit   // unknown source rate: only GIF and explicit caps apply
        }
        if let limit, source > limit + 0.5 { return limit }
        if video.isVariableFrameRate {
            // Snap to a conventional rate rather than an odd average like 29.31.
            let common = [24.0, 25, 30, 48, 50, 60]
            let nearest = common.min { abs($0 - source) < abs($1 - source) } ?? source
            return abs(nearest - source) < 1.5 ? nearest : source.rounded()
        }
        return nil
    }

    private static func format(rate: Double) -> String {
        rate == rate.rounded() ? String(Int(rate)) : String(format: "%.3f", rate)
    }

    // MARK: Arguments

    public static func arguments(input: URL, output: URL, info: MediaInfo, settings: EncodeSettings,
                                 capabilities: FFmpegCapabilities) throws -> [String] {
        guard let video = info.video else { throw CommandBuilderError.noVideoStream }
        let format = settings.format
        let keepAudio = info.audio != nil && format.hasAudio && settings.audio != .remove

        var args = [
            "-hide_banner", "-nostdin",
            "-n",                       // never overwrite an existing file
            "-v", "error",
            "-progress", "pipe:1", "-nostats",
            "-i", input.path,
            "-map", "0:v:0",
        ]
        if keepAudio { args += ["-map", "0:a:0"] }

        // Video filters, in order: frame rate, size and colour, GIF palette.
        var filters: [String] = []
        if let rate = outputFrameRate(video: video, settings: settings) {
            filters.append("fps=\(Self.format(rate: rate))")
        }

        let target = outputSize(displayWidth: video.displayWidth, displayHeight: video.displayHeight,
                                max: settings.maxResolution)
        let needsResize = target.width != video.displayWidth || target.height != video.displayHeight
        let convertHDR = video.isHDR && capabilities.hdrConversion != .unavailable
        let size = "\(target.width):\(target.height):flags=lanczos"
        if convertHDR && capabilities.hdrConversion == .scaleFilter {
            filters.append("scale=\(size):out_transfer=bt709:out_primaries=bt709:out_color_matrix=bt709")
        } else {
            if needsResize { filters.append("scale=\(size)") }
            if convertHDR {
                filters += [
                    "zscale=t=linear:npl=100", "format=gbrpf32le", "zscale=p=bt709",
                    "tonemap=tonemap=hable:desat=0", "zscale=t=bt709:m=bt709:r=tv",
                ]
            }
        }
        if format == .gif {
            filters.append("split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5")
        }
        if !filters.isEmpty { args += ["-vf", filters.joined(separator: ",")] }

        // Video encoder.
        let encoder = settings.usesHardwareEncoder ? format.hardwareEncoder! : format.softwareEncoder
        let quality = String(qualityValue(forQuality: settings.quality, encoder: encoder))
        switch encoder {
        case "libx264":
            args += ["-c:v", "libx264", "-preset", "medium", "-crf", quality, "-profile:v", "high"]
        case "libx265":
            args += ["-c:v", "libx265", "-preset", "medium", "-crf", quality,
                     "-x265-params", "log-level=error", "-tag:v", "hvc1"]
        case "libvpx-vp9":
            // -b:v 0 switches VP9 to pure constant-quality mode.
            args += ["-c:v", "libvpx-vp9", "-crf", quality, "-b:v", "0",
                     "-row-mt", "1", "-deadline", "good", "-cpu-used", "2"]
        case "libsvtav1":
            args += ["-c:v", "libsvtav1", "-crf", quality, "-preset", "8"]
        case "h264_videotoolbox":
            args += ["-c:v", "h264_videotoolbox", "-q:v", quality, "-profile:v", "high"]
        case "hevc_videotoolbox":
            args += ["-c:v", "hevc_videotoolbox", "-q:v", quality, "-tag:v", "hvc1"]
        default: // gif
            args += ["-c:v", "gif", "-loop", "0"]
        }
        if format != .gif {
            args += ["-pix_fmt", "yuv420p"]     // 8-bit 4:2:0 plays everywhere
            if convertHDR {
                args += ["-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709"]
            }
        }

        // Audio.
        if keepAudio, let audioEncoder = format.audioEncoder {
            let bitrate: String
            switch (audioEncoder, settings.audio) {
            case ("libopus", .low): bitrate = "48k"
            case ("libopus", _): bitrate = "96k"
            case (_, .low): bitrate = "64k"
            default: bitrate = "128k"
            }
            args += ["-c:a", audioEncoder, "-b:a", bitrate, "-ac", "2"]
        } else {
            args += ["-an"]
        }

        args += ["-sn", "-dn"]                  // drop subtitle and data tracks
        if settings.stripMetadata {
            args += ["-map_metadata", "-1", "-map_chapters", "-1"]
        }
        if format.isMP4 {
            args += ["-movflags", "+faststart"] // playback can start before the download finishes
        }
        args.append(output.path)
        return args
    }
}
