import AppKit
import Foundation
import Observation
import ScriptureDetector
import SongMatcher
import SwiftData
import SwiftUI
import TranscribeCore

/// What can be on the output screen.
enum OutputSource: Equatable {
    /// A verse card in the transcript; corrections to the card show on screen straight away.
    case callout(UUID)
    /// A passage reached with next/previous verse, not tied to a card.
    case passage(BibleReference, version: String)
    /// A section of a song card (index into the song's full lyrics).
    case song(UUID, section: Int)
}

/// One thing queued for, or showing on, the screen: its source and its slides.
struct OutputCue: Identifiable, Equatable {
    let id = UUID()
    var source: OutputSource
    var slides: [OutputSlide]
    var page = 0

    var slide: OutputSlide? { slides.indices.contains(page) ? slides[page] : slides.last }
}

struct OutputSlide: Equatable {
    enum Kind: Equatable { case verse, lyric }
    var kind: Kind
    var text: String
    /// "John 3:16-18" or the song title.
    var heading: String
    /// "KJV", "NIV requested, showing KJV", or a song section name.
    var label: String
    /// Copyright line an online provider requires.
    var footnote: String = ""
    /// "2 / 3" when a passage is split.
    var pageNote: String = ""
}

/// Feeds the output screen: what's previewed, what's live, and detections waiting for the operator.
@MainActor
@Observable
final class OutputController {
    enum Mode: String, CaseIterable, Identifiable {
        case off, preview, autoSend
        var id: String { rawValue }
        var title: String {
            switch self {
            case .off: "Off"
            case .preview: "Detect to Preview"
            case .autoSend: "Auto-Send"
            }
        }
        var explanation: String {
            switch self {
            case .off: "Nothing goes to the screen unless you send it."
            case .preview: "Detected verses and lyrics wait in Preview for you to send."
            case .autoSend: "Confident detections go straight to the screen; others wait in Preview."
            }
        }
    }

    private(set) var preview: OutputCue?
    private(set) var live: OutputCue?
    /// Detections waiting behind the one in Preview.
    private(set) var queue: [OutputCue] = []
    /// Follow the sung lyrics on screen; turned off when the operator moves a song by hand.
    var followSong = true

    var mode: Mode {
        get { Mode(rawValue: UserDefaults.standard.string(forKey: SettingsKey.outputMode) ?? "") ?? .preview }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: SettingsKey.outputMode); modeVersion += 1 }
    }
    /// Detections less sure than this are never sent automatically.
    var threshold: Double {
        get { UserDefaults.standard.object(forKey: SettingsKey.outputThreshold) as? Double ?? 0.85 }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKey.outputThreshold); modeVersion += 1 }
    }
    private var modeVersion = 0

    var theme = OutputTheme.load() {
        didSet { theme.save(); refreshAll() }
    }

    private let context: ModelContext
    private let scripture: ScriptureService
    /// Bumped when a card changes, so slides built from its old contents are rebuilt.
    private var revisions: [UUID: Int] = [:]

    init(context: ModelContext, scripture: ScriptureService) {
        self.context = context
        self.scripture = scripture
    }

    // MARK: Operator actions

    /// Sends a card straight to the screen.
    func send(_ source: OutputSource) async {
        guard let cue = await makeCue(source) else { return }
        live = cue
        removeFromQueue(source)
        if case .song = source { followSong = true }
    }

    func showInPreview(_ source: OutputSource) async {
        guard let cue = await makeCue(source) else { return }
        if let preview, preview.source != source, !queue.contains(where: { $0.source == preview.source }) {
            queue.insert(preview, at: 0)
        }
        preview = cue
        queue.removeAll { $0.source == source }
    }

    /// Shows exactly this in Preview, replacing what was there without queueing it, and sends
    /// it on its own: used for verses the operator types or picks from Recent.
    func previewOnly(_ source: OutputSource) async {
        guard let cue = await makeCue(source) else { return }
        preview = cue
        queue.removeAll()
    }

    /// Preview goes live, and the next waiting detection moves into Preview.
    func take() {
        guard let preview else { return }
        live = preview
        if case .song = preview.source { followSong = true }
        self.preview = queue.isEmpty ? nil : queue.removeFirst()
    }

    func skipPreview() {
        preview = queue.isEmpty ? nil : queue.removeFirst()
    }

    func clearScreen() {
        live = nil
    }

    /// Next or previous slide of a split passage or song section; past the end, the next verse
    /// or section.
    func step(slide delta: Int, onLive: Bool) async {
        guard var cue = onLive ? live : preview else { return }
        let page = cue.page + delta
        if cue.slides.indices.contains(page) {
            cue.page = page
            set(cue, onLive: onLive)
        } else {
            await step(verse: delta, onLive: onLive)
        }
    }

    /// The next or previous verse (or song section) after what's showing.
    func step(verse delta: Int, onLive: Bool) async {
        guard let cue = onLive ? live : preview else { return }
        var next: OutputSource?
        switch cue.source {
        case .callout(let id):
            if let item = item(id), let reference = item.bibleReference, let stepped = ReferenceParser.step(reference, by: delta) {
                next = .passage(stepped, version: item.versionAbbreviation)
            }
        case .passage(let reference, let version):
            if let stepped = ReferenceParser.step(reference, by: delta) { next = .passage(stepped, version: version) }
        case .song(let id, let section):
            let count = songSections(id).count
            if (0..<count).contains(section + delta) { next = .song(id, section: section + delta) }
            followSong = false
        }
        guard let next, var fresh = await makeCue(next) else { return }
        if delta < 0 { fresh.page = fresh.slides.count - 1 }
        set(fresh, onLive: onLive)
    }

    private func set(_ cue: OutputCue, onLive: Bool) {
        if onLive { live = cue } else { preview = cue }
    }

    // MARK: Detections

    /// A new verse card. What happens depends on the auto-detect mode.
    func detected(_ item: TranscriptItem, confidence: Double) {
        let source = OutputSource.callout(item.id)
        Task {
            switch mode {
            case .off:
                return
            case .autoSend where confidence >= threshold && item.referenceConfidence >= 0.75:
                await send(source)
            case .preview, .autoSend:
                await enqueue(source)
            }
        }
    }

    /// A section of a song is being sung.
    func sectionSung(_ item: TranscriptItem, section: Int, confidence: Double) {
        let source = OutputSource.song(item.id, section: section)
        Task {
            // Following along: the song is on screen, so advance it as it's sung.
            if case .song(let id, let current)? = live?.source, id == item.id {
                if followSong && current != section { await send(source) }
                return
            }
            switch mode {
            case .off:
                return
            case .autoSend where confidence >= threshold:
                await send(source)
            case .preview, .autoSend:
                // One place per song: a newer section replaces the one waiting.
                guard let cue = await makeCue(source) else { return }
                if case .song(let id, _)? = preview?.source, id == item.id {
                    preview = cue
                } else if let index = queue.firstIndex(where: { if case .song(let id, _) = $0.source { id == item.id } else { false } }) {
                    queue[index] = cue
                } else if preview == nil {
                    preview = cue
                } else {
                    queue.append(cue)
                }
            }
        }
    }

    private func enqueue(_ source: OutputSource) async {
        guard let cue = await makeCue(source) else { return }
        if preview == nil || preview?.source == source {
            preview = cue
        } else if let index = queue.firstIndex(where: { $0.source == source }) {
            queue[index] = cue
        } else {
            queue.append(cue)
        }
    }

    /// A card changed (version settled, reference corrected): refresh it wherever it shows.
    func calloutChanged(_ item: TranscriptItem) {
        revisions[item.id, default: 0] += 1
        let source = OutputSource.callout(item.id)
        Task { await refresh(source) }
    }

    /// A card was dismissed: take it off the screen and out of the queue.
    func calloutRemoved(_ id: UUID) {
        let source = OutputSource.callout(id)
        if live?.source == source { live = nil }
        if preview?.source == source { skipPreview() }
        removeFromQueue(source)
    }

    private func removeFromQueue(_ source: OutputSource) {
        queue.removeAll { $0.source == source }
    }

    private func refresh(_ source: OutputSource) async {
        let showing = live?.source == source || preview?.source == source || queue.contains { $0.source == source }
        guard showing, let cue = await makeCue(source) else { return }
        if var current = live, current.source == source {
            current.slides = cue.slides
            current.page = min(current.page, cue.slides.count - 1)
            live = current
        }
        if var current = preview, current.source == source {
            current.slides = cue.slides
            current.page = min(current.page, cue.slides.count - 1)
            preview = current
        }
        if let index = queue.firstIndex(where: { $0.source == source }) { queue[index].slides = cue.slides }
    }

    private func refreshAll() {
        let sources = [live?.source, preview?.source].compactMap { $0 } + queue.map(\.source)
        Task { for source in sources { await refresh(source) } }
    }

    // MARK: Building slides

    /// Builds the slides for `source`, again if its card changed while they were being built,
    /// so a slow build can never put out-of-date text on screen.
    func makeCue(_ source: OutputSource) async -> OutputCue? {
        guard case .callout(let id) = source else { return await buildCue(source) }
        for _ in 0..<3 {
            let revision = revisions[id] ?? 0
            let cue = await buildCue(source)
            if revisions[id] ?? 0 == revision { return cue }
        }
        return await buildCue(source)
    }

    private func buildCue(_ source: OutputSource) async -> OutputCue? {
        let slides: [OutputSlide]
        switch source {
        case .callout(let id):
            guard let item = item(id), let reference = item.bibleReference else { return nil }
            let label = item.requestedVersion.isEmpty ? item.versionAbbreviation : "\(item.requestedVersion) requested, showing \(item.versionAbbreviation)"
            slides = await verseSlides(reference, version: item.versionAbbreviation, fallbackText: item.verseText, label: label, footnote: item.verseCopyright)
        case .passage(let reference, let version):
            let text = await scripture.text(of: reference, abbreviation: version) ?? ""
            guard !text.isEmpty else { return nil }
            slides = await verseSlides(reference, version: version, fallbackText: text, label: version, footnote: "")
        case .song(let id, let section):
            guard let item = item(id) else { return nil }
            let sections = songSections(id)
            guard sections.indices.contains(section) else { return nil }
            let lyric = sections[section]
            let pages = lyricPages(lyric.lyrics)
            slides = pages.enumerated().map { index, text in
                OutputSlide(kind: .lyric, text: text, heading: item.title, label: lyric.name,
                            pageNote: pages.count > 1 ? "\(index + 1) / \(pages.count)" : "")
            }
        }
        guard !slides.isEmpty else { return nil }
        return OutputCue(source: source, slides: slides)
    }

    private func verseSlides(_ reference: BibleReference, version: String, fallbackText: String, label: String, footnote: String) async -> [OutputSlide] {
        let verses = await scripture.verses(of: reference, abbreviation: version)
        let units: [String]
        if verses.count > 1 {
            units = verses.map { theme.showVerseNumbers ? "\(Self.superscript($0.verse)) \($0.text)" : $0.text }
        } else {
            units = [verses.first?.text ?? fallbackText]
        }
        let pages = SlideSplitter.split(units.filter { !$0.isEmpty }, maxWords: theme.maxWordsPerSlide)
        return pages.enumerated().map { index, text in
            OutputSlide(kind: .verse, text: text, heading: reference.description, label: label, footnote: footnote,
                        pageNote: pages.count > 1 ? "\(index + 1) / \(pages.count)" : "")
        }
    }

    /// Song sections split at blank lines or every few lines, so lyrics stay readable.
    private func lyricPages(_ lyrics: String) -> [String] {
        let lines = lyrics.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        var pages: [[String]] = [[]]
        for line in lines {
            if line.isEmpty || pages[pages.count - 1].count >= theme.linesPerLyricSlide {
                if !pages[pages.count - 1].isEmpty { pages.append([]) }
                if line.isEmpty { continue }
            }
            pages[pages.count - 1].append(line)
        }
        return pages.filter { !$0.isEmpty }.map { $0.joined(separator: "\n") }
    }

    /// The song's full lyrics from the library, or the sections heard so far.
    func songSections(_ itemID: UUID) -> [SongSection] {
        guard let item = item(itemID) else { return [] }
        if let songID = item.songID,
           let stored = try? context.fetch(FetchDescriptor<StoredSong>(predicate: #Predicate { $0.id == songID })).first,
           !stored.sections.isEmpty {
            return stored.sections
        }
        return item.lyricSections
    }

    /// The index of `section` in the song's full lyrics, for sending a section from a card.
    func songSectionIndex(_ itemID: UUID, matching section: SongSection) -> Int {
        songSections(itemID).firstIndex(of: section) ?? 0
    }

    private func item(_ id: UUID) -> TranscriptItem? {
        let item = try? context.fetch(FetchDescriptor<TranscriptItem>(predicate: #Predicate { $0.id == id })).first
        return item?.isDeleted == false ? item : nil
    }

    static func superscript(_ number: Int) -> String {
        let digits: [Character: Character] = ["0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹"]
        return String(String(number).map { digits[$0] ?? $0 })
    }

    // MARK: Displays

    /// The chosen display, or another display than this one if there is one.
    var outputScreen: NSScreen? {
        let name = UserDefaults.standard.string(forKey: SettingsKey.outputDisplay) ?? ""
        if let chosen = NSScreen.screens.first(where: { $0.localizedName == name }) { return chosen }
        return NSScreen.screens.first { $0 != NSScreen.main } ?? NSScreen.main
    }
}

/// How the output screen looks.
struct OutputTheme: Codable, Equatable {
    enum Alignment: String, Codable, CaseIterable, Identifiable {
        case leading, center, trailing
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var text: TextAlignment { self == .leading ? .leading : self == .center ? .center : .trailing }
        var frame: SwiftUI.Alignment { self == .leading ? .leading : self == .center ? .center : .trailing }
        var horizontal: HorizontalAlignment { self == .leading ? .leading : self == .center ? .center : .trailing }
    }
    enum Placement: String, Codable, CaseIterable, Identifiable {
        case top, bottom, hidden
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }
    enum LabelPlacement: String, Codable, CaseIterable, Identifiable {
        case withReference, corner, hidden
        var id: String { rawValue }
        var title: String {
            switch self {
            case .withReference: "With reference"
            case .corner: "Bottom corner"
            case .hidden: "Hidden"
            }
        }
    }

    var fontName = ""
    var fontSize = 64.0
    var textColor = "#FFFFFF"
    var backgroundColor = "#000000"
    var backgroundImage = ""
    var backgroundDim = 0.4
    var alignment = Alignment.center
    var referencePlacement = Placement.bottom
    var versionPlacement = LabelPlacement.withReference
    var maxWordsPerSlide = 45
    var linesPerLyricSlide = 4
    var showVerseNumbers = true
    var shadow = true

    static func load() -> OutputTheme {
        UserDefaults.standard.data(forKey: SettingsKey.outputTheme).flatMap { try? JSONDecoder().decode(OutputTheme.self, from: $0) } ?? OutputTheme()
    }

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: SettingsKey.outputTheme)
    }

    static var backgroundsDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Transcribe/Backgrounds", directoryHint: .isDirectory)
    }
}

extension Color {
    /// "#RRGGBB" to a color; white if it can't be read.
    init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&value)
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    var hex: String {
        let color = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return String(format: "#%02X%02X%02X", Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255))
    }
}
