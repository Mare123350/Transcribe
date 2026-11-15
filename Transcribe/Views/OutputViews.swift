import AppKit
import SwiftUI

/// One slide as it appears on the output screen. Laid out on a 1920×1080 canvas and scaled to fit,
/// so the preview thumbnails show exactly what the screen will show.
struct OutputSlideView: View {
    let slide: OutputSlide?
    let theme: OutputTheme

    static let canvas = CGSize(width: 1920, height: 1080)

    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / Self.canvas.width, proxy.size.height / Self.canvas.height)
            canvas
                .frame(width: Self.canvas.width, height: Self.canvas.height)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: Self.canvas.width * scale, height: Self.canvas.height * scale, alignment: .topLeading)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(hex: theme.backgroundColor))
    }

    private var canvas: some View {
        ZStack {
            background
            if let slide {
                content(slide)
                    .padding(.horizontal, 120)
                    .padding(.vertical, 90)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: theme.alignment.frame)
                if theme.versionPlacement == .corner && slide.kind == .verse && !slide.label.isEmpty {
                    Text(slide.label)
                        .font(font(size: theme.fontSize * 0.42, weight: .semibold))
                        .foregroundStyle(textColor.opacity(0.75))
                        .padding(48)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
        }
        .clipped()
    }

    @ViewBuilder private var background: some View {
        Color(hex: theme.backgroundColor)
        if !theme.backgroundImage.isEmpty, let image = NSImage(contentsOf: OutputTheme.backgroundsDirectory.appending(path: theme.backgroundImage)) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: Self.canvas.width, height: Self.canvas.height)
                .clipped()
            Color.black.opacity(theme.backgroundDim)
        }
    }

    private func content(_ slide: OutputSlide) -> some View {
        VStack(alignment: theme.alignment.horizontal, spacing: theme.fontSize * 0.5) {
            if theme.referencePlacement == .top { heading(slide) }
            Text(slide.text)
                .font(font(size: theme.fontSize, weight: .regular))
                .foregroundStyle(textColor)
                .multilineTextAlignment(theme.alignment.text)
                .lineSpacing(theme.fontSize * 0.18)
                .minimumScaleFactor(0.5)
            if theme.referencePlacement == .bottom { heading(slide) }
            if !slide.footnote.isEmpty {
                Text(slide.footnote)
                    .font(.system(size: 22))
                    .foregroundStyle(textColor.opacity(0.6))
                    .multilineTextAlignment(theme.alignment.text)
            }
        }
        .shadow(color: theme.shadow ? .black.opacity(0.6) : .clear, radius: 6, x: 0, y: 3)
    }

    @ViewBuilder private func heading(_ slide: OutputSlide) -> some View {
        let showLabel = slide.kind == .lyric || theme.versionPlacement == .withReference
        let parts = [slide.heading, showLabel ? slide.label : "", slide.pageNote].filter { !$0.isEmpty }
        Text(parts.joined(separator: "  ·  "))
            .font(font(size: theme.fontSize * 0.5, weight: .semibold))
            .foregroundStyle(textColor.opacity(0.8))
            .multilineTextAlignment(theme.alignment.text)
    }

    private var textColor: Color { Color(hex: theme.textColor) }

    private func font(size: Double, weight: Font.Weight) -> Font {
        theme.fontName.isEmpty ? .system(size: size, weight: weight, design: .serif) : .custom(theme.fontName, size: size).weight(weight)
    }
}

/// The window on the projector or second display: whatever is live, full screen.
struct OutputWindowView: View {
    @Environment(AppModel.self) private var model
    @State private var window: NSWindow?
    /// True when the output is an ordinary window (one display), not a projector.
    @State private var windowed = true

    var body: some View {
        OutputSlideView(slide: model.output.live?.slide, theme: model.output.theme)
            .ignoresSafeArea()
            .overlay {
                // On a projector an empty screen stays black; in a window, say what to do.
                if windowed && model.output.live == nil { emptyHint }
            }
            .background(WindowAccessor(window: $window))
            .onChange(of: window) { place() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in place() }
            .onReceive(NotificationCenter.default.publisher(for: .outputDisplayChanged)) { _ in place() }
    }

    /// Fills the chosen display, borderless, above its menu bar. On a single-display Mac it stays
    /// an ordinary window so it doesn't cover the operator's screen.
    private var emptyHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.on.rectangle").font(.system(size: 36))
            Text("Nothing on screen").font(.title2.weight(.semibold))
            Group {
                if let heading = model.output.preview?.slide?.heading {
                    Text("“\(heading)” is in Preview. Press Send (⌘↩) to show it here.")
                } else {
                    Text("Send a verse or song from its card, or type one with ⌘K.")
                }
            }
            .font(.callout)
            Text("Connect a projector or second display and this window fills it automatically.")
                .font(.caption)
                .padding(.top, 6)
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(.white.opacity(0.6))
        .padding()
    }

    private func place() {
        guard let window, let screen = model.output.outputScreen else { return }
        windowed = !(NSScreen.screens.count > 1 && screen != NSScreen.main)
        if !windowed {
            window.styleMask = [.borderless]
            window.level = .mainMenu + 1
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.setFrame(screen.frame, display: true)
            window.hasShadow = false
        } else {
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.level = .normal
            if window.frame.width < 400 { window.setContentSize(NSSize(width: 960, height: 540)) }
        }
        window.backgroundColor = .black
        window.title = "Output"
    }
}

extension Notification.Name {
    static let outputDisplayChanged = Notification.Name("outputDisplayChanged")
}

/// Preview and live, side by side like presentation software, with the controls an operator needs.
struct OutputPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let output = model.output
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Auto-detect", selection: Binding(get: { output.mode }, set: { output.mode = $0 })) {
                    ForEach(OutputController.Mode.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .help(output.mode.explanation)
                Spacer()
                Button { openWindow(id: WindowID.output) } label: { Image(systemName: "rectangle.on.rectangle") }
                    .buttonStyle(.borderless)
                    .help("Open the output window on the chosen display (⌥⌘O)")
            }

            if output.manualHold {
                HStack(alignment: .center, spacing: Design.Space.s) {
                    Image(systemName: "hand.raised.fill").foregroundStyle(Design.Palette.song)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Holding your song").font(.caption.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(output.queue.isEmpty ? "Detections will wait." : "\(output.queue.count) detection\(output.queue.count == 1 ? "" : "s") waiting")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 0)
                    Button("Resume Auto") { output.resumeAuto() }
                        .controlSize(.small)
                        .fixedSize()
                        .help("Let detected verses and songs reach Preview again")
                }
                .padding(Design.Space.s)
                .background(Design.Palette.song.opacity(0.1), in: RoundedRectangle(cornerRadius: Design.Radius.small))
            }

            screen("Preview", cue: output.preview, live: false)
            if let cue = output.preview, cue.slides.count > 1 { SlideStrip(cue: cue, onLive: false) }
            HStack {
                Button { Task { await output.step(verse: -1, onLive: false) } } label: { Image(systemName: "chevron.left") }
                    .help("Previous verse or section")
                Button { Task { await output.step(verse: 1, onLive: false) } } label: { Image(systemName: "chevron.right") }
                    .help("Next verse or section")
                if !output.queue.isEmpty {
                    Text("\(output.queue.count) waiting").font(.caption).foregroundStyle(.secondary)
                    Button("Skip") { output.skipPreview() }.controlSize(.small)
                }
                Spacer()
                Button("Send") { output.take() }
                    .buttonStyle(.borderedProminent)
                    .disabled(output.preview == nil)
                    .help("Send the preview to the screen (⌘↩)")
            }
            .controlSize(.small)

            screen("Live", cue: output.live, live: true)
            if let cue = output.live, cue.slides.count > 1 { SlideStrip(cue: cue, onLive: true) }
            HStack {
                Button { Task { await output.step(slide: -1, onLive: true) } } label: { Image(systemName: "chevron.left") }
                    .help("Previous slide (⌘[)")
                Button { Task { await output.step(slide: 1, onLive: true) } } label: { Image(systemName: "chevron.right") }
                    .help("Next slide (⌘])")
                if case .song? = output.live?.source {
                    Toggle("Follow", isOn: Binding(get: { output.followSong }, set: { output.followSong = $0 }))
                        .toggleStyle(.checkbox)
                        .help("Advance the lyrics as the song is sung")
                }
                Spacer()
                Button("Clear", role: .destructive) { output.clearScreen() }
                    .disabled(output.live == nil)
                    .help("Clear the screen (⇧⌘⌫)")
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private func screen(_ title: String, cue: OutputCue?, live: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if live { Circle().fill(cue == nil ? Color.secondary : Color.red).frame(width: 7, height: 7) }
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                Spacer()
                if let slide = cue?.slide { Text(slide.heading).font(.caption).lineLimit(1) }
            }
            OutputSlideView(slide: cue?.slide, theme: model.output.theme)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(live && cue != nil ? Color.red : Color.secondary.opacity(0.3), lineWidth: live && cue != nil ? 2 : 1))
                .overlay {
                    if cue == nil {
                        Text(live ? "Screen is clear" : "Nothing in preview").font(.caption).foregroundStyle(.white.opacity(0.6))
                    }
                }
        }
    }
}

/// Every slide of what's in Preview or Live (V1, C, V2, B for a song; 1, 2, 3 for a long passage).
/// Click one to jump to it; with the list focused, number keys 1–9 jump too.
struct SlideStrip: View {
    let cue: OutputCue
    let onLive: Bool
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Design.Space.xs) {
                    ForEach(Array(cue.slides.enumerated()), id: \.offset) { index, slide in
                        let current = index == cue.page
                        Button { model.output.go(toSlide: index, onLive: onLive) } label: {
                            Text(Self.label(for: slide, at: index, in: cue))
                                .font(.caption.weight(current ? .bold : .regular).monospacedDigit())
                                .padding(.horizontal, Design.Space.s)
                                .padding(.vertical, Design.Space.xxs)
                                .background(current ? (onLive ? Design.Palette.live : Color.accentColor) : Color.secondary.opacity(0.15), in: Capsule())
                                .foregroundStyle(current ? Color.white : Color.primary)
                        }
                        .buttonStyle(.plain)
                        .id(index)
                        .help("\(slide.label.isEmpty ? "Slide \(index + 1)" : slide.label)\(index < 9 ? " (\(index + 1))" : "")")
                        .accessibilityLabel("Slide \(index + 1), \(slide.label)")
                    }
                }
                .padding(Design.Space.xxs)
            }
            .onChange(of: cue.page) { withAnimation { proxy.scrollTo(cue.page, anchor: .center) } }
        }
        .focusable()
        .focused($focused)
        .overlay(RoundedRectangle(cornerRadius: Design.Radius.small).strokeBorder(focused ? Color.accentColor.opacity(0.6) : .clear))
        .onKeyPress(characters: .decimalDigits) { press in
            guard let number = Int(press.characters), number >= 1 else { return .ignored }
            model.output.go(toSlide: number - 1, onLive: onLive)
            return .handled
        }
        .onKeyPress(.rightArrow) { model.output.go(toSlide: cue.page + 1, onLive: onLive); return .handled }
        .onKeyPress(.leftArrow) { model.output.go(toSlide: cue.page - 1, onLive: onLive); return .handled }
    }

    /// "V1", "C", "B", "PC"; a second page of a section adds "·2"; passages are numbered.
    static func label(for slide: OutputSlide, at index: Int, in cue: OutputCue) -> String {
        guard slide.kind == .lyric else { return "\(index + 1)" }
        let words = slide.label.split(separator: " ")
        var short = words.filter { $0.first?.isLetter == true }.map { String($0.prefix(1)).uppercased() }.joined()
        if slide.label.lowercased().hasPrefix("pre") { short = "PC" }
        if let number = words.last.flatMap({ Int($0) }) { short += "\(number)" }
        if short.isEmpty { short = "\(index + 1)" }
        let samePart = cue.slides.indices.filter { cue.slides[$0].sectionIndex == slide.sectionIndex && cue.slides[$0].label == slide.label }
        if samePart.count > 1, let position = samePart.firstIndex(of: index), position > 0 { short += "·\(position + 1)" }
        return short
    }
}
