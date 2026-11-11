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
        if format == .webBundle {
            return format.components.allSatisfy(supports) && encoders.contains("mjpeg")
        }
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

    // MARK: Target size

    /// Encoders that can do a first analysis pass, which makes hitting a size
    /// target much more accurate.
    public static let twoPassEncoders: Set<String> = ["libx264", "libx265", "libvpx-vp9"]

    public static func audioBitrateKbps(format: OutputFormat, mode: AudioMode) -> Int {
        switch (format.audioEncoder, mode) {
        case (nil, _), (_, .remove): 0
        case ("libopus", .low): 48
        case ("libopus", _): 96
        case (_, .low): 64
        default: 128
        }
    }

    /// Video bitrate that makes the whole file land on the target size.
    /// 3% is held back for container overhead; the floor keeps the picture
    /// from collapsing entirely when the target is unrealistically small.
    public static func videoBitrateKbps(targetMB: Double, duration: Double, audioKbps: Int) -> Int {
        guard duration > 0 else { return 1000 }
        let totalKbps = targetMB * 8000 * 0.97 / duration
        return Swift.max(50, Int(totalKbps) - audioKbps)
    }

    // MARK: Filters

    /// Resize and HDR-to-SDR filters. `alwaysScale` forces an explicit size
    /// even when the source already fits (used for the poster image).
    static func sizeAndColourFilters(video: VideoStream, settings: EncodeSettings,
                                     capabilities: FFmpegCapabilities, alwaysScale: Bool = false) -> [String] {
        let target = outputSize(displayWidth: video.displayWidth, displayHeight: video.displayHeight,
                                max: settings.maxResolution)
        let needsResize = alwaysScale
            || target.width != video.displayWidth || target.height != video.displayHeight
        let convertHDR = video.isHDR && capabilities.hdrConversion != .unavailable
        let size = "\(target.width):\(target.height):flags=lanczos"
        if convertHDR && capabilities.hdrConversion == .scaleFilter {
            return ["scale=\(size):out_transfer=bt709:out_primaries=bt709:out_color_matrix=bt709"]
        }
        var filters: [String] = []
        if needsResize { filters.append("scale=\(size)") }
        if convertHDR {
            filters += [
                "zscale=t=linear:npl=100", "format=gbrpf32le", "zscale=p=bt709",
                "tonemap=tonemap=hable:desat=0", "zscale=t=bt709:m=bt709:r=tv",
            ]
        }
        return filters
    }

    private static func seconds(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    // MARK: Arguments

    /// One pass of a two-pass encode.
    public struct Pass: Sendable, Equatable {
        public var number: Int          // 1 = analysis, 2 = final
        public var logBase: URL         // where the encoder keeps its statistics
        public init(number: Int, logBase: URL) {
            self.number = number
            self.logBase = logBase
        }
    }

    /// The FFmpeg runs needed for one output file: one normally, two when a
    /// size target is set and the encoder supports an analysis pass.
    public static func passes(input: URL, output: URL, info: MediaInfo, settings: EncodeSettings,
                              trim: TrimRange? = nil, capabilities: FFmpegCapabilities,
                              passLogBase: URL) throws -> [[String]] {
        let encoder = settings.usesHardwareEncoder ? settings.format.hardwareEncoder! : settings.format.softwareEncoder
        guard settings.effectiveTargetSizeMB != nil, twoPassEncoders.contains(encoder) else {
            return [try arguments(input: input, output: output, info: info, settings: settings,
                                  trim: trim, capabilities: capabilities)]
        }
        return try [1, 2].map { number in
            try arguments(input: input, output: output, info: info, settings: settings, trim: trim,
                          capabilities: capabilities, pass: Pass(number: number, logBase: passLogBase))
        }
    }

    public static func arguments(input: URL, output: URL, info: MediaInfo, settings: EncodeSettings,
                                 trim: TrimRange? = nil, capabilities: FFmpegCapabilities,
                                 pass: Pass? = nil) throws -> [String] {
        guard let video = info.video else { throw CommandBuilderError.noVideoStream }
        let format = settings.format
        let analysisOnly = pass?.number == 1
        let keepAudio = info.audio != nil && format.hasAudio && settings.audio != .remove
        let kept = trim?.resolved(duration: info.duration)
        let duration = kept?.length ?? info.duration

        var args = [
            "-hide_banner", "-nostdin",
            "-n",                       // never overwrite an existing file
            "-v", "error",
            "-progress", "pipe:1", "-nostats",
        ]
        // Seeking before -i is fast, and still frame-accurate because we re-encode.
        if let kept, kept.start > 0 { args += ["-ss", seconds(kept.start)] }
        args += ["-i", input.path]
        if let kept { args += ["-t", seconds(kept.length)] }
        args += ["-map", "0:v:0"]
        if keepAudio && !analysisOnly { args += ["-map", "0:a:0"] }

        // Video filters, in order: frame rate, size and colour, GIF palette.
        var filters: [String] = []
        if let rate = outputFrameRate(video: video, settings: settings) {
            filters.append("fps=\(Self.format(rate: rate))")
        }
        filters += sizeAndColourFilters(video: video, settings: settings, capabilities: capabilities)
        let convertHDR = video.isHDR && capabilities.hdrConversion != .unavailable
        if format == .gif {
            filters.append("split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5")
        }
        if !filters.isEmpty { args += ["-vf", filters.joined(separator: ",")] }

        // Video encoder: by quality, or by bitrate when aiming for a file size.
        let encoder = settings.usesHardwareEncoder ? format.hardwareEncoder! : format.softwareEncoder
        let quality = String(qualityValue(forQuality: settings.quality, encoder: encoder))
        let bitrate: String? = settings.effectiveTargetSizeMB.map { target in
            let audio = keepAudio ? audioBitrateKbps(format: format, mode: settings.audio) : 0
            return "\(videoBitrateKbps(targetMB: target, duration: duration, audioKbps: audio))k"
        }
        let rateControl = bitrate.map { ["-b:v", $0] }
        var passFlags: [String] = []
        if let pass, encoder != "libx265" {
            passFlags = ["-pass", String(pass.number), "-passlogfile", pass.logBase.path]
        }
        switch encoder {
        case "libx264":
            args += ["-c:v", "libx264", "-preset", "medium"] + (rateControl ?? ["-crf", quality])
                + ["-profile:v", "high"] + passFlags
        case "libx265":
            var params = "log-level=error"
            if let pass { params += ":pass=\(pass.number):stats=\(pass.logBase.path)" }
            args += ["-c:v", "libx265", "-preset", "medium"] + (rateControl ?? ["-crf", quality])
                + ["-x265-params", params, "-tag:v", "hvc1"]
        case "libvpx-vp9":
            // In quality mode, -b:v 0 switches VP9 to pure constant quality.
            args += ["-c:v", "libvpx-vp9"] + (rateControl ?? ["-crf", quality, "-b:v", "0"])
                + ["-row-mt", "1", "-deadline", "good", "-cpu-used", "2"] + passFlags
        case "libsvtav1":
            args += ["-c:v", "libsvtav1"] + (rateControl ?? ["-crf", quality]) + ["-preset", "8"]
        case "h264_videotoolbox":
            args += ["-c:v", "h264_videotoolbox"] + (rateControl ?? ["-q:v", quality]) + ["-profile:v", "high"]
        case "hevc_videotoolbox":
            args += ["-c:v", "hevc_videotoolbox"] + (rateControl ?? ["-q:v", quality]) + ["-tag:v", "hvc1"]
        default: // gif
            args += ["-c:v", "gif", "-loop", "0"]
        }
        if format != .gif {
            args += ["-pix_fmt", "yuv420p"]     // 8-bit 4:2:0 plays everywhere
            if convertHDR {
                args += ["-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709"]
            }
        }

        // The analysis pass only gathers statistics; nothing is written.
        if analysisOnly {
            return args + ["-an", "-sn", "-dn", "-f", "null", "-"]
        }

        // Audio.
        if keepAudio, let audioEncoder = format.audioEncoder {
            let kbps = audioBitrateKbps(format: format, mode: settings.audio)
            args += ["-c:a", audioEncoder, "-b:a", "\(kbps)k", "-ac", "2"]
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

    /// A single JPEG still of the first frame that will be shown, at the same
    /// size as the video, so the page does not jump when playback starts.
    public static func posterArguments(input: URL, output: URL, info: MediaInfo, settings: EncodeSettings,
                                       trim: TrimRange? = nil,
                                       capabilities: FFmpegCapabilities) throws -> [String] {
        guard let video = info.video else { throw CommandBuilderError.noVideoStream }
        var args = ["-hide_banner", "-nostdin", "-n", "-v", "error"]
        if let kept = trim?.resolved(duration: info.duration), kept.start > 0 {
            args += ["-ss", seconds(kept.start)]
        }
        let filters = sizeAndColourFilters(video: video, settings: settings, capabilities: capabilities,
                                           alwaysScale: true)
        args += [
            "-i", input.path, "-map", "0:v:0", "-frames:v", "1",
            "-vf", filters.joined(separator: ","),
            "-c:v", "mjpeg", "-q:v", "3", "-pix_fmt", "yuvj420p",
            "-update", "1", output.path,
        ]
        return args
    }
}
