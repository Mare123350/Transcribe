import AudioCapture
import SwiftUI

struct RecordingToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some ToolbarContent {
        let density = Design.ToolbarDensity(detailWidth: model.detailWidth)
        let compact = density != .full

        // Record, stop, status and level: one pill with room inside for everything. Centred when
        // there's room; at narrow widths it starts at the left so the other buttons still fit.
        if density == .narrow {
            ToolbarItem(placement: .navigation) { RecordingControls(narrow: true) }
            ToolbarItem(placement: .navigation) { InputPicker(density: density) }
        } else {
            ToolbarItem(placement: .principal) { RecordingControls(narrow: false) }
            ToolbarItem(placement: .principal) { InputPicker(density: density) }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if density == .narrow {
                // At the smallest sizes the three actions share one menu instead of overflowing.
                Menu {
                    Button("Export…") { model.isExporting = true }.disabled(model.selectedSession == nil)
                    Button("Song Library") { openWindow(id: WindowID.songLibrary) }
                    Button("Output Screen") { openWindow(id: WindowID.output) }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .help("Export (⌘E), Song Library (⇧⌘L), Output Screen (⌥⌘O)")
            } else {
                if !model.recorder.statusMessage.isEmpty && !compact {
                    Text(model.recorder.statusMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Button { model.isExporting = true } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                        .labelStyle(compact ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
                }
                .disabled(model.selectedSession == nil)
                .help("Export the service as Markdown, PDF, Word or text (⌘E)")
                Button { openWindow(id: WindowID.songLibrary) } label: {
                    Label("Songs", systemImage: "music.note.list")
                        .labelStyle(compact ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
                }
                .help("Song library: add, import and edit songs (⇧⌘L)")
                Button { openWindow(id: WindowID.output) } label: {
                    Label("Screen", systemImage: "rectangle.on.rectangle")
                        .labelStyle(compact ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
                }
                .help("Open the output screen for the projector or second display (⌥⌘O)")
            }
        }
    }
}

/// Record / pause, stop, what's happening, and the input level, laid out at a fixed width so the
/// pill never changes size or clips when recording starts.
private struct RecordingControls: View {
    let narrow: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        let recorder = model.recorder
        HStack(spacing: Design.Space.s) {
            RecordButton()
            Button { Task { await model.stopRecording() } } label: {
                Image(systemName: "stop.fill")
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!recorder.isActive)
            .opacity(recorder.isActive ? 1 : 0.35)
            .help("Stop recording and save (⌘.)")
            .accessibilityLabel("Stop recording")

            if !narrow { Divider().frame(height: 18) }

            RecordingStatus(width: narrow ? 62 : 112)

            LevelMeter(recorder: recorder)
                .frame(width: narrow ? 40 : 76, height: 16)
                .help("Microphone level: green is good, amber is loud, red is clipping")
                .accessibilityElement()
                .accessibilityLabel("Input level")
                .accessibilityValue(recorder.state == .recording ? "\(Int(recorder.level * 100)) percent" : "Not recording")
        }
        .padding(.horizontal, Design.Space.s)
        .fixedSize()
    }
}

private struct RecordButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let state = model.recorder.state
        Button { Task { await model.toggleRecording() } } label: {
            Group {
                switch state {
                case .recording: Label("Pause", systemImage: "pause.fill")
                case .paused: Label("Resume", systemImage: "record.circle.fill")
                case .starting: Label("Starting", systemImage: "hourglass")
                case .stopping: Label("Saving", systemImage: "hourglass")
                case .idle: Label("Record", systemImage: "record.circle.fill")
                }
            }
            .labelStyle(.titleAndIcon)
            .frame(width: 78)
        }
        // A red capsule of its own: a prominent style would tint the whole toolbar pill.
        .buttonStyle(RecordPillStyle(tint: state == .recording || state == .stopping ? nil : Design.Palette.recording))
        .disabled(state == .starting || state == .stopping)
        .help(state == .recording ? "Pause recording (⌘R)" : state == .paused ? "Resume recording (⌘R)" : "Start recording (⌘R)")
    }
}

/// "Ready", a pulsing red dot with the running time, or "Paused" with the time.
private struct RecordingStatus: View {
    let width: CGFloat
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let recorder = model.recorder
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: Design.Space.xs) {
                switch recorder.state {
                case .recording:
                    Circle()
                        .fill(Design.Palette.recording)
                        .frame(width: 9, height: 9)
                        .phaseAnimator(reduceMotion ? [1.0] : [1.0, 0.35]) { dot, phase in dot.opacity(phase) } animation: { _ in .easeInOut(duration: 0.8) }
                    Text(TimeFormat.clock(recorder.elapsed(at: context.date)))
                        .font(.callout.monospacedDigit().weight(.semibold))
                        .foregroundStyle(Design.Palette.recording)
                case .paused:
                    Image(systemName: "pause.circle.fill").foregroundStyle(Design.Palette.paused)
                    Text(width < 100 ? TimeFormat.clock(recorder.elapsed(at: context.date)) : "Paused \(TimeFormat.clock(recorder.elapsed(at: context.date)))")
                        .font(.callout.monospacedDigit().weight(.semibold))
                        .foregroundStyle(Design.Palette.paused)
                case .starting:
                    ProgressView().controlSize(.mini)
                    Text("Starting…").font(.callout).foregroundStyle(.secondary)
                case .stopping:
                    ProgressView().controlSize(.mini)
                    Text("Saving…").font(.callout).foregroundStyle(.secondary)
                case .idle:
                    Text("Ready").font(.callout).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .frame(width: width, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(recorder.state == .recording ? "Recording" : recorder.state == .paused ? "Paused" : "Not recording")
    }
}

/// The Record button's own capsule: red to start or resume, quiet while recording.
struct RecordPillStyle: ButtonStyle {
    let tint: Color?
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(tint == nil ? Color.primary : Color.white)
            .padding(.horizontal, Design.Space.s)
            .padding(.vertical, Design.Space.xs)
            .background(Capsule().fill(tint ?? Color.primary.opacity(0.08)))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.5)
            .contentShape(Capsule())
    }
}

/// Lets a label style be chosen at runtime.
struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView
    init<S: LabelStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
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
    private let note = CATextLayer()
    private var timer: Timer?
    /// When the level last rose above silence, to say "No input" after a few quiet seconds.
    private var lastSound = Date()

    init(read: @escaping @MainActor () -> (level: Float, active: Bool)) {
        self.read = read
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(track)
        layer?.addSublayer(fill)
        note.string = "No input"
        note.fontSize = 10
        note.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        note.alignmentMode = .center
        note.contentsScale = 2
        note.isHidden = true
        layer?.addSublayer(note)
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
        if !active || value > 0.04 { lastSound = .now }
        let silent = active && Date.now.timeIntervalSince(lastSound) > 3

        CATransaction.begin()
        CATransaction.setAnimationDuration(1.0 / 15)
        // A thin bar centred vertically, leaving room for the "No input" note.
        let barHeight: CGFloat = 6
        let bar = CGRect(x: 0, y: (bounds.height - barHeight) / 2, width: bounds.width, height: barHeight)
        track.frame = bar
        track.cornerRadius = barHeight / 2
        track.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        track.isHidden = silent
        fill.frame = CGRect(x: bar.minX, y: bar.minY, width: bar.width * value, height: barHeight)
        fill.cornerRadius = barHeight / 2
        let colour: NSColor = value > 0.9 ? .systemRed : value > 0.75 ? .systemOrange : .systemGreen
        fill.backgroundColor = colour.cgColor
        fill.isHidden = silent
        note.isHidden = !silent
        note.frame = CGRect(x: 0, y: (bounds.height - 13) / 2, width: bounds.width, height: 13)
        note.foregroundColor = NSColor.systemOrange.cgColor
        note.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }

    deinit { MainActor.assumeIsolated { timer?.invalidate() } }
}

private struct InputPicker: View {
    let density: Design.ToolbarDensity
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
            HStack(spacing: Design.Space.xs) {
                Image(systemName: "mic")
                if density != .narrow {
                    Text(Self.shorten(currentName, to: density == .full ? 22 : 12)).lineLimit(1)
                }
            }
        }
        .fixedSize()
        .disabled(model.recorder.isActive)
        .help(model.recorder.isActive ? "Stop recording to change the input" : "Audio input: \(currentName) (⌥⌘M)")
        .accessibilityLabel("Audio input, \(currentName)")
        .onAppear { devices = AudioDeviceCatalog.inputDevices() }
        .onHover { if $0 { devices = AudioDeviceCatalog.inputDevices() } }
    }

    private var currentName: String {
        devices.first { $0.uid == inputUID }?.name ?? "System Default"
    }

    /// Toolbar menus ignore width limits, so long device names are shortened here.
    static func shorten(_ name: String, to length: Int) -> String {
        name.count <= length ? name : String(name.prefix(length - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}


/// ⌥⌘M: pick the audio input from the keyboard.
struct InputChooserSheet: View {
    @AppStorage(SettingsKey.inputDeviceUID) private var inputUID = ""
    @Environment(\.dismiss) private var dismiss
    @State private var devices: [AudioInputDevice] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.m) {
            Text("Audio Input").font(.title2.bold())
            Picker("Audio input", selection: $inputUID) {
                Text("System Default").tag("")
                ForEach(devices) { Text($0.name).tag($0.uid) }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Text("For the best results, use a feed from the sound desk rather than a laptop microphone.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(Design.Space.xl)
        .frame(width: 380)
        .onAppear { devices = AudioDeviceCatalog.inputDevices() }
    }
}
