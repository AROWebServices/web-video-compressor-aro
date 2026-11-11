import CompressorCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if model.tools == nil {
                MissingFFmpegBanner()
            }
            HStack(spacing: 0) {
                Group {
                    if model.items.isEmpty {
                        DropZone(isTargeted: isDropTargeted).padding(20)
                    } else {
                        QueueList()
                            .overlay {
                                if isDropTargeted {
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(Color.accentColor, lineWidth: 2)
                                        .padding(4)
                                }
                            }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .dropDestination(for: URL.self) { urls, _ in
                    model.add(urls)
                    return !urls.isEmpty
                } isTargeted: { isDropTargeted = $0 }

                Divider()
                SettingsPanel()
                    .frame(width: 310)
            }
            Divider()
            BottomBar()
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
    }
}

// MARK: - FFmpeg missing

private struct MissingFFmpegBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("FFmpeg was not found").font(.headline)
                Text(model.notice
                     ?? "Install it with Homebrew (brew install ffmpeg) or point the app at an ffmpeg binary.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Check Again") { model.refreshTools() }
            Button("Locate…") { model.chooseFFmpeg() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.yellow.opacity(0.12))
    }
}

// MARK: - Empty state

private struct DropZone: View {
    @Environment(AppModel.self) private var model
    let isTargeted: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "film.stack")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
            Text("Drop videos here").font(.title3.weight(.medium))
            Button("Add Videos…") { model.chooseFiles() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .background(RoundedRectangle(cornerRadius: 12)
                    .fill(isTargeted ? Color.accentColor.opacity(0.08) : .clear))
        }
    }
}

// MARK: - Queue

private struct QueueList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            ForEach(model.items) { item in
                QueueRow(item: item)
                    .tag(item.id)
                    .contextMenu {
                        if item.result != nil {
                            Button("Copy HTML") { model.copyHTML(for: item) }
                            Button("Reveal in Finder") { model.reveal(item) }
                        }
                        if item.isBusy {
                            Button("Cancel") { model.cancel(item) }
                        } else if item.info?.video != nil {
                            Button(item.result == nil ? "Compress" : "Compress Again") { model.start(item) }
                                .disabled(model.tools == nil)
                        }
                        Divider()
                        Button("Remove from Queue") { model.remove(item) }
                    }
            }
        }
        .listStyle(.inset)
    }
}

private struct QueueRow: View {
    @Environment(AppModel.self) private var model
    let item: QueueItem

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 3) {
                Text(item.url.lastPathComponent)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(details)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                statusLine
            }
            Spacer(minLength: 8)
            actions
        }
        .padding(.vertical, 5)
    }

    private var thumbnail: some View {
        Group {
            if let image = item.thumbnail {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "film").foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 76, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private var details: String {
        var parts = [Format.bytes(item.size)]
        if let info = item.info {
            if let video = info.video {
                parts.append("\(video.displayWidth) × \(video.displayHeight)")
            }
            if info.duration > 0 { parts.append(Format.duration(info.duration)) }
            if let video = info.video {
                parts.append(video.codec.uppercased())
                if video.isHDR { parts.append("HDR") }
            }
            if info.audio == nil { parts.append("no audio") }
        }
        return parts.joined(separator: "  ·  ")
    }

    @ViewBuilder private var statusLine: some View {
        switch item.status {
        case .probing:
            Text("Reading…").font(.callout).foregroundStyle(.secondary)
        case .ready:
            Text(plan).font(.callout).foregroundStyle(.secondary).lineLimit(1)
        case .waiting:
            Text("Waiting").font(.callout).foregroundStyle(.secondary)
        case .cancelled:
            Text("Cancelled. Nothing was saved.").font(.callout).foregroundStyle(.secondary)
        case .encoding(let fraction):
            VStack(alignment: .leading, spacing: 2) {
                ProgressView(value: fraction)
                Text(progressText(fraction))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        case .done(let result):
            let larger = result.largestSize > item.size && item.size > 0
            Label(resultText(result), systemImage: larger ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(larger ? .orange : .green)
                .lineLimit(1)
                .help(result.allURLs.map(\.lastPathComponent).joined(separator: "\n"))
        case .failed(let summary, _):
            Text(summary)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.red)
                .lineLimit(3)
                .textSelection(.enabled)
        case .unreadable(let message):
            Text(message).font(.callout).foregroundStyle(.red).lineLimit(2)
        }
    }

    /// What will happen to this video with the current settings.
    private var plan: String {
        let settings = model.settings(for: item).adjusted(forSourceBytes: item.size)
        var parts = [settings.format.label]
        if let size = model.outputSize(for: item) { parts.append("\(size.width) × \(size.height)") }
        if let target = settings.effectiveTargetSizeMB {
            parts.append("about \(Format.megabytes(target))" + (settings.format == .webBundle ? " each" : ""))
        }
        if let duration = item.info?.duration, item.trim.resolved(duration: duration) != nil {
            parts.append("trimmed to \(Format.duration(model.keptDuration(for: item)))")
        }
        if item.override != nil { parts.append("own settings") }
        if item.info?.video?.isHDR == true {
            parts.append(model.capabilities?.hdrConversion == .unavailable
                         ? "HDR cannot be converted; colours may look washed out"
                         : "HDR will be converted to SDR")
        }
        return "→ " + parts.joined(separator: "  ·  ")
    }

    private func progressText(_ fraction: Double) -> String {
        var text = "\(Int((fraction * 100).rounded()))%"
        if let remaining = item.secondsRemaining, remaining.isFinite {
            text += "  ·  about \(Format.duration(max(1, remaining))) left"
        }
        return text
    }

    private func verdict(_ size: Int64) -> String? {
        guard item.size > 0 else { return nil }
        let change = Double(item.size - size) / Double(item.size) * 100
        return change >= 0
            ? "\(Int(change.rounded()))% smaller"
            : "\(Int((-change).rounded()))% larger than the original"
    }

    private func resultText(_ result: ExportResult) -> String {
        if result.videos.count == 1, let file = result.videos.first {
            var parts = [Format.bytes(file.size)]
            if let verdict = verdict(file.size) { parts.append(verdict) }
            parts.append(file.url.lastPathComponent)
            if result.poster != nil { parts.append("poster") }
            return parts.joined(separator: "  ·  ")
        }
        // A bundle: one entry per file, e.g. "WEBM 4.1 MB (91% smaller)".
        var parts = result.videos.map { file in
            let kind = file.url.pathExtension.uppercased()
            let note = verdict(file.size).map { " (\($0))" } ?? ""
            return "\(kind) \(Format.bytes(file.size))\(note)"
        }
        if result.poster != nil { parts.append("poster") }
        return parts.joined(separator: "  ·  ")
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 6) {
            if case .failed(_, let fullLog) = item.status, !fullLog.isEmpty {
                iconButton("doc.on.doc", "Copy the full FFmpeg log") { model.copyToClipboard(fullLog) }
            }
            if item.result != nil {
                iconButton("chevron.left.forwardslash.chevron.right", "Copy HTML for this video") {
                    model.copyHTML(for: item)
                }
                iconButton("magnifyingglass", "Reveal in Finder") { model.reveal(item) }
            }
            if item.isBusy {
                iconButton("xmark.circle", "Cancel") { model.cancel(item) }
            } else {
                iconButton("trash", "Remove from queue") { model.remove(item) }
            }
        }
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .help(help)
            .accessibilityLabel(help)
    }
}

// MARK: - Settings

private struct SettingsPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let settings = model.editedSettings
        Form {
            Section {
                if let item = model.selectedItem {
                    Toggle("Own settings for this video", isOn: Binding(
                        get: { item.override != nil },
                        set: { model.setOverride($0, for: item) }))
                    Text(item.override != nil
                         ? "Editing \(item.url.lastPathComponent) only."
                         : "Editing the settings for all videos.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Text("These settings apply to all videos. Select one to give it its own.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Picker("Preset", selection: Binding(
                    get: { settings.preset },
                    set: { model.editedSettings.apply($0) })) {
                    ForEach(Preset.allCases) { Text($0.label).tag($0) }
                }
                Picker("Format", selection: $model.editedSettings.format) {
                    ForEach(model.availableFormats) { Text($0.label).tag($0) }
                }
                Text(settings.format.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.hardwareAvailable(for: settings.format) {
                    Toggle("Fast (hardware) encoding", isOn: $model.editedSettings.useHardware)
                    if settings.useHardware {
                        Text("Much faster, but files are larger at the same quality.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                if settings.format.supportsTargetSize {
                    Picker("Aim for", selection: $model.editedSettings.useTargetSize) {
                        Text("Quality").tag(false)
                        Text("File size").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                if settings.effectiveTargetSizeMB != nil || (settings.useTargetSize && settings.format.supportsTargetSize) {
                    LabeledContent("Target size") {
                        HStack(spacing: 4) {
                            TextField("Target size", value: $model.editedSettings.targetSizeMB,
                                      format: .number.precision(.fractionLength(0...1)))
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .frame(width: 64)
                            Text("MB").foregroundStyle(.secondary)
                        }
                    }
                    Text(settings.format == .webBundle
                         ? "Applies to each file in the bundle. Takes about twice as long."
                         : "Takes about twice as long. Very small targets will look poor.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if settings.format.hasQualitySetting {
                    LabeledContent("Quality") {
                        Text(settings.qualityLabel).foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(
                        get: { Double(settings.quality) },
                        set: { model.editedSettings.quality = Int($0) }), in: 0...100, step: 5) {
                        Text("Quality")
                    } minimumValueLabel: {
                        Text("Small").font(.caption)
                    } maximumValueLabel: {
                        Text("High").font(.caption)
                    }
                    .labelsHidden()
                }
                Picker("Max size", selection: $model.editedSettings.maxResolution) {
                    ForEach(MaxResolution.allCases) { Text($0.label).tag($0) }
                }
                if settings.format == .gif {
                    LabeledContent("Frame rate") { Text("15 fps").foregroundStyle(.secondary) }
                } else {
                    Picker("Frame rate", selection: $model.editedSettings.frameRateCap) {
                        ForEach(FrameRateCap.allCases) { Text($0.label).tag($0) }
                    }
                }
                if settings.format.hasAudio {
                    Picker("Audio", selection: $model.editedSettings.audio) {
                        ForEach(AudioMode.allCases) { Text($0.label).tag($0) }
                    }
                } else {
                    LabeledContent("Audio") { Text("None").foregroundStyle(.secondary) }
                }
                Toggle("Strip metadata", isOn: $model.editedSettings.stripMetadata)
                if settings.format == .webBundle {
                    LabeledContent("Poster image") { Text("Included").foregroundStyle(.secondary) }
                } else if settings.format != .gif {
                    Toggle("Poster image", isOn: $model.editedSettings.exportPoster)
                }
            }

            if let item = model.selectedItem, let duration = item.info?.duration, duration > 0 {
                TrimSection(item: item, duration: duration)
            }
        }
        .formStyle(.grouped)
    }
}

/// Start and end points for the selected video, in seconds.
private struct TrimSection: View {
    @Environment(AppModel.self) private var model
    @Bindable var item: QueueItem
    let duration: Double

    var body: some View {
        Section("Trim \(item.url.lastPathComponent)") {
            field("Start", value: $item.trim.start, placeholder: "0")
            field("End", value: $item.trim.end, placeholder: String(format: "%.1f", duration))
            HStack {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(isValid ? Color.secondary : Color.red)
                Spacer()
                if item.trim != TrimRange() {
                    Button("Clear") { item.trim = TrimRange() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
        .disabled(item.isBusy)
    }

    private func field(_ label: String, value: Binding<Double?>, placeholder: String) -> some View {
        LabeledContent(label) {
            HStack(spacing: 4) {
                TextField(label, value: value, format: .number.precision(.fractionLength(0...2)),
                          prompt: Text(placeholder))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                Text("sec").foregroundStyle(.secondary)
            }
        }
    }

    private var hasValues: Bool { item.trim.start != nil || item.trim.end != nil }
    private var isValid: Bool { !hasValues || item.trim.resolved(duration: duration) != nil
        || ((item.trim.start ?? 0) <= 0 && (item.trim.end ?? duration) >= duration) }

    private var summary: String {
        guard hasValues else { return "The whole video (\(Format.duration(duration))) is kept." }
        guard let kept = item.trim.resolved(duration: duration) else {
            return isValid ? "The whole video is kept." : "End must come after start, within the video."
        }
        return String(format: "Keeps %.1f sec, from %.1f to %.1f.", kept.length, kept.start, kept.start + kept.length)
    }
}

// MARK: - Bottom bar

private struct BottomBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Menu {
                Button("Same Folder as Each Video") { model.outputFolder = nil }
                Button("Choose Folder…") { model.chooseOutputFolder() }
            } label: {
                Label(model.outputFolder?.lastPathComponent ?? "Same folder as source",
                      systemImage: "folder")
            }
            .fixedSize()
            .help(model.outputFolder?.path ?? "Each result is saved next to its source with “-web” added to the name.")

            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()

            Button("Add…") { model.chooseFiles() }
            if model.isRunning {
                Button("Cancel All", role: .cancel) { model.cancelAll() }
            }
            Button("Compress All") { model.startAll() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canStart)
        }
    }

    private var summary: String {
        let count = model.items.count
        guard count > 0 else { return "" }
        var text = count == 1 ? "1 video" : "\(count) videos"
        if let savings = model.savings {
            text += "  ·  \(Format.bytes(savings.original)) → \(Format.bytes(savings.compressed))"
        }
        return text
    }
}

// MARK: - Formatting

enum Format {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func megabytes(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value)) MB" : String(format: "%.1f MB", value)
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
