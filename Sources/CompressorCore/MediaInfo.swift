import Foundation

/// What we know about an input file, taken from `ffprobe -print_format json`.
public struct MediaInfo: Sendable, Equatable {
    public var duration: Double
    public var fileSize: Int64?
    public var bitRate: Int?
    public var video: VideoStream?
    public var audio: AudioStream?

    public init(duration: Double, fileSize: Int64? = nil, bitRate: Int? = nil,
                video: VideoStream? = nil, audio: AudioStream? = nil) {
        self.duration = duration
        self.fileSize = fileSize
        self.bitRate = bitRate
        self.video = video
        self.audio = audio
    }
}

public struct VideoStream: Sendable, Equatable {
    public var codec: String
    /// Stored (coded) dimensions, before rotation is applied.
    public var width: Int
    public var height: Int
    /// Rotation in degrees from the display matrix or the legacy `rotate` tag.
    public var rotation: Int
    /// Average frame rate.
    public var frameRate: Double?
    /// The container's base frame rate; differs from the average for variable frame rate video.
    public var baseFrameRate: Double?
    public var pixelFormat: String?
    public var colorTransfer: String?
    /// Four-character sample entry, e.g. "hvc1" or "avc1".
    public var codecTag: String?

    public init(codec: String, width: Int, height: Int, rotation: Int = 0, frameRate: Double? = nil,
                baseFrameRate: Double? = nil, pixelFormat: String? = nil, colorTransfer: String? = nil,
                codecTag: String? = nil) {
        self.codec = codec
        self.width = width
        self.height = height
        self.rotation = rotation
        self.frameRate = frameRate
        self.baseFrameRate = baseFrameRate
        self.pixelFormat = pixelFormat
        self.colorTransfer = colorTransfer
        self.codecTag = codecTag
    }

    /// PQ (HDR10, Dolby Vision) or HLG (iPhone HDR). These look washed out in
    /// browsers unless converted to standard dynamic range.
    public var isHDR: Bool {
        colorTransfer == "smpte2084" || colorTransfer == "arib-std-b67"
    }

    /// Screen recordings and phone footage often have an uneven frame rate.
    public var isVariableFrameRate: Bool {
        guard let frameRate, let baseFrameRate, frameRate > 0 else { return false }
        return abs(baseFrameRate - frameRate) / frameRate > 0.02
    }

    private var isSideways: Bool { abs(rotation) % 180 == 90 }
    /// Dimensions as a viewer sees them (FFmpeg auto-rotates on decode).
    public var displayWidth: Int { isSideways ? height : width }
    public var displayHeight: Int { isSideways ? width : height }
}

public struct AudioStream: Sendable, Equatable {
    public var codec: String
    public var channels: Int?
    public var bitRate: Int?

    public init(codec: String, channels: Int? = nil, bitRate: Int? = nil) {
        self.codec = codec
        self.channels = channels
        self.bitRate = bitRate
    }
}

public enum MediaInfoError: Error, Equatable {
    case unreadableProbeOutput
}

extension MediaInfo {
    /// Parses the JSON printed by `ffprobe -print_format json -show_format -show_streams`.
    public static func parse(ffprobeJSON data: Data) throws -> MediaInfo {
        let raw: RawProbe
        do {
            raw = try JSONDecoder().decode(RawProbe.self, from: data)
        } catch {
            throw MediaInfoError.unreadableProbeOutput
        }
        let streams = raw.streams ?? []

        // Cover art is reported as a video stream; skip it.
        let rawVideo = streams.first { $0.codec_type == "video" && $0.disposition?.attached_pic?.value != 1 }
        let rawAudio = streams.first { $0.codec_type == "audio" }

        let video: VideoStream? = rawVideo.flatMap { s in
            guard let w = s.width?.value, let h = s.height?.value, w > 0, h > 0 else { return nil }
            let matrixRotation = s.side_data_list?.compactMap { $0.rotation?.value }.first
            let tagRotation = s.tags?["rotate"].flatMap { Double($0) }
            return VideoStream(
                codec: s.codec_name ?? "unknown",
                width: Int(w), height: Int(h),
                rotation: Int((matrixRotation ?? tagRotation ?? 0).rounded()),
                frameRate: parseRate(s.avg_frame_rate) ?? parseRate(s.r_frame_rate),
                baseFrameRate: parseRate(s.r_frame_rate),
                pixelFormat: s.pix_fmt,
                colorTransfer: s.color_transfer,
                codecTag: s.codec_tag_string)
        }
        let audio: AudioStream? = rawAudio.map { s in
            AudioStream(codec: s.codec_name ?? "unknown",
                        channels: s.channels.map { Int($0.value) },
                        bitRate: s.bit_rate.map { Int($0.value) })
        }

        let duration = raw.format?.duration?.value
            ?? rawVideo?.duration?.value
            ?? rawAudio?.duration?.value
            ?? 0
        return MediaInfo(duration: duration,
                         fileSize: raw.format?.size.map { Int64($0.value) },
                         bitRate: raw.format?.bit_rate.map { Int($0.value) },
                         video: video, audio: audio)
    }

    /// "30000/1001" -> 29.97. Returns nil for "0/0" and other junk.
    static func parseRate(_ text: String?) -> Double? {
        guard let text else { return nil }
        let parts = text.split(separator: "/")
        if parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]) {
            return d > 0 && n > 0 ? n / d : nil
        }
        return Double(text).flatMap { $0 > 0 ? $0 : nil }
    }
}

// MARK: - Raw ffprobe JSON

/// ffprobe prints most numbers as strings but some as real numbers; accept both.
private struct FlexibleNumber: Decodable {
    let value: Double
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) {
            value = d
        } else if let s = try? c.decode(String.self), let d = Double(s) {
            value = d
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "not a number")
        }
    }
}

private struct RawProbe: Decodable {
    var streams: [RawStream]?
    var format: RawFormat?
}

private struct RawFormat: Decodable {
    var duration: FlexibleNumber?
    var size: FlexibleNumber?
    var bit_rate: FlexibleNumber?

    enum CodingKeys: String, CodingKey { case duration, size, bit_rate }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        duration = try? c.decode(FlexibleNumber.self, forKey: .duration)
        size = try? c.decode(FlexibleNumber.self, forKey: .size)
        bit_rate = try? c.decode(FlexibleNumber.self, forKey: .bit_rate)
    }
}

private struct RawStream: Decodable {
    var codec_type: String?
    var codec_name: String?
    var width: FlexibleNumber?
    var height: FlexibleNumber?
    var r_frame_rate: String?
    var avg_frame_rate: String?
    var pix_fmt: String?
    var color_transfer: String?
    var codec_tag_string: String?
    var channels: FlexibleNumber?
    var bit_rate: FlexibleNumber?
    var duration: FlexibleNumber?
    var tags: [String: String]?
    var side_data_list: [RawSideData]?
    var disposition: RawDisposition?

    enum CodingKeys: String, CodingKey {
        case codec_type, codec_name, width, height, r_frame_rate, avg_frame_rate, pix_fmt
        case color_transfer, codec_tag_string, channels, bit_rate, duration, tags, side_data_list, disposition
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        codec_type = try? c.decode(String.self, forKey: .codec_type)
        codec_name = try? c.decode(String.self, forKey: .codec_name)
        width = try? c.decode(FlexibleNumber.self, forKey: .width)
        height = try? c.decode(FlexibleNumber.self, forKey: .height)
        r_frame_rate = try? c.decode(String.self, forKey: .r_frame_rate)
        avg_frame_rate = try? c.decode(String.self, forKey: .avg_frame_rate)
        pix_fmt = try? c.decode(String.self, forKey: .pix_fmt)
        color_transfer = try? c.decode(String.self, forKey: .color_transfer)
        codec_tag_string = try? c.decode(String.self, forKey: .codec_tag_string)
        channels = try? c.decode(FlexibleNumber.self, forKey: .channels)
        bit_rate = try? c.decode(FlexibleNumber.self, forKey: .bit_rate)
        duration = try? c.decode(FlexibleNumber.self, forKey: .duration)
        tags = try? c.decode([String: String].self, forKey: .tags)
        side_data_list = try? c.decode([RawSideData].self, forKey: .side_data_list)
        disposition = try? c.decode(RawDisposition.self, forKey: .disposition)
    }
}

private struct RawSideData: Decodable {
    var rotation: FlexibleNumber?
    enum CodingKeys: String, CodingKey { case rotation }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rotation = try? c.decode(FlexibleNumber.self, forKey: .rotation)
    }
}

private struct RawDisposition: Decodable {
    var attached_pic: FlexibleNumber?
    enum CodingKeys: String, CodingKey { case attached_pic }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        attached_pic = try? c.decode(FlexibleNumber.self, forKey: .attached_pic)
    }
}
