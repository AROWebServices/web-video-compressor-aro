import Foundation
import Testing
@testable import CompressorCore

private let input = URL(fileURLWithPath: "/videos/clip.mov")

private let allEncoders: Set<String> = ["libx264", "libx265", "libvpx-vp9", "libsvtav1", "gif", "aac", "libopus",
                                        "h264_videotoolbox", "hevc_videotoolbox"]

private func caps(_ hdr: FFmpegCapabilities.HDRConversion = .scaleFilter) -> FFmpegCapabilities {
    FFmpegCapabilities(encoders: allEncoders, hdrConversion: hdr)
}

private func source(width: Int = 1920, height: Int = 1080, audio: Bool = true, frameRate: Double? = 30,
                    baseFrameRate: Double? = nil, transfer: String? = nil) -> MediaInfo {
    MediaInfo(duration: 10,
              video: VideoStream(codec: "h264", width: width, height: height, frameRate: frameRate,
                                 baseFrameRate: baseFrameRate ?? frameRate, colorTransfer: transfer),
              audio: audio ? AudioStream(codec: "aac", channels: 2) : nil)
}

private func build(_ settings: EncodeSettings, _ info: MediaInfo = source(),
                   _ capabilities: FFmpegCapabilities = caps()) throws -> [String] {
    let output = URL(fileURLWithPath: "/videos/clip-web.\(settings.format.fileExtension)")
    return try FFmpegCommandBuilder.arguments(input: input, output: output, info: info, settings: settings,
                                              capabilities: capabilities)
}

private func value(after flag: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

@Suite struct FormatTests {
    @Test func hevcIsTaggedForSafari() throws {
        let args = try build(EncodeSettings(format: .mp4HEVC))
        #expect(value(after: "-c:v", in: args) == "libx265")
        #expect(value(after: "-tag:v", in: args) == "hvc1")
        #expect(value(after: "-crf", in: args) == "28")
        #expect(value(after: "-c:a", in: args) == "aac")
        #expect(value(after: "-movflags", in: args) == "+faststart")
        #expect(args.last?.hasSuffix(".mp4") == true)
    }

    @Test func vp9UsesConstantQualityAndOpus() throws {
        let args = try build(EncodeSettings(format: .webmVP9))
        #expect(value(after: "-c:v", in: args) == "libvpx-vp9")
        #expect(value(after: "-b:v", in: args) == "0")
        #expect(value(after: "-crf", in: args) == "33")
        #expect(value(after: "-c:a", in: args) == "libopus")
        #expect(value(after: "-b:a", in: args) == "96k")
        #expect(!args.contains("-movflags"))
        #expect(args.last?.hasSuffix(".webm") == true)
    }

    @Test func av1InWebMAndMP4() throws {
        let webm = try build(EncodeSettings(format: .webmAV1))
        #expect(value(after: "-c:v", in: webm) == "libsvtav1")
        #expect(value(after: "-c:a", in: webm) == "libopus")
        #expect(!webm.contains("-movflags"))

        let mp4 = try build(EncodeSettings(format: .mp4AV1))
        #expect(value(after: "-c:v", in: mp4) == "libsvtav1")
        #expect(value(after: "-c:a", in: mp4) == "aac")
        #expect(value(after: "-movflags", in: mp4) == "+faststart")
    }

    @Test(arguments: [OutputFormat.mp4H264, .mp4HEVC, .webmVP9, .webmAV1, .mp4AV1])
    func everyVideoFormatIs8Bit420(format: OutputFormat) throws {
        let args = try build(EncodeSettings(format: format))
        #expect(value(after: "-pix_fmt", in: args) == "yuv420p")
    }

    @Test func gifUsesAPaletteAndHasNoAudio() throws {
        let args = try build(EncodeSettings(format: .gif, maxResolution: .p480))
        let filters = try #require(value(after: "-vf", in: args))
        #expect(filters.hasPrefix("fps=15,scale=854:480:flags=lanczos,split"))
        #expect(filters.contains("palettegen"))
        #expect(filters.contains("paletteuse"))
        #expect(args.contains("-an"))
        #expect(!args.contains("-pix_fmt"))
        #expect(!args.contains("-crf"))
        #expect(args.last?.hasSuffix(".gif") == true)
    }

    @Test func gifKeepsALowerSourceFrameRate() throws {
        let args = try build(EncodeSettings(format: .gif), source(frameRate: 10))
        #expect(value(after: "-vf", in: args)?.contains("fps=") == false)
    }
}

@Suite struct HardwareTests {
    @Test func hardwareToggleSwitchesToVideoToolbox() throws {
        let h264 = try build(EncodeSettings(format: .mp4H264, useHardware: true))
        #expect(value(after: "-c:v", in: h264) == "h264_videotoolbox")
        #expect(value(after: "-q:v", in: h264) == "55")
        #expect(!h264.contains("-crf"))

        let hevc = try build(EncodeSettings(format: .mp4HEVC, useHardware: true))
        #expect(value(after: "-c:v", in: hevc) == "hevc_videotoolbox")
        #expect(value(after: "-tag:v", in: hevc) == "hvc1")
    }

    @Test func hardwareToggleIsIgnoredWhereThereIsNoHardwareEncoder() throws {
        let settings = EncodeSettings(format: .webmVP9, useHardware: true)
        #expect(!settings.usesHardwareEncoder)
        #expect(value(after: "-c:v", in: try build(settings)) == "libvpx-vp9")
    }
}

@Suite struct AudioTests {
    @Test func smallerAudioLowersTheBitrate() throws {
        #expect(value(after: "-b:a", in: try build(EncodeSettings(format: .mp4H264, audio: .low))) == "64k")
        #expect(value(after: "-b:a", in: try build(EncodeSettings(format: .webmVP9, audio: .low))) == "48k")
        #expect(value(after: "-b:a", in: try build(EncodeSettings(format: .mp4H264, audio: .keep))) == "128k")
    }

    @Test func removeAudioDropsTheTrack() throws {
        let args = try build(EncodeSettings(audio: .remove))
        #expect(args.contains("-an"))
        #expect(!args.contains("0:a:0"))
        #expect(!args.contains("-c:a"))
    }
}

@Suite struct FrameRateTests {
    @Test func capLowersAHighFrameRate() throws {
        let args = try build(EncodeSettings(frameRateCap: .fps30), source(frameRate: 60))
        #expect(value(after: "-vf", in: args) == "fps=30")
    }

    @Test func capNeverRaisesTheFrameRate() throws {
        let args = try build(EncodeSettings(frameRateCap: .fps30), source(frameRate: 24))
        #expect(!args.contains("-vf"))
    }

    @Test func ntscRatesAreNotTreatedAsOverTheCap() throws {
        let args = try build(EncodeSettings(frameRateCap: .fps30), source(frameRate: 29.97))
        #expect(!args.contains("-vf"))
    }

    @Test func variableFrameRateBecomesConstant() throws {
        // A phone clip averaging 29.3 fps on a 60 fps timebase.
        let vfr = source(frameRate: 29.3, baseFrameRate: 60)
        #expect(vfr.video?.isVariableFrameRate == true)
        let args = try build(EncodeSettings(), vfr)
        #expect(value(after: "-vf", in: args) == "fps=30")
    }

    @Test func frameRateFilterComesBeforeScaling() throws {
        let args = try build(EncodeSettings(maxResolution: .p720, frameRateCap: .fps24), source(frameRate: 60))
        #expect(value(after: "-vf", in: args) == "fps=24,scale=1280:720:flags=lanczos")
    }
}

@Suite struct HDRTests {
    @Test func hlgAndPQAreDetected() {
        #expect(source(transfer: "arib-std-b67").video?.isHDR == true)
        #expect(source(transfer: "smpte2084").video?.isHDR == true)
        #expect(source(transfer: "bt709").video?.isHDR == false)
        #expect(source().video?.isHDR == false)
    }

    @Test func scaleFilterConversion() throws {
        let args = try build(EncodeSettings(maxResolution: .original), source(transfer: "arib-std-b67"),
                             caps(.scaleFilter))
        #expect(value(after: "-vf", in: args)
                == "scale=1920:1080:flags=lanczos:out_transfer=bt709:out_primaries=bt709:out_color_matrix=bt709")
        #expect(value(after: "-color_trc", in: args) == "bt709")
        #expect(value(after: "-pix_fmt", in: args) == "yuv420p")
    }

    @Test func zscaleToneMapping() throws {
        let args = try build(EncodeSettings(maxResolution: .p720), source(transfer: "smpte2084"),
                             caps(.zscaleTonemap))
        let filters = try #require(value(after: "-vf", in: args))
        #expect(filters.hasPrefix("scale=1280:720:flags=lanczos,zscale=t=linear"))
        #expect(filters.contains("tonemap=tonemap=hable"))
        #expect(value(after: "-colorspace", in: args) == "bt709")
    }

    @Test func noConversionWhenFFmpegCannot() throws {
        let args = try build(EncodeSettings(maxResolution: .original), source(transfer: "smpte2084"),
                             caps(.unavailable))
        #expect(!args.contains("-vf"))
        #expect(!args.contains("-color_trc"))
    }

    @Test func sdrSourcesAreLeftAlone() throws {
        let args = try build(EncodeSettings(maxResolution: .original), source(transfer: "bt709"))
        #expect(!args.contains("-vf"))
        #expect(!args.contains("-color_trc"))
    }
}

@Suite struct MetadataTests {
    @Test func stripMetadataIsOptional() throws {
        #expect(value(after: "-map_metadata", in: try build(EncodeSettings(stripMetadata: true))) == "-1")
        #expect(!(try build(EncodeSettings(stripMetadata: false))).contains("-map_metadata"))
    }
}

@Suite struct PresetTests {
    @Test func heroPresetIsSilentAndCapped() {
        var settings = EncodeSettings(format: .webmVP9)
        settings.apply(.hero)
        #expect(settings.audio == .remove)
        #expect(settings.maxResolution == .p1080)
        #expect(settings.frameRateCap == .fps30)
        #expect(settings.format == .webmVP9)   // presets leave the format alone
        #expect(settings.preset == .hero)
    }

    @Test func defaultsAreTheStandardPreset() {
        #expect(EncodeSettings().preset == .standard)
    }

    @Test func changingAValueMakesItCustom() {
        var settings = EncodeSettings()
        settings.apply(.small)
        #expect(settings.preset == .small)
        settings.quality = 80
        #expect(settings.preset == .custom)
    }

    @Test func formatAndEncoderChoiceDoNotAffectThePreset() {
        var settings = EncodeSettings()
        settings.format = .mp4AV1
        settings.useHardware = true
        #expect(settings.preset == .standard)
    }
}

@Suite struct CapabilityTests {
    private let encoders = """
    Encoders:
     V..... = Video
     ------
     V....D libx264              libx264 H.264 / AVC (codec h264)
     V....D h264_videotoolbox    VideoToolbox H.264 Encoder (codec h264)
     V....D libvpx-vp9           libvpx VP9 (codec vp9)
     A....D aac                  AAC (Advanced Audio Coding)
     A....D libopus              libopus Opus (codec opus)
    """

    @Test func parsesEncoderList() {
        let caps = FFmpegCapabilities.parse(encodersOutput: encoders, filtersOutput: "", scaleHelp: "")
        #expect(caps.supports(.mp4H264))
        #expect(caps.supports(.webmVP9))
        #expect(!caps.supports(.mp4HEVC))
        #expect(!caps.supports(.webmAV1))
        #expect(!caps.supports(.gif))
        #expect(caps.supportsHardware(.mp4H264))
        #expect(!caps.supportsHardware(.mp4HEVC))
        #expect(!caps.supportsHardware(.webmVP9))
    }

    @Test func picksTheBestHDRConversionAvailable() {
        let withZscale = " ... zscale  V->V  Apply resizing\n ... tonemap  V->V  Tone map\n"
        #expect(FFmpegCapabilities.parse(encodersOutput: "", filtersOutput: withZscale, scaleHelp: "")
            .hdrConversion == .zscaleTonemap)
        #expect(FFmpegCapabilities.parse(encodersOutput: "", filtersOutput: " ... tonemap V->V x",
                                         scaleHelp: "  out_transfer  <int>  set output color transfer")
            .hdrConversion == .scaleFilter)
        #expect(FFmpegCapabilities.parse(encodersOutput: "", filtersOutput: "", scaleHelp: "")
            .hdrConversion == .unavailable)
    }
}
