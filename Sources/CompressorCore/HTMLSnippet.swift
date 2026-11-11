import Foundation

/// Builds the markup to paste into a page for a finished export.
public enum HTMLSnippet {
    /// The `type` attribute for a <source>. The codec string lets a browser skip
    /// a file it cannot play without downloading any of it.
    public static func mimeType(for format: OutputFormat, hasAudio: Bool) -> String {
        let video: String
        let audio: String
        let container: String
        switch format {
        case .webBundle, .mp4H264: (container, video, audio) = ("video/mp4", "avc1.640028", "mp4a.40.2")
        case .mp4HEVC: (container, video, audio) = ("video/mp4", "hvc1.1.6.L123.B0", "mp4a.40.2")
        case .mp4AV1: (container, video, audio) = ("video/mp4", "av01.0.08M.08", "mp4a.40.2")
        case .webmVP9: (container, video, audio) = ("video/webm", "vp9", "opus")
        case .webmAV1: (container, video, audio) = ("video/webm", "av01.0.08M.08", "opus")
        case .gif: return "image/gif"
        }
        return "\(container); codecs=\"\(hasAudio ? "\(video), \(audio)" : video)\""
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
    }

    /// File names are percent-encoded so spaces and accents survive in a URL.
    private static func url(_ fileName: String) -> String {
        escape(fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName)
    }

    /// - Parameters:
    ///   - files: output file names with their formats, in <source> order (preferred first).
    ///   - background: a silent, looping, autoplaying video with no controls (the hero preset).
    public static func make(files: [(name: String, format: OutputFormat)], poster: String?, size: PixelSize,
                            hasAudio: Bool, background: Bool) -> String {
        if let gif = files.first, gif.format == .gif {
            return "<img src=\"\(url(gif.name))\" width=\"\(size.width)\" height=\"\(size.height)\" alt=\"\">"
        }
        var attributes = ["width=\"\(size.width)\"", "height=\"\(size.height)\""]
        if background {
            // Browsers only allow autoplay when the video is muted; playsinline
            // stops iPhones from going full screen.
            attributes += ["autoplay", "muted", "loop", "playsinline"]
        } else {
            attributes += ["controls", "preload=\"metadata\""]
            if !hasAudio { attributes += ["muted", "playsinline"] }
        }
        if let poster { attributes.append("poster=\"\(url(poster))\"") }

        var lines = ["<video \(attributes.joined(separator: " "))>"]
        for file in files {
            let type = mimeType(for: file.format, hasAudio: hasAudio)
            // Single quotes outside, because the codecs list needs double quotes.
            lines.append("  <source src=\"\(url(file.name))\" type=\'\(type)\'>")
        }
        lines.append("</video>")
        return lines.joined(separator: "\n")
    }
}
