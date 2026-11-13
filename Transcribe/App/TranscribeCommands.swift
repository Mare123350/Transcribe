import SwiftUI

struct TranscribeCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage(SettingsKey.fontSize) private var fontSize = 16.0

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Session") { model.newSession() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(after: .saveItem) {
            Button("Export…") { model.isExporting = true }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(model.selectedSession == nil)
        }

        // ⌘H is reserved for Insert Header, so Hide moves to ⌃⌘H.
        CommandGroup(replacing: .appVisibility) {
            Button("Hide Transcribe") { NSApp.hide(nil) }
                .keyboardShortcut("h", modifiers: [.command, .control])
            Button("Hide Others") { NSApp.hideOtherApplications(nil) }
                .keyboardShortcut("h", modifiers: [.command, .option])
            Button("Show All") { NSApp.unhideAllApplications(nil) }
        }

        CommandMenu("Recording") {
            Button(recordTitle) { Task { await model.toggleRecording() } }
                .keyboardShortcut("r", modifiers: .command)
            Button("Continue Recording This Session") { Task { await model.continueRecording() } }
                .disabled(model.recorder.isActive || model.selectedSession == nil)
            Button("Stop") { Task { await model.stopRecording() } }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!model.recorder.isActive)
            Divider()
            Button("Insert Header") { model.insertHeaderAtEnd() }
                .keyboardShortcut("h", modifiers: .command)
                .disabled(model.selectedSession == nil)
            Button("Insert Verse…") { model.isInsertingVerse = true }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(model.selectedSession == nil)
        }

        CommandGroup(after: .toolbar) {
            Button("Bigger Text") { fontSize = min(fontSize + 2, 40) }
                .keyboardShortcut("+", modifiers: .command)
            Button("Smaller Text") { fontSize = max(fontSize - 2, 11) }
                .keyboardShortcut("-", modifiers: .command)
            Button("Actual Size") { fontSize = 16 }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
            Button("Song Library") { openWindow(id: WindowID.songLibrary) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Presentation Mode") { openWindow(id: WindowID.presentation) }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button(model.showInspector ? "Hide Inspector" : "Show Inspector") { model.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
        }
    }

    private var recordTitle: String {
        switch model.recorder.state {
        case .recording: "Pause"
        case .paused: "Resume"
        default: "Record"
        }
    }
}
