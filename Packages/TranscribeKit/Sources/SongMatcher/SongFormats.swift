import Foundation

/// The song file formats Transcribe can import.
public enum SongFileFormat: String, Sendable {
    case json = "JSON"
    case text = "Plain text"
    case chordPro = "ChordPro"
    case openLyrics = "OpenLyrics"
    case songSelectUSR = "CCLI SongSelect (.usr)"
    case songSelectText = "CCLI SongSelect text"

    public static let fileExtensions = ["json", "txt", "text", "cho", "chordpro", "chopro", "crd", "pro", "usr", "xml"]

    static func detect(extension ext: String, text: String) -> SongFileFormat {
        switch ext.lowercased() {
        case "json": return .json
        case "cho", "chordpro", "chopro", "crd", "pro": return .chordPro
        case "usr": return .songSelectUSR
        default: break
        }
        let head = String(text.prefix(4000))
        if head.contains("<song") && (head.contains("openlyrics") || head.contains("<lyrics")) { return .openLyrics }
        if head.contains("[File]") || (head.contains("Fields=") && head.contains("Words=")) { return .songSelectUSR }
        if head.range(of: #"\{\s*(title|t|soc|start_of_chorus|start_of_verse)\s*[:}]"#, options: .regularExpression) != nil { return .chordPro }
        if text.contains("CCLI Song #") || text.contains("CCLI Song No") { return .songSelectText }
        if head.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") || head.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[") && head.contains("\"title\"") { return .json }
        return .text
    }
}

extension SongImporter {
    /// Names for section codes used by OpenLyrics and others: v1 → Verse 1, c → Chorus.
    static func sectionName(code: String) -> String {
        let letters = code.prefix { $0.isLetter }.lowercased()
        let number = code.drop { $0.isLetter }
        let base: String
        switch letters {
        case "v": base = "Verse"
        case "c": base = "Chorus"
        case "b": base = "Bridge"
        case "p": base = "Pre-Chorus"
        case "e": base = "Ending"
        case "i": base = "Intro"
        case "o": base = "Outro"
        case "t": base = "Tag"
        default: base = code.capitalized
        }
        if letters == "v" && number.isEmpty { return "Verse 1" }
        return number.isEmpty ? base : "\(base) \(number)"
    }

    // MARK: ChordPro

    private static let chordPattern = try! NSRegularExpression(pattern: #"\[[^\]]*\]"#)
    private static let directivePattern = try! NSRegularExpression(pattern: #"^\{\s*([a-zA-Z_]+)\s*(?::\s*(.*?))?\s*\}$"#)

    /// ChordPro: `{title:}`, `{artist:}`, `{ccli:}`, `{copyright:}`, `{start_of_chorus}`/`{soc}`,
    /// `{start_of_verse: Verse 2}`, `{comment: Bridge}`, chords in square brackets (removed).
    /// Several songs in one file are separated by `{new_song}`.
    public static func songs(fromChordPro text: String) -> [SongRecord] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var songs: [SongRecord] = []
        var title = "", artist = "", ccli = "", copyright = ""
        var themes: [String] = []
        var sections: [SongSection] = []
        var name: String?
        var body: [String] = []
        var inEnvironment = false
        var verseCount = 0

        func flush() {
            let lyrics = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !lyrics.isEmpty {
                var sectionName = name ?? ""
                if sectionName.isEmpty { verseCount += 1; sectionName = "Verse \(verseCount)" }
                else if sectionName.lowercased().hasPrefix("verse") { verseCount = max(verseCount, Int(sectionName.filter(\.isNumber)) ?? verseCount + 1) }
                sections.append(SongSection(name: sectionName, lyrics: lyrics))
            }
            body = []
        }
        func finishSong() {
            flush()
            if !title.isEmpty && !sections.isEmpty {
                songs.append(SongRecord(title: title, artist: artist, sections: sections, ccliNumber: ccli, copyright: copyright, themes: themes))
            }
            title = ""; artist = ""; ccli = ""; copyright = ""; themes = []; sections = []; name = nil; verseCount = 0; inEnvironment = false
        }

        for rawLine in normalized.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            let ns = line as NSString
            if let match = directivePattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                let directive = ns.substring(with: match.range(at: 1)).lowercased()
                let value = match.range(at: 2).location != NSNotFound ? ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces) : ""
                switch directive {
                case "title", "t": title = value
                case "artist", "subtitle", "st", "composer", "lyricist":
                    if artist.isEmpty { artist = value }
                case "ccli": ccli = value.filter(\.isNumber)
                case "copyright": copyright = value
                case "keywords", "theme", "themes":
                    themes += value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                case "new_song", "ns": finishSong()
                case "start_of_chorus", "soc":
                    flush(); name = value.isEmpty ? "Chorus" : value; inEnvironment = true
                case "start_of_verse", "sov":
                    flush(); name = value.isEmpty ? nil : value; inEnvironment = true
                case "start_of_bridge", "sob":
                    flush(); name = value.isEmpty ? "Bridge" : value; inEnvironment = true
                case "start_of_tab", "sot", "start_of_grid", "sog":
                    flush(); name = "__skip__"; inEnvironment = true
                case "end_of_chorus", "eoc", "end_of_verse", "eov", "end_of_bridge", "eob", "end_of_tab", "eot", "end_of_grid", "eog":
                    if name == "__skip__" { body = [] } else { flush() }
                    name = nil; inEnvironment = false
                case "comment", "c", "comment_italic", "ci", "comment_box", "cb":
                    // Usually a section label ("Verse 2", "Chorus").
                    flush(); name = value.isEmpty ? nil : value
                default: break
                }
                continue
            }
            if line.isEmpty {
                if !inEnvironment { flush(); name = nil }
                continue
            }
            if let heading = sectionHeading(line), !inEnvironment {
                flush(); name = heading
                continue
            }
            let lyric = chordPattern.stringByReplacingMatches(in: line, range: NSRange(location: 0, length: ns.length), withTemplate: "")
                .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            if !lyric.isEmpty { body.append(lyric) }
        }
        finishSong()
        return songs
    }

    private static let headingOnly = try! NSRegularExpression(
        pattern: #"^\[?\s*(verse|chorus|refrain|bridge|pre[- ]?chorus|tag|intro|outro|ending|interlude)\s*(\d+)?\s*\]?\s*:?\s*$"#, options: [.caseInsensitive])

    /// "Verse 2:", "[Chorus]" on a line of its own.
    static func sectionHeading(_ line: String) -> String? {
        let ns = line as NSString
        guard let match = headingOnly.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let kind = ns.substring(with: match.range(at: 1))
        let number = match.range(at: 2).location != NSNotFound ? " " + ns.substring(with: match.range(at: 2)) : ""
        return kind.prefix(1).uppercased() + kind.dropFirst().lowercased() + number
    }

    // MARK: OpenLyrics

    /// OpenLyrics XML (exported by OpenLP, OpenSong converters and others).
    public static func songs(fromOpenLyrics data: Data) throws -> [SongRecord] {
        let reader = OpenLyricsReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { throw SongImportError.malformed("the OpenLyrics XML couldn't be read (line \(parser.lineNumber))") }
        guard let song = reader.song() else { throw SongImportError.noSongs }
        return [song]
    }

    // MARK: SongSelect

    /// CCLI SongSelect `.usr` files: `Title=`, `Author=`, `Copyright=`, `Themes=`, and parallel
    /// `Fields=` / `Words=` lists separated by `/t`, with `/n` line breaks.
    public static func songs(fromUSR text: String) -> [SongRecord] {
        var values: [String: String] = [:]
        var number = ""
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[S "), let digits = trimmed.split(separator: " ").last?.filter(\.isNumber), !digits.isEmpty {
                number = String(digits)
            }
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            values[String(trimmed[..<equals]).lowercased()] = String(trimmed[trimmed.index(after: equals)...])
        }
        guard let title = values["title"], !title.isEmpty else { return [] }
        let fields = (values["fields"] ?? "").components(separatedBy: "/t")
        let words = (values["words"] ?? "").components(separatedBy: "/t")
        var sections: [SongSection] = []
        for (index, lyric) in words.enumerated() {
            let lyrics = lyric.replacingOccurrences(of: "/n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !lyrics.isEmpty else { continue }
            let name = index < fields.count && !fields[index].isEmpty ? fields[index] : "Verse \(index + 1)"
            sections.append(SongSection(name: name, lyrics: lyrics))
        }
        guard !sections.isEmpty else { return [] }
        let authors = (values["author"] ?? "").components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let themes = (values["themes"] ?? "").components(separatedBy: "/t").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return [SongRecord(title: title, artist: authors.joined(separator: ", "), sections: sections,
                           ccliNumber: number, copyright: values["copyright"] ?? "", themes: themes)]
    }

    /// SongSelect's plain-text download: title, sections with headings, then a footer with
    /// "CCLI Song # …", the authors, "© …", and licence lines.
    public static func song(fromSongSelectText text: String) -> SongRecord? {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard let footer = lines.firstIndex(where: { $0.contains("CCLI Song #") || $0.contains("CCLI Song No") }) else { return nil }
        let number = lines[footer].filter(\.isNumber)
        var authors = ""
        var copyright = ""
        for line in lines[(footer + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("For use solely") || trimmed.hasPrefix("CCLI Licen") || trimmed.contains("www.ccli.com") { continue }
            if trimmed.hasPrefix("©") || trimmed.lowercased().hasPrefix("copyright") { copyright = trimmed; continue }
            if authors.isEmpty { authors = trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", ") }
        }
        guard var song = song(fromText: lines[..<footer].joined(separator: "\n")) else { return nil }
        song.ccliNumber = number
        song.copyright = copyright
        if song.artist.isEmpty { song.artist = authors }
        return song
    }
}

/// Reads one OpenLyrics song.
private final class OpenLyricsReader: NSObject, XMLParserDelegate {
    private var path: [String] = []
    private var titles: [String] = []
    private var authors: [String] = []
    private var themes: [String] = []
    private var ccli = ""
    private var copyright = ""
    private var verseOrder = ""
    private var verses: [(name: String, lines: [String])] = []
    private var currentLines: [String]?
    private var currentLine = ""
    private var text = ""
    private var skipDepth = 0

    func song() -> SongRecord? {
        guard let title = titles.first, !verses.isEmpty else { return nil }
        var ordered = verses
        // Keep the verse order given by the song, without repeats.
        let order = verseOrder.split(separator: " ").map(String.init)
        if !order.isEmpty {
            var seen = Set<String>()
            let byName = Dictionary(verses.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            ordered = order.compactMap { name in seen.insert(name).inserted ? byName[name] : nil }
            ordered += verses.filter { !seen.contains($0.name) }
        }
        let sections = ordered.map { SongSection(name: SongImporter.sectionName(code: $0.name), lyrics: $0.lines.joined(separator: "\n")) }
            .filter { !$0.lyrics.isEmpty }
        return SongRecord(title: title, artist: authors.joined(separator: ", "), sections: sections, ccliNumber: ccli, copyright: copyright, themes: themes)
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        path.append(element)
        text = ""
        switch element {
        case "verse": verses.append((attributes["name"] ?? "v\(verses.count + 1)", []))
        case "lines": currentLines = []; currentLine = ""
        case "br":
            if currentLines != nil { currentLines!.append(currentLine.trimmingCharacters(in: .whitespaces)); currentLine = "" }
        case "comment": skipDepth += 1
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch element {
        case "title" where path.contains("titles"): if !value.isEmpty { titles.append(value) }
        case "author": if !value.isEmpty { authors.append(value) }
        case "theme": if !value.isEmpty { themes.append(value) }
        case "ccliNo": ccli = value.filter(\.isNumber)
        case "copyright": copyright = value
        case "verseOrder": verseOrder = value
        case "lines":
            if var lines = currentLines {
                let last = currentLine.trimmingCharacters(in: .whitespaces)
                if !last.isEmpty { lines.append(last) }
                if !verses.isEmpty { verses[verses.count - 1].lines += lines.filter { !$0.isEmpty } }
            }
            currentLines = nil
        case "comment": skipDepth = max(0, skipDepth - 1)
        default: break
        }
        path.removeLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentLines != nil {
            if skipDepth == 0 { currentLine += string.replacingOccurrences(of: "\n", with: " ") }
        } else {
            text += string
        }
    }
}
