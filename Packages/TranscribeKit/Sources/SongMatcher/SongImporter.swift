import Foundation

public enum SongImportError: LocalizedError, Sendable {
    case unreadable
    case noSongs
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .malformed(let detail): "The song file has a problem: \(detail)."
        case .unreadable: "The file couldn't be read as text."
        case .noSongs: "No songs were found in the file. See docs/SONG_FORMAT.md for the expected layout."
        }
    }
}

/// Reads songs from JSON or plain text.
///
/// JSON: one song `{"title", "artist", "sections": [{"name", "lyrics"}]}`, an array of songs,
/// or `{"songs": [...]}`.
///
/// Text: the first line is the title; an optional `Artist:` line follows. Section headings like
/// `[Verse 1]`, `Chorus:`, or `BRIDGE` start sections. Without headings, blank lines separate
/// sections, and a block that repeats is treated as the chorus. Separate songs with a `---` line.
public enum SongImporter {
    /// Reads any supported format: JSON, plain text, ChordPro, OpenLyrics, or CCLI SongSelect.
    public static func songs(from url: URL) throws -> [SongRecord] {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) ?? String(data: data, encoding: .isoLatin1) else {
            throw SongImportError.unreadable
        }
        let found: [SongRecord]
        switch SongFileFormat.detect(extension: url.pathExtension, text: text) {
        case .json: return try Self.songs(fromJSON: data)
        case .openLyrics: return try Self.songs(fromOpenLyrics: data)
        case .chordPro: found = Self.songs(fromChordPro: text)
        case .songSelectUSR: found = Self.songs(fromUSR: text)
        case .songSelectText: found = Self.song(fromSongSelectText: text).map { [$0] } ?? []
        case .text: found = Self.songs(fromText: text)
        }
        guard !found.isEmpty else { throw SongImportError.noSongs }
        return found
    }

    public static func format(of url: URL) -> SongFileFormat? {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        return SongFileFormat.detect(extension: url.pathExtension, text: text)
    }

    public static func songs(fromJSON data: Data) throws -> [SongRecord] {
        struct Wrapper: Decodable { let songs: [SongRecord] }
        let decoder = JSONDecoder()
        let songs = (try? decoder.decode([SongRecord].self, from: data))
            ?? (try? decoder.decode(Wrapper.self, from: data).songs)
            ?? (try? [decoder.decode(SongRecord.self, from: data)])
        guard let songs, !songs.isEmpty else { throw SongImportError.noSongs }
        return songs.filter { !$0.title.isEmpty && !$0.sections.isEmpty }
    }

    public static func json(for songs: [SongRecord]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(songs)
    }

    private static let headingPattern = try! NSRegularExpression(
        pattern: #"^\[?\s*(verse|chorus|refrain|bridge|pre[- ]?chorus|tag|intro|outro|ending|interlude|hook|vamp|coda)\s*(\d+)?\s*\]?\s*:?\s*$"#,
        options: [.caseInsensitive]
    )

    public static func songs(fromText text: String) -> [SongRecord] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var chunks: [String] = []
        var current: [String] = []
        for line in normalized.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).allSatisfy({ $0 == "-" }) && line.trimmingCharacters(in: .whitespaces).count >= 3 {
                chunks.append(current.joined(separator: "\n"))
                current = []
            } else {
                current.append(line)
            }
        }
        chunks.append(current.joined(separator: "\n"))
        return chunks.compactMap(song(fromText:))
    }

    static func song(fromText text: String) -> SongRecord? {
        var lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        guard var title = lines.first, !title.isEmpty else { return nil }
        lines.removeFirst()
        if title.lowercased().hasPrefix("title:") { title = String(title.dropFirst(6)).trimmingCharacters(in: .whitespaces) }

        var artist = ""
        while let line = lines.first, line.isEmpty || line.lowercased().hasPrefix("artist:") || line.lowercased().hasPrefix("by ") {
            lines.removeFirst()
            if line.lowercased().hasPrefix("artist:") { artist = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            else if line.lowercased().hasPrefix("by ") { artist = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
        }

        var sections: [SongSection] = []
        var name: String?
        var body: [String] = []
        var usedHeadings = false

        func flush() {
            let lyrics = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !lyrics.isEmpty { sections.append(SongSection(name: name ?? "", lyrics: lyrics)) }
            body = []
        }

        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            if let match = headingPattern.firstMatch(in: line, range: range) {
                flush()
                usedHeadings = true
                let kind = (line as NSString).substring(with: match.range(at: 1))
                let number = match.range(at: 2).location != NSNotFound ? " " + (line as NSString).substring(with: match.range(at: 2)) : ""
                name = kind.prefix(1).uppercased() + kind.dropFirst().lowercased() + number
            } else if line.isEmpty && !usedHeadings {
                flush()
                name = nil
            } else if !line.isEmpty || !body.isEmpty {
                body.append(line)
            }
        }
        flush()
        guard !sections.isEmpty else { return nil }

        if !usedHeadings {
            // Name blocks: a block that appears more than once is the chorus; the rest are verses.
            var counts: [String: Int] = [:]
            for section in sections { counts[section.lyrics.lowercased(), default: 0] += 1 }
            var verse = 0
            var unique: [SongSection] = []
            for section in sections {
                let isChorus = counts[section.lyrics.lowercased(), default: 0] > 1
                if isChorus {
                    if !unique.contains(where: { $0.name == "Chorus" }) { unique.append(SongSection(name: "Chorus", lyrics: section.lyrics)) }
                } else {
                    verse += 1
                    unique.append(SongSection(name: "Verse \(verse)", lyrics: section.lyrics))
                }
            }
            sections = unique
        } else {
            sections = sections.enumerated().map { index, section in
                SongSection(name: section.name.isEmpty ? "Verse \(index + 1)" : section.name, lyrics: section.lyrics)
            }
        }
        return SongRecord(title: title, artist: artist, sections: sections)
    }
}
