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

        CommandMenu("Screen") {
            Button("Find Verse…") {
                model.showInspector = true
                model.verseEntryFocusRequest += 1
            }
            .keyboardShortcut("k", modifiers: .command)
            Divider()
            Button("Send Preview to Screen") { model.output.take() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.output.preview == nil)
            Button("Clear Screen") { model.output.clearScreen() }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
                .disabled(model.output.live == nil)
            Divider()
            Button("Next Slide") { Task { await model.output.step(slide: 1, onLive: true) } }
                .keyboardShortcut("]", modifiers: .command)
            Button("Previous Slide") { Task { await model.output.step(slide: -1, onLive: true) } }
                .keyboardShortcut("[", modifiers: .command)
            Button("Next Verse in Preview") { Task { await model.output.step(verse: 1, onLive: false) } }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Previous Verse in Preview") { Task { await model.output.step(verse: -1, onLive: false) } }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("Skip Preview") { model.output.skipPreview() }
                .disabled(model.output.preview == nil)
            Divider()
            Picker("Auto-Detect", selection: Binding(get: { model.output.mode }, set: { model.output.mode = $0 })) {
                ForEach(OutputController.Mode.allCases) { Text($0.title).tag($0) }
            }
            Button("Open Output Window") { openWindow(id: WindowID.output) }
                .keyboardShortcut("o", modifiers: [.command, .option])
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
