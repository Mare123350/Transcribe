import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Output: which display, auto-detect, and how slides look.
struct OutputSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.outputDisplay) private var displayName = ""
    @State private var choosingImage = false
    @State private var screens: [String] = []

    private static let sample = OutputSlide(kind: .verse, text: "For God so loved the world, that he gave his only begotten Son, that whosoever believeth in him should not perish, but have everlasting life.", heading: "John 3:16", label: "KJV")

    var body: some View {
        let output = model.output
        Form {
            Section("Display") {
                Picker("Output display", selection: $displayName) {
                    Text("Automatic (a second display if connected)").tag("")
                    ForEach(screens, id: \.self) { Text($0).tag($0) }
                }
                .onChange(of: displayName) { NotificationCenter.default.post(name: .outputDisplayChanged, object: nil) }
                Text(screens.count > 1 ? "The output window fills the chosen display." : "Only one display is connected, so the output opens as a window you can move.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Auto-Detect") {
                Picker("Mode", selection: Binding(get: { output.mode }, set: { output.mode = $0 })) {
                    ForEach(OutputController.Mode.allCases) { Text($0.title).tag($0) }
                }
                Text(output.mode.explanation).font(.caption).foregroundStyle(.secondary)
                LabeledContent("Auto-send only above") {
                    Slider(value: Binding(get: { output.threshold }, set: { output.threshold = $0 }), in: 0.75...0.99, step: 0.01) {
                        Text("Threshold")
                    } minimumValueLabel: { Text("75%").font(.caption) } maximumValueLabel: { Text("99%").font(.caption) }
                }
                Text("Detections below \(Int(output.threshold * 100))% confidence, and references that need confirming, always wait in Preview.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Look") {
                OutputSlideView(slide: Self.sample, theme: output.theme)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Design.Radius.small))
                Picker("Font", selection: theme(\.fontName)) {
                    Text("System Serif").tag("")
                    ForEach(NSFontManager.shared.availableFontFamilies, id: \.self) { Text($0).tag($0) }
                }
                LabeledContent("Size") {
                    Slider(value: theme(\.fontSize), in: 32...120, step: 2)
                }
                ColorPicker("Text colour", selection: Binding(get: { Color(hex: output.theme.textColor) }, set: { output.theme.textColor = $0.hex }), supportsOpacity: false)
                ColorPicker("Background colour", selection: Binding(get: { Color(hex: output.theme.backgroundColor) }, set: { output.theme.backgroundColor = $0.hex }), supportsOpacity: false)
                LabeledContent("Background image") {
                    HStack {
                        Text(output.theme.backgroundImage.isEmpty ? "None" : output.theme.backgroundImage).foregroundStyle(.secondary).lineLimit(1)
                        Button("Choose…") { choosingImage = true }
                        if !output.theme.backgroundImage.isEmpty {
                            Button("Remove") { output.theme.backgroundImage = "" }
                        }
                    }
                }
                if !output.theme.backgroundImage.isEmpty {
                    LabeledContent("Darken image") { Slider(value: theme(\.backgroundDim), in: 0...0.8) }
                }
                Picker("Alignment", selection: theme(\.alignment)) {
                    ForEach(OutputTheme.Alignment.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Reference", selection: theme(\.referencePlacement)) {
                    ForEach(OutputTheme.Placement.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Translation label", selection: theme(\.versionPlacement)) {
                    ForEach(OutputTheme.LabelPlacement.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Verse numbers in passages", isOn: theme(\.showVerseNumbers))
                Toggle("Text shadow", isOn: theme(\.shadow))
            }

            Section("Long Passages and Songs") {
                Stepper("Up to \(output.theme.maxWordsPerSlide) words per slide", value: theme(\.maxWordsPerSlide), in: 15...120, step: 5)
                Stepper("Up to \(output.theme.linesPerLyricSlide) lyric lines per slide", value: theme(\.linesPerLyricSlide), in: 2...8)
                Text("Longer passages are split across slides at verse breaks (then sentences). Use ⌘] and ⌘[ to move through them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { screens = NSScreen.screens.map(\.localizedName) }
        .fileImporter(isPresented: $choosingImage, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            // Keep a copy, so the background still works if the original moves.
            let directory = OutputTheme.backgroundsDirectory
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appending(path: url.lastPathComponent)
            try? FileManager.default.removeItem(at: destination)
            if (try? FileManager.default.copyItem(at: url, to: destination)) != nil {
                output.theme.backgroundImage = url.lastPathComponent
            }
        }
    }

    private func theme<Value>(_ keyPath: WritableKeyPath<OutputTheme, Value>) -> Binding<Value> {
        Binding(get: { model.output.theme[keyPath: keyPath] }, set: { model.output.theme[keyPath: keyPath] = $0 })
    }
}
