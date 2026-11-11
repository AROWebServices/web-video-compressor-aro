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
            Group {
                if let file = model.file {
                    FileCard(file: file)
                } else {
                    DropZone(isTargeted: isDropTargeted)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            SettingsSection()
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .disabled(model.isEncoding)
            Divider()
            StatusBar()
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, !model.isEncoding else { return false }
            model.load(url)
            return true
        } isTargeted: { isDropTargeted = $0 }
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
                Text("Install it with Homebrew (brew install ffmpeg) or point the app at an ffmpeg binary.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Check Again") { model.refreshTools() }
            Button("Locate…") { model.chooseFFmpeg() }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.yellow.opacity(0.12))
    }
}

// MARK: - Empty state

private struct DropZone: View {
    @Environment(AppModel.self) private var model
    let isTargeted: Bool

    var body: some View {
        VStack(spacing: 12) {
            if model.isLoading {
                ProgressView()
                Text("Reading video…").foregroundStyle(.secondary)
            } else {
                Image(systemName: "film.stack")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
                Text("Drop a video here").font(.title3.weight(.medium))
                Button("Choose a Video…") { model.chooseFile() }
                if let error = model.loadError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .padding(.top, 4)
                }
            }
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

// MARK: - Loaded file

private struct FileCard: View {
    @Environment(AppModel.self) private var model
    let file: LoadedFile

    var body: some View {
        VStack(spacing: 14) {
            Group {
                if let thumbnail = model.thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "film")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.quaternary)
                }
            }
            .frame(maxHeight: 190)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(spacing: 4) {
                Text(file.url.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(details)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let error = model.loadError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            }
            Button("Choose Another…") { model.chooseFile() }
                .buttonStyle(.link)
                .disabled(model.isEncoding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var details: String {
        var parts = [Format.bytes(file.size)]
        if let video = file.info.video {
            parts.append("\(video.displayWidth) × \(video.displayHeight)")
        }
        if file.info.duration > 0 { parts.append(Format.duration(file.info.duration)) }
        if let codec = file.info.video?.codec { parts.append(codec.uppercased()) }
        if file.info.audio == nil { parts.append("no audio") }
        return parts.joined(separator: "  ·  ")
    }
}

// MARK: - Settings

private struct SettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 12) {
            GridRow {
                Text("Format").gridColumnAlignment(.trailing)
                Text("MP4 (H.264 + AAC)").foregroundStyle(.secondary)
            }
            GridRow {
                Text("Quality")
                HStack(spacing: 10) {
                    Text("Small").font(.caption).foregroundStyle(.secondary)
                    Slider(value: quality, in: 0...100, step: 5)
                    Text("High").font(.caption).foregroundStyle(.secondary)
                    Text(model.settings.qualityLabel)
                        .monospacedDigit()
                        .frame(width: 70, alignment: .trailing)
                }
            }
            GridRow {
                Text("Max size")
                HStack {
                    Picker("Max size", selection: $model.settings.maxResolution) {
                        ForEach(MaxResolution.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                    if let size = model.outputSize {
                        Text("Output \(size.width) × \(size.height)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var quality: Binding<Double> {
        Binding(get: { Double(model.settings.quality) },
                set: { model.settings.quality = Int($0) })
    }
}

// MARK: - Status and actions

private struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.status {
        case .idle:
            HStack {
                Text(model.file == nil ? "No video selected" : "Ready")
                    .foregroundStyle(.secondary)
                Spacer()
                compressButton
            }
        case .cancelled:
            HStack {
                Text("Cancelled. Nothing was saved.").foregroundStyle(.secondary)
                Spacer()
                compressButton
            }
        case .encoding(let fraction):
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: fraction)
                    Text(progressText(fraction))
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Button("Cancel", role: .cancel) { model.cancel() }
                    .keyboardShortcut(.cancelAction)
            }
        case .done(let result):
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(resultHeadline(result)).font(.headline)
                    Text(result.outputURL.lastPathComponent)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Reveal in Finder") { model.revealResult() }
                compressButton
            }
        case .failed(let summary, let fullLog):
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Compression failed").font(.headline)
                    Text(summary)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(5)
                        .textSelection(.enabled)
                }
                Spacer()
                if !fullLog.isEmpty {
                    Button("Copy Full Log") { model.copyToClipboard(fullLog) }
                }
                compressButton
            }
        }
    }

    private var compressButton: some View {
        Button("Compress") { model.compress() }
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canCompress)
    }

    private func progressText(_ fraction: Double) -> String {
        var text = "\(Int((fraction * 100).rounded()))%"
        if let remaining = model.secondsRemaining, remaining.isFinite {
            text += "  ·  about \(Format.duration(max(1, remaining))) left"
        }
        return text
    }

    private func resultHeadline(_ result: CompressionResult) -> String {
        let size = Format.bytes(result.outputSize)
        guard let original = model.file?.size, original > 0 else { return size }
        let change = Double(original - result.outputSize) / Double(original) * 100
        if change >= 0 {
            return "\(size)  ·  \(Int(change.rounded()))% smaller"
        }
        return "\(size)  ·  \(Int((-change).rounded()))% larger than the original"
    }
}

// MARK: - Formatting

enum Format {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
