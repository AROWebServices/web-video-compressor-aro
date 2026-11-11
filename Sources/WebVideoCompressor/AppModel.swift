import AppKit
import AVFoundation
import CompressorCore
import Observation
import UniformTypeIdentifiers

enum ItemStatus: Equatable {
    case probing
    case ready
    case waiting
    case encoding(fraction: Double)
    case done(ExportResult)
    case failed(summary: String, fullLog: String)
    case cancelled
    case unreadable(String)
}

/// One video in the queue.
@MainActor
@Observable
final class QueueItem: Identifiable {
    let id = UUID()
    let url: URL
    var info: MediaInfo?
    var size: Int64 = 0
    var thumbnail: NSImage?
    var status: ItemStatus = .probing
    /// Settings for this video only; nil means "use the batch settings".
    var override: EncodeSettings?
    /// Start and end points to keep; empty means the whole video.
    var trim = TrimRange()
    var secondsRemaining: Double?

    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored var started: Date?
    @ObservationIgnored var reservedOutputs: [String] = []
    @ObservationIgnored var runningOnHardware = false

    init(url: URL) {
        self.url = url
    }

    var isEncoding: Bool {
        if case .encoding = status { return true }
        return false
    }

    var isBusy: Bool { isEncoding || status == .waiting }

    /// Can be (re)started: has a video track and is not already running or finished.
    var isStartable: Bool {
        guard info?.video != nil else { return false }
        switch status {
        case .ready, .cancelled, .failed: return true
        default: return false
        }
    }

    var result: ExportResult? {
        if case .done(let result) = status { return result }
        return nil
    }

    fileprivate func updateProgress(_ fraction: Double) {
        // Late updates can arrive after the job finished or was cancelled.
        guard case .encoding(let current) = status, fraction >= current else { return }
        status = .encoding(fraction: fraction)
        if let started, fraction > 0.03 {
            secondsRemaining = Date().timeIntervalSince(started) * (1 - fraction) / fraction
        }
    }
}

@MainActor
@Observable
final class AppModel {
    private static let ffmpegPathKey = "ffmpegPath"

    var tools: FFmpegTools?
    /// nil until the installed FFmpeg has been asked what it supports.
    var capabilities: FFmpegCapabilities?
    var items: [QueueItem] = []
    var selection: QueueItem.ID?
    /// Settings for every video without its own override.
    var batchSettings = EncodeSettings()
    /// nil means "next to each source file".
    var outputFolder: URL?
    var notice: String?

    @ObservationIgnored private var reservedOutputs: Set<String> = []

    init() {
        refreshTools()
        // Videos passed on the command line are queued at launch, e.g.
        // open "Web Video Compressor.app" --args clip.mov
        add(CommandLine.arguments.dropFirst()
            .filter { !$0.hasPrefix("-") }
            .map { URL(fileURLWithPath: $0) })
    }

    // MARK: Derived state

    var selectedItem: QueueItem? {
        items.first { $0.id == selection }
    }

    var isRunning: Bool { items.contains { $0.isBusy } }
    var canStart: Bool { tools != nil && items.contains { $0.isStartable } }

    var availableFormats: [OutputFormat] {
        guard let capabilities else { return OutputFormat.allCases }
        return OutputFormat.allCases.filter(capabilities.supports)
    }

    func hardwareAvailable(for format: OutputFormat) -> Bool {
        guard format.hardwareEncoder != nil else { return false }
        return capabilities?.supportsHardware(format) ?? true
    }

    func settings(for item: QueueItem) -> EncodeSettings {
        item.override ?? batchSettings
    }

    /// The settings the panel is editing: the selected video's own settings if
    /// it has any, otherwise the batch settings.
    var editedSettings: EncodeSettings {
        get { selectedItem?.override ?? batchSettings }
        set {
            if let item = selectedItem, item.override != nil {
                item.override = newValue
            } else {
                batchSettings = newValue
            }
        }
    }

    func outputSize(for item: QueueItem) -> PixelSize? {
        guard let video = item.info?.video else { return nil }
        return FFmpegCommandBuilder.outputSize(displayWidth: video.displayWidth,
                                               displayHeight: video.displayHeight,
                                               max: settings(for: item).maxResolution)
    }

    /// Total size before and after, over the videos that have finished.
    var savings: (original: Int64, compressed: Int64)? {
        let finished = items.filter { $0.result != nil }
        guard !finished.isEmpty else { return nil }
        return (finished.reduce(0) { $0 + $1.size },
                finished.reduce(0) { $0 + ($1.result?.largestSize ?? 0) })
    }

    // MARK: FFmpeg location

    func refreshTools() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("WebVideoCompressor/bin").path
        tools = FFmpegLocator.locate(
            override: UserDefaults.standard.string(forKey: Self.ffmpegPathKey),
            directories: [appSupport].compactMap { $0 } + FFmpegLocator.standardDirectories)
        capabilities = nil
        guard let tools else { return }
        Task {
            capabilities = try? await Compressor(tools: tools).capabilities()
            let formats = availableFormats
            if !formats.contains(batchSettings.format), let first = formats.first {
                batchSettings.format = first
            }
        }
        // Videos dropped before FFmpeg was found can be read now.
        for item in items where item.info == nil && !item.isBusy { probe(item) }
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
        notice = tools == nil
            ? "No working ffmpeg and ffprobe pair was found in \(url.deletingLastPathComponent().path)."
            : nil
    }

    // MARK: Queue contents

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .audiovisualContent]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    func add(_ urls: [URL]) {
        var isDirectory: ObjCBool = false
        for url in urls {
            let path = url.standardizedFileURL.path
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  !items.contains(where: { $0.url.standardizedFileURL.path == path }) else { continue }
            let item = QueueItem(url: url)
            item.size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
            items.append(item)
            probe(item)
        }
        if selection == nil, items.count == 1 { selection = items.first?.id }
    }

    private func probe(_ item: QueueItem) {
        guard let tools else {
            item.status = .unreadable("FFmpeg is needed to read this file.")
            return
        }
        item.status = .probing
        item.task = Task {
            do {
                let info = try await Compressor(tools: tools).probe(item.url)
                guard !Task.isCancelled else { return }
                item.info = info
                if let size = info.fileSize { item.size = size }
                item.status = info.video == nil ? .unreadable("This file has no video track.") : .ready
                item.thumbnail = await Self.makeThumbnail(for: item.url)
            } catch is CancellationError {
            } catch CompressorError.probeFailed(let summary) {
                item.status = .unreadable(summary.isEmpty ? "This file could not be read as a video." : summary)
            } catch {
                item.status = .unreadable(error.localizedDescription)
            }
        }
    }

    private static func makeThumbnail(for url: URL) async -> NSImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        guard let cgImage = try? await generator.image(at: .zero).image else { return nil }
        return NSImage(cgImage: cgImage, size: .zero)
    }

    func remove(_ item: QueueItem) {
        item.task?.cancel()
        items.removeAll { $0.id == item.id }
        if selection == item.id { selection = nil }
    }

    func removeSelected() {
        if let item = selectedItem { remove(item) }
    }

    func clearFinished() {
        for item in items where item.result != nil { remove(item) }
    }

    /// Empties the queue. Videos that are encoding or waiting stay, so a
    /// running batch is never thrown away by accident; cancel those first.
    func clearAll() {
        for item in items where !item.isBusy { remove(item) }
    }

    var hasFinished: Bool { items.contains { $0.result != nil } }
    var canClearAll: Bool { items.contains { !$0.isBusy } }

    func setOverride(_ enabled: Bool, for item: QueueItem) {
        item.override = enabled ? (item.override ?? batchSettings) : nil
    }

    // MARK: Running the queue

    func startAll() {
        for item in items where item.isStartable { item.status = .waiting }
        pump()
    }

    /// Runs one video again (or for the first time) with the current settings.
    func start(_ item: QueueItem) {
        guard item.info?.video != nil, !item.isBusy else { return }
        item.status = .waiting
        pump()
    }

    func cancel(_ item: QueueItem) {
        if item.isEncoding {
            item.task?.cancel()
        } else if item.status == .waiting {
            item.status = .ready
        }
    }

    func cancelAll() {
        for item in items { cancel(item) }
    }

    /// Starts waiting videos while there is room. Software encoders already use
    /// every core, so they run one at a time; hardware encodes can run two at once.
    private func pump() {
        while let next = items.first(where: { $0.status == .waiting }) {
            let running = items.filter(\.isEncoding)
            let nextOnHardware = settings(for: next).usesHardwareEncoder
            let hasRoom = running.isEmpty
                || (running.count < 2 && nextOnHardware && running.allSatisfy(\.runningOnHardware))
            guard hasRoom else { break }
            begin(next)
        }
    }

    private func begin(_ item: QueueItem) {
        guard let tools, let info = item.info else {
            item.status = .failed(summary: "FFmpeg was not found.", fullLog: "")
            return
        }
        var settings = settings(for: item)
        let capabilities = capabilities
            ?? FFmpegCapabilities(encoders: [], hdrConversion: .unavailable)
        if self.capabilities != nil {
            guard capabilities.supports(settings.format) else {
                item.status = .failed(
                    summary: "This FFmpeg build cannot produce \(settings.format.label).", fullLog: "")
                return
            }
            if settings.usesHardwareEncoder && !capabilities.supportsHardware(settings.format) {
                settings.useHardware = false
            }
        }

        // One free base name for every file of this export; names claimed by
        // jobs that are still running count as taken.
        let destinations = OutputNaming.destinations(
            for: item.url, settings: settings, in: outputFolder
        ) { [reservedOutputs] candidate in
            FileManager.default.fileExists(atPath: candidate.path) || reservedOutputs.contains(candidate.path)
        }
        let claimed = destinations.all.map(\.path)
        reservedOutputs.formUnion(claimed)
        item.reservedOutputs = claimed
        let trim = item.trim
        item.runningOnHardware = settings.usesHardwareEncoder
        item.status = .encoding(fraction: 0)
        item.secondsRemaining = nil
        item.started = Date()

        item.task = Task {
            do {
                let result = try await Compressor(tools: tools).export(
                    input: item.url, info: info, settings: settings, trim: trim,
                    capabilities: capabilities, destinations: destinations
                ) { fraction in
                    Task { @MainActor in item.updateProgress(fraction) }
                }
                item.status = .done(result)
            } catch is CancellationError {
                item.status = .cancelled
            } catch CompressorError.ffmpegFailed(_, let summary, let fullLog) {
                item.status = .failed(
                    summary: summary.isEmpty ? "FFmpeg stopped without an error message." : summary,
                    fullLog: fullLog)
            } catch CompressorError.noVideoStream {
                item.status = .failed(summary: "This file has no video track.", fullLog: "")
            } catch {
                item.status = .failed(summary: error.localizedDescription, fullLog: String(describing: error))
            }
            reservedOutputs.subtract(claimed)
            item.reservedOutputs = []
            pump()
        }
    }

    // MARK: Output folder and results

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        outputFolder = url
    }

    func reveal(_ item: QueueItem) {
        guard let urls = item.result?.allURLs, !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func revealAll() {
        let urls = items.flatMap { $0.result?.allURLs ?? [] }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    func copyHTML(for item: QueueItem) {
        if let html = item.result?.html { copyToClipboard(html) }
    }

    /// Length of the part of this video that will be kept, in seconds.
    func keptDuration(for item: QueueItem) -> Double {
        let duration = item.info?.duration ?? 0
        return item.trim.resolved(duration: duration)?.length ?? duration
    }

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
