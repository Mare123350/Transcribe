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

            RecordingClock()

            LevelMeter(recorder: model.recorder)
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

/// The input level, drawn by a layer that reads the recorder 15 times a second. It deliberately
/// bypasses SwiftUI: a level that changes constantly would otherwise re-lay-out the toolbar.
struct LevelMeter: NSViewRepresentable {
    let recorder: RecordingController

    func makeNSView(context: Context) -> LevelMeterView {
        LevelMeterView { [weak recorder] in
            guard let recorder else { return (0, false) }
            return (recorder.level, recorder.state == .recording)
        }
    }

    func updateNSView(_ view: LevelMeterView, context: Context) {}
}

final class LevelMeterView: NSView {
    private let read: @MainActor () -> (level: Float, active: Bool)
    private let track = CALayer()
    private let fill = CALayer()
    private var timer: Timer?

    init(read: @escaping @MainActor () -> (level: Float, active: Bool)) {
        self.read = read
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(track)
        layer?.addSublayer(fill)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        guard window != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    override func layout() {
        super.layout()
        refresh()
    }

    override func updateLayer() {
        track.backgroundColor = NSColor.quaternaryLabelColor.cgColor
    }

    override var wantsUpdateLayer: Bool { true }

    private func refresh() {
        let (level, active) = read()
        let value = CGFloat(active ? max(0, min(1, level)) : 0)
        CATransaction.begin()
        CATransaction.setAnimationDuration(1.0 / 15)
        track.frame = bounds
        track.cornerRadius = bounds.height / 2
        track.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        fill.frame = CGRect(x: 0, y: 0, width: bounds.width * value, height: bounds.height)
        fill.cornerRadius = bounds.height / 2
        fill.backgroundColor = (value > 0.85 ? NSColor.systemRed : NSColor.systemGreen).cgColor
        CATransaction.commit()
    }

    deinit { MainActor.assumeIsolated { timer?.invalidate() } }
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

/// A clear recording state: a red dot and the running time while recording, "Paused" when paused.
private struct RecordingClock: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let recorder = model.recorder
        if recorder.state == .recording || recorder.state == .paused {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 5) {
                    Image(systemName: recorder.state == .paused ? "pause.circle.fill" : "circle.fill")
                        .foregroundStyle(.red)
                        .imageScale(.small)
                        .symbolEffect(.pulse, isActive: recorder.state == .recording)
                    Text(recorder.state == .paused ? "Paused" : "REC")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.red)
                    Text(TimeFormat.clock(recorder.elapsed(at: context.date)))
                        .font(.callout.monospacedDigit())
                }
                .frame(width: 118, alignment: .leading)
            }
            .help(recorder.state == .paused ? "Recording is paused" : "Recording")
        }
    }
}
