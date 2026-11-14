import AppKit
import SwiftUI

/// Full-screen view of the live transcript for a projector or stream. Shows the most recent
/// lines large, with the latest song or verse callout styled like the main transcript.
struct PresentationView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.presentationFontSize) private var fontSize = 44.0
    @State private var window: NSWindow?

    var body: some View {
        let session = model.recorder.isActive ? model.recorder.session : model.selectedSession
        let items = Array((session?.orderedItems ?? []).filter { $0.parentItemID == nil }.suffix(8))

        ZStack(alignment: .bottomLeading) {
            Color.black.ignoresSafeArea()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: fontSize * 0.5) {
                        ForEach(items) { item in
                            PresentationItem(item: item, fontSize: fontSize).id(item.id)
                        }
                        if model.recorder.isActive && !model.recorder.volatileText.isEmpty {
                            Text(model.recorder.volatileText)
                                .font(.system(size: fontSize))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(fontSize)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
                .onChange(of: items.last?.id) { withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
                .onChange(of: model.recorder.volatileText) { proxy.scrollTo("end", anchor: .bottom) }
            }
            if session == nil || items.isEmpty {
                Text("The live transcript appears here as you record. For verses and lyrics on a projector, use the Output Screen (⌥⌘O).")
                    .font(.title)
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .preferredColorScheme(.dark)
        .background(WindowAccessor(window: $window))
        .toolbar {
            ToolbarItemGroup {
                Button { fontSize = max(fontSize - 4, 20) } label: { Label("Smaller", systemImage: "textformat.size.smaller") }
                Button { fontSize = min(fontSize + 4, 120) } label: { Label("Larger", systemImage: "textformat.size.larger") }
                Button { window?.toggleFullScreen(nil) } label: { Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") }
                    .keyboardShortcut("f", modifiers: [.command, .control])
            }
        }
    }
}

private struct PresentationItem: View {
    let item: TranscriptItem
    let fontSize: Double

    var body: some View {
        switch item.kind {
        case .segment:
            Text(item.text)
                .font(.system(size: fontSize))
                .foregroundStyle(.white)
        case .header:
            Text(item.subtitle.isEmpty ? item.title : "\(item.title) — \(item.subtitle)")
                .font(.system(size: fontSize * 0.6, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .textCase(.uppercase)
        case .song:
            VStack(alignment: .leading, spacing: 8) {
                Label(item.title, systemImage: "music.note")
                    .font(.system(size: fontSize * 0.6, weight: .semibold))
                    .foregroundStyle(.purple.mix(with: .white, by: 0.4))
                if let last = item.lyricSections.last {
                    Text(last.lyrics)
                        .font(.system(size: fontSize))
                        .foregroundStyle(.white)
                }
            }
        case .verse:
            VStack(alignment: .leading, spacing: 8) {
                Text(item.versionAbbreviation.isEmpty ? item.reference : "\(item.reference) · \(item.versionAbbreviation)")
                    .font(.system(size: fontSize * 0.6, weight: .semibold))
                    .foregroundStyle(.orange.mix(with: .white, by: 0.3))
                Text(item.verseText.isEmpty ? item.spokenText : item.verseText)
                    .font(.system(size: fontSize, design: .serif))
                    .foregroundStyle(.white)
            }
            .padding(.leading, fontSize * 0.4)
            .overlay(alignment: .leading) { Rectangle().fill(.orange).frame(width: 4) }
        }
    }
}

/// Gives SwiftUI access to the hosting NSWindow (for full screen).
struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { window = view.window }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if window == nil { DispatchQueue.main.async { window = nsView.window } }
    }
}
