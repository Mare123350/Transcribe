import AudioCapture
import SwiftUI

struct RecordingToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .principal) {
            RecordButton()
            Button { Task { await model.stopRecording() } } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .disabled(!model.recorder.isActive)
            .help("Stop (⌘.)")

            LevelMeter(level: model.recorder.level, active: model.recorder.state == .recording)
                .frame(width: 70, height: 8)
                .help("Input level")

            InputPicker()
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if !model.recorder.statusMessage.isEmpty {
                Text(model.recorder.statusMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button { model.isExporting = true } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(model.selectedSession == nil)
            .help("Export as Markdown, PDF, Word, or text (⌘E)")
            Button { openWindow(id: WindowID.presentation) } label: {
                Label("Presentation", systemImage: "rectangle.on.rectangle")
            }
            .help("Open presentation mode (⇧⌘P)")
            Button { model.showInspector.toggle() } label: {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .help("Show or hide the inspector (⌥⌘I)")
        }
    }
}

private struct RecordButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let state = model.recorder.state
        Button { Task { await model.toggleRecording() } } label: {
            switch state {
            case .recording: Label("Pause", systemImage: "pause.fill")
            case .paused: Label("Resume", systemImage: "record.circle")
            case .starting: Label("Starting…", systemImage: "hourglass")
            case .stopping: Label("Stopping…", systemImage: "hourglass")
            case .idle: Label("Record", systemImage: "record.circle")
            }
        }
        .labelStyle(.titleAndIcon)
        .tint(state == .idle || state == .paused ? .red : nil)
        .disabled(state == .starting || state == .stopping)
        .help("Record / Pause (⌘R)")
    }
}

struct LevelMeter: View {
    let level: Float
    let active: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(level > 0.85 ? Color.red : Color.green)
                    .frame(width: proxy.size.width * CGFloat(active ? level : 0))
                    .animation(.linear(duration: 0.08), value: level)
            }
        }
    }
}

private struct InputPicker: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.inputDeviceUID) private var inputUID = ""
    @State private var devices: [AudioInputDevice] = []

    var body: some View {
        Menu {
            Picker("Audio Input", selection: $inputUID) {
                Text("System Default").tag("")
                ForEach(devices) { device in
                    Text(device.channelCount > 2 ? "\(device.name) (\(device.channelCount) ch)" : device.name).tag(device.uid)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(currentName, systemImage: "mic")
        }
        .disabled(model.recorder.isActive)
        .help(model.recorder.isActive ? "Stop recording to change the input" : "Choose the audio input")
        .onAppear { devices = AudioDeviceCatalog.inputDevices() }
        .onHover { if $0 { devices = AudioDeviceCatalog.inputDevices() } }
    }

    private var currentName: String {
        devices.first { $0.uid == inputUID }?.name ?? "System Default"
    }
}
