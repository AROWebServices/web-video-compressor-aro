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
                .frame(minWidth: 820, idealWidth: 900, minHeight: 540, idealHeight: 600)
                .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Videos…") { model.chooseFiles() }
                    .keyboardShortcut("o")
            }
            CommandMenu("Queue") {
                Button("Compress All") { model.startAll() }
                    .keyboardShortcut(.return)
                    .disabled(!model.canStart)
                Button("Cancel All") { model.cancelAll() }
                    .keyboardShortcut(".")
                    .disabled(!model.isRunning)
                Divider()
                Button("Remove Selected Video") { model.removeSelected() }
                    .keyboardShortcut(.delete)
                    .disabled(model.selectedItem == nil)
                Button("Clear Finished") { model.clearFinished() }
                    .keyboardShortcut("k")
                    .disabled(!model.hasFinished)
                Button("Clear All") { model.clearAll() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                    .disabled(!model.canClearAll)
                Divider()
                Button("Reveal Results in Finder") { model.revealAll() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.savings == nil)
                Divider()
                Button("Locate FFmpeg…") { model.chooseFFmpeg() }
            }
        }
    }
}
