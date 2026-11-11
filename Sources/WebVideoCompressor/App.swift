import AppKit
import SwiftUI

@main
struct WebVideoCompressorApp: App {
    @State private var model = AppModel()

    init() {
        // Lets the app show a normal window and Dock icon even when it is run
        // as a bare executable (`swift run`) rather than from the .app bundle.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Window("Web Video Compressor", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 520, idealWidth: 560, minHeight: 500)
                .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Video…") { model.chooseFile() }
                    .keyboardShortcut("o")
                    .disabled(model.isEncoding)
            }
            CommandMenu("Video") {
                Button("Compress") { model.compress() }
                    .keyboardShortcut(.return)
                    .disabled(!model.canCompress)
                Button("Cancel") { model.cancel() }
                    .keyboardShortcut(".")
                    .disabled(!model.isEncoding)
                Divider()
                Button("Reveal Result in Finder") { model.revealResult() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.resultURL == nil)
                Divider()
                Button("Locate FFmpeg…") { model.chooseFFmpeg() }
            }
        }
    }
}
