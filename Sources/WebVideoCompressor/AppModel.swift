import AppKit
import AVFoundation
import CompressorCore
import Observation
import UniformTypeIdentifiers

struct LoadedFile: Equatable {
    let url: URL
    let info: MediaInfo
    let size: Int64
}

enum JobStatus: Equatable {
    case idle
    case encoding(fraction: Double)
    case done(CompressionResult)
    case failed(summary: String, fullLog: String)
    case cancelled
}

@MainActor
@Observable
final class AppModel {
    private static let ffmpegPathKey = "ffmpegPath"

    var tools: FFmpegTools?
    var file: LoadedFile?
    var thumbnail: NSImage?
    var isLoading = false
    var loadError: String?
    var settings = EncodeSettings()
    var status: JobStatus = .idle
    var secondsRemaining: Double?

    private var loadTask: Task<Void, Never>?
    private var encodeTask: Task<Void, Never>?
    private var encodeStarted: Date?

    init() {
        refreshTools()
    }

    // MARK: Derived state

    var isEncoding: Bool {
        if case .encoding = status { return true }
        return false
    }

    var canCompress: Bool {
        tools != nil && file?.info.video != nil && !isEncoding && !isLoading
    }

    var resultURL: URL? {
        if case .done(let result) = status { return result.outputURL }
        return nil
    }

    /// Size the video will be encoded at with the current settings.
    var outputSize: PixelSize? {
        guard let video = file?.info.video else { return nil }
        return FFmpegCommandBuilder.outputSize(displayWidth: video.displayWidth,
                                               displayHeight: video.displayHeight,
                                               max: settings.maxResolution)
    }

    // MARK: FFmpeg location

    func refreshTools() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("WebVideoCompressor/bin").path
        tools = FFmpegLocator.locate(
            override: UserDefaults.standard.string(forKey: Self.ffmpegPathKey),
            directories: [appSupport].compactMap { $0 } + FFmpegLocator.standardDirectories)
    }

    func chooseFFmpeg() {
        let panel = NSOpenPanel()
        panel.title = "Locate FFmpeg"
        panel.message = "Choose the ffmpeg program. ffprobe must be in the same folder."
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: Self.ffmpegPathKey)
        refreshTools()
        if tools == nil {
            loadError = "No working ffmpeg and ffprobe pair was found in \(url.deletingLastPathComponent().path)."
        } else if let current = file?.url ?? pendingURL {
            loadError = nil
            load(current)
        }
    }

    // MARK: Loading a file

    /// A file dropped before FFmpeg was located; loaded once it is.
    private var pendingURL: URL?

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .audiovisualContent]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }

    func load(_ url: URL) {
        guard !isEncoding else { return }
        loadTask?.cancel()
        file = nil
        thumbnail = nil
        status = .idle
        loadError = nil
        guard let tools else {
            pendingURL = url
            loadError = "FFmpeg is needed to read this file. Locate it first."
            return
        }
        pendingURL = nil
        isLoading = true
        loadTask = Task {
            defer { isLoading = false }
            do {
                let info = try await Compressor(tools: tools).probe(url)
                guard !Task.isCancelled else { return }
                let size = info.fileSize
                    ?? ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value
                    ?? 0
                file = LoadedFile(url: url, info: info, size: size)
                if info.video == nil {
                    loadError = "This file has no video track."
                }
                thumbnail = await Self.makeThumbnail(for: url)
            } catch is CancellationError {
            } catch CompressorError.probeFailed(let summary) {
                loadError = summary.isEmpty ? "This file could not be read as a video." : summary
            } catch {
                loadError = error.localizedDescription
            }
        }
    }

    private static func makeThumbnail(for url: URL) async -> NSImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        guard let cgImage = try? await generator.image(at: .zero).image else { return nil }
        return NSImage(cgImage: cgImage, size: .zero)
    }

    // MARK: Encoding

    func compress() {
        guard canCompress, let tools, let file else { return }
        let output = OutputNaming.uniqueURL(for: file.url, fileExtension: "mp4")
        let settings = settings
        status = .encoding(fraction: 0)
        secondsRemaining = nil
        encodeStarted = Date()
        encodeTask = Task {
            do {
                let result = try await Compressor(tools: tools).compress(
                    input: file.url, output: output, info: file.info, settings: settings
                ) { fraction in
                    Task { @MainActor in self.updateProgress(fraction) }
                }
                status = .done(result)
            } catch is CancellationError {
                status = .cancelled
            } catch CompressorError.ffmpegFailed(_, let summary, let fullLog) {
                status = .failed(summary: summary.isEmpty ? "FFmpeg stopped without an error message." : summary,
                                 fullLog: fullLog)
            } catch CompressorError.noVideoStream {
                status = .failed(summary: "This file has no video track.", fullLog: "")
            } catch {
                status = .failed(summary: error.localizedDescription, fullLog: String(describing: error))
            }
        }
    }

    private func updateProgress(_ fraction: Double) {
        // Late updates can arrive after the job finished or was cancelled.
        guard case .encoding(let current) = status, fraction >= current else { return }
        status = .encoding(fraction: fraction)
        if let encodeStarted, fraction > 0.03 {
            let elapsed = Date().timeIntervalSince(encodeStarted)
            secondsRemaining = elapsed * (1 - fraction) / fraction
        }
    }

    func cancel() {
        encodeTask?.cancel()
    }

    func revealResult() {
        guard let resultURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([resultURL])
    }

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
