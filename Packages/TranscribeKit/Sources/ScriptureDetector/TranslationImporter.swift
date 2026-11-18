import Foundation

/// File formats a licensed translation can be imported from.
public enum TranslationFormat: String, Sendable, CaseIterable {
    case sqlite = "Transcribe SQLite"
    case json = "Transcribe JSON"
    case osis = "OSIS XML"
    case usfm = "USFM"
    case usx = "USX"
    case zefania = "Zefania XML"

    public static let fileExtensions = ["sqlite", "sqlite3", "db", "json", "xml", "osis", "usfm", "sfm", "usx", "txt"]
}

/// A translation read from an import file, checked and ready to install.
public struct ParsedTranslation: Sendable {
    public var format: TranslationFormat
    /// Suggested from the file's own metadata or name; the operator can change them before installing.
    public var abbreviation: String
    public var name: String
    public var license: String
    public var verses: [Verse]
    /// Problems that don't stop the import, e.g. skipped deuterocanonical books.
    public var warnings: [String]

    public var bookCount: Int { Set(verses.map(\.book)).count }
    public var hasOldTestament: Bool { verses.contains { Books.canonicalOrder.firstIndex(of: $0.book).map { $0 < 39 } ?? false } }
    public var hasNewTestament: Bool { verses.contains { Books.canonicalOrder.firstIndex(of: $0.book).map { $0 >= 39 } ?? false } }
}

/// Reads OSIS, USFM, USX, Zefania XML and Transcribe JSON into verses, with errors that say what
/// is wrong and where. Nothing is installed until `install` is called.
public enum TranslationImporter {
    // MARK: Detection

    public static func detectFormat(of url: URL) throws -> TranslationFormat {
        let ext = url.pathExtension.lowercased()
        if url.hasDirectoryPath { return try detectFormat(ofFolder: url) }
        switch ext {
        case "sqlite", "sqlite3", "db": return .sqlite
        case "json": return .json
        case "usfm", "sfm": return .usfm
        case "usx": return .usx
        case "osis": return .osis
        default: break
        }
        let head = try headOfFile(url)
        if head.contains("<osis") { return .osis }
        if head.contains("<XMLBIBLE") || head.contains("<xmlbible") { return .zefania }
        if head.contains("<usx") { return .usx }
        if head.range(of: #"(?m)^\\id\s+[A-Z0-9]{3}"#, options: .regularExpression) != nil { return .usfm }
        if head.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") { return .json }
        throw TranslationError.unrecognizedFormat(url.lastPathComponent)
    }

    private static func detectFormat(ofFolder url: URL) throws -> TranslationFormat {
        let files = folderFiles(url)
        guard let first = files.first else { throw TranslationError.noVerses("the folder has no .usfm, .sfm or .usx files") }
        let format = try detectFormat(of: first)
        guard format == .usfm || format == .usx else { throw TranslationError.unrecognizedFormat(url.lastPathComponent) }
        return format
    }

    static func folderFiles(_ url: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        return files.filter { ["usfm", "sfm", "usx", "txt"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func headOfFile(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 4096) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Parsing

    /// Reads one file, or several files / a folder holding one book each (USFM, USX).
    public static func parse(_ urls: [URL]) throws -> ParsedTranslation {
        guard let first = urls.first else { throw TranslationError.noVerses("no file was chosen") }
        let files = urls.count == 1 && first.hasDirectoryPath ? folderFiles(first) : urls
        let format = try detectFormat(of: first)
        let fallbackName = first.deletingPathExtension().lastPathComponent
        var parsed: ParsedTranslation
        switch format {
        case .sqlite:
            let probe = try BibleTranslation(url: first, isBundled: false)
            var verses: [Verse] = []
            probe.forEachVerse { verses.append($0) }
            parsed = ParsedTranslation(format: .sqlite, abbreviation: probe.info.abbreviation, name: probe.info.name, license: probe.info.license, verses: verses, warnings: [])
        case .json:
            parsed = try parseJSON(Data(contentsOf: first))
        case .osis:
            parsed = try OSISReader.read(first)
        case .zefania:
            parsed = try ZefaniaReader.read(first)
        case .usx:
            parsed = ParsedTranslation(format: .usx, abbreviation: "", name: "", license: "", verses: [], warnings: [])
            for file in files { parsed.verses += try USXReader.read(file, warnings: &parsed.warnings) }
        case .usfm:
            parsed = ParsedTranslation(format: .usfm, abbreviation: "", name: "", license: "", verses: [], warnings: [])
            for file in files {
                let text = try String(contentsOf: file, encoding: .utf8)
                parsed.verses += try USFMReader.read(text, file: file.lastPathComponent, warnings: &parsed.warnings)
            }
        }
        if parsed.abbreviation.isEmpty { parsed.abbreviation = suggestedAbbreviation(fallbackName) }
        if parsed.name.isEmpty { parsed.name = fallbackName }
        try validate(&parsed)
        return parsed
    }

    public static func parse(_ url: URL) throws -> ParsedTranslation { try parse([url]) }

    static func suggestedAbbreviation(_ name: String) -> String {
        let letters = name.uppercased().filter { $0.isLetter || $0.isNumber }
        return String(letters.prefix(6))
    }

    /// Rejects files with no usable verses; removes duplicates and empty verses with a warning.
    static func validate(_ parsed: inout ParsedTranslation) throws {
        var seen = Set<String>()
        var unique: [Verse] = []
        var duplicates = 0, empty = 0, outOfRange = 0
        for verse in parsed.verses {
            let text = verse.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { empty += 1; continue }
            guard verse.chapter > 0, verse.verse > 0 else { outOfRange += 1; continue }
            guard seen.insert("\(verse.book).\(verse.chapter).\(verse.verse)").inserted else { duplicates += 1; continue }
            unique.append(Verse(book: verse.book, chapter: verse.chapter, verse: verse.verse, text: text))
        }
        guard !unique.isEmpty else {
            throw TranslationError.noVerses(parsed.verses.isEmpty
                ? "no verses were found in this \(parsed.format.rawValue) file"
                : "every verse in the file was empty")
        }
        if duplicates > 0 { parsed.warnings.append("\(duplicates) repeated verses were ignored.") }
        if empty > 0 { parsed.warnings.append("\(empty) empty verses were skipped.") }
        if outOfRange > 0 { parsed.warnings.append("\(outOfRange) verses with a chapter or verse number of 0 were skipped.") }
        let extra = unique.filter { !BibleReference(book: $0.book, chapter: $0.chapter, verseStart: $0.verse).isValid }.count
        if extra > 0 { parsed.warnings.append("\(extra) verses fall outside the usual verse numbering; they're kept but may not be found by reference.") }
        parsed.verses = unique
    }

    // MARK: Installing

    /// Writes the translation as SQLite in `directory`. Returns the installed file.
    @discardableResult
    public static func install(_ parsed: ParsedTranslation, abbreviation: String, name: String, license: String, into directory: URL, existingIDs: Set<String>) throws -> URL {
        let abbreviation = abbreviation.trimmingCharacters(in: .whitespaces)
        guard !abbreviation.isEmpty, abbreviation.count <= 12 else { throw TranslationError.invalidSchema("the abbreviation must be 1 to 12 characters") }
        let id = abbreviation.lowercased().filter { $0.isLetter || $0.isNumber }
        guard !id.isEmpty else { throw TranslationError.invalidSchema("the abbreviation needs at least one letter or digit") }
        guard !existingIDs.contains(id) else { throw TranslationError.duplicate(abbreviation) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(id).sqlite")
        try TranslationLibrary.writeSQLite(
            meta: ["id": id, "abbreviation": abbreviation, "name": name.isEmpty ? abbreviation : name,
                   "license": license.isEmpty ? "Imported by the user" : license, "schema_version": "1",
                   "source_format": parsed.format.rawValue],
            verses: parsed.verses, to: destination
        )
        return destination
    }

    // MARK: JSON

    static func parseJSON(_ data: Data) throws -> ParsedTranslation {
        let document: TranslationLibrary.JSONTranslation
        do {
            document = try JSONDecoder().decode(TranslationLibrary.JSONTranslation.self, from: data)
        } catch let DecodingError.keyNotFound(key, context) {
            throw TranslationError.invalidJSON("the “\(key.stringValue)” field is missing\(path(context))")
        } catch let DecodingError.typeMismatch(_, context) {
            throw TranslationError.invalidJSON("a value has the wrong type\(path(context))")
        } catch let DecodingError.dataCorrupted(context) {
            throw TranslationError.invalidJSON(context.debugDescription)
        } catch {
            throw TranslationError.invalidJSON(error.localizedDescription)
        }
        var verses: [Verse] = []
        var unknown = Set<String>()
        for entry in document.verses {
            guard let book = bookID(entry.book) else { unknown.insert(entry.book); continue }
            verses.append(Verse(book: book, chapter: entry.chapter, verse: entry.verse, text: entry.text))
        }
        var warnings: [String] = []
        if !unknown.isEmpty {
            if verses.isEmpty { throw TranslationError.unknownBooks(unknown.sorted()) }
            warnings.append("Skipped unrecognized books: \(unknown.sorted().prefix(6).joined(separator: ", ")).")
        }
        return ParsedTranslation(format: .json, abbreviation: document.abbreviation, name: document.name, license: document.license ?? "", verses: verses, warnings: warnings)
    }

    private static func path(_ context: DecodingError.Context) -> String {
        let keys = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
        return keys.isEmpty ? "" : " at \(keys.hasPrefix(".") ? String(keys.dropFirst()) : keys)"
    }

    /// A USFM code ("JHN"), OSIS id ("John", "1Cor"), or book name ("1 Corinthians").
    static func bookID(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if let book = Books.book(trimmed.uppercased()) { return book.id }
        if let id = osisBooks[trimmed] { return id }
        return Books.resolve(name: trimmed)
    }

    // MARK: Book codes

    static let osisOrder = ("Gen Exod Lev Num Deut Josh Judg Ruth 1Sam 2Sam 1Kgs 2Kgs 1Chr 2Chr Ezra Neh Esth Job Ps Prov Eccl Song "
        + "Isa Jer Lam Ezek Dan Hos Joel Amos Obad Jonah Mic Nah Hab Zeph Hag Zech Mal Matt Mark Luke John Acts Rom 1Cor 2Cor "
        + "Gal Eph Phil Col 1Thess 2Thess 1Tim 2Tim Titus Phlm Heb Jas 1Pet 2Pet 1John 2John 3John Jude Rev").split(separator: " ").map(String.init)
    static let osisBooks: [String: String] = Dictionary(uniqueKeysWithValues: zip(osisOrder, Books.canonicalOrder))

    /// Books outside the 66-book canon (deuterocanon, front matter), skipped with a warning.
    static let nonCanonical: Set<String> = ["TOB", "JDT", "ESG", "WIS", "SIR", "BAR", "LJE", "S3Y", "SUS", "BEL", "1MA", "2MA", "3MA", "4MA",
        "1ES", "2ES", "MAN", "PS2", "ODA", "PSS", "DAG", "FRT", "BAK", "OTH", "INT", "CNC", "GLO", "TDX", "NDX", "XXA", "XXB", "XXC", "XXD", "XXE", "XXF", "XXG",
        "Tob", "Jdt", "EsthGr", "AddEsth", "Wis", "Sir", "Bar", "EpJer", "PrAzar", "Sus", "Bel", "1Macc", "2Macc", "3Macc", "4Macc", "1Esd", "2Esd", "PrMan", "AddPs"]
}

// MARK: - USFM

enum USFMReader {
    /// Paragraph markers whose line is a heading or introduction, not verse text.
    static let skippedLines: Set<String> = ["h", "toc", "toca", "mt", "mte", "ms", "mr", "s", "sr", "r", "d", "sp", "sd", "cl", "cd", "ide", "rem",
        "sts", "imt", "imte", "is", "ip", "ipi", "im", "imi", "ipq", "imq", "ipr", "iq", "ib", "ili", "iot", "io", "ior", "iex", "ie", "lit", "restore", "usfm"]
    static let markerPattern = try! NSRegularExpression(pattern: #"\\(\+?)([a-z]+[0-9]*)(\*?)"#)
    static let notePattern = try! NSRegularExpression(pattern: #"\\(f|fe|x|ef|ex|fig)\s.*?\\\1\*"#, options: [.dotMatchesLineSeparators])
    static let attributePattern = try! NSRegularExpression(pattern: #"\|[^\\|]*(?=\\\+?[a-z]+\*)"#)

    static func read(_ raw: String, file: String, warnings: inout [String]) throws -> [Verse] {
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        text = notePattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        text = attributePattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")

        var verses: [Verse] = []
        var book: String?
        var skippingBook = false
        var chapter = 0
        var current: (verse: Int, text: String)?
        var sawID = false

        func finish() {
            if let current, let book, chapter > 0 {
                verses.append(Verse(book: book, chapter: chapter, verse: current.verse, text: collapse(current.text)))
            }
            current = nil
        }

        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("\\id ") || trimmed == "\\id" {
                finish()
                sawID = true
                let code = String(trimmed.dropFirst(4).prefix(3)).uppercased()
                chapter = 0
                if let known = Books.book(code)?.id {
                    book = known
                    skippingBook = false
                } else if TranslationImporter.nonCanonical.contains(code) {
                    book = nil
                    skippingBook = true
                    warnings.append("Skipped \(code) in \(file) (not in the 66-book canon).")
                } else {
                    throw TranslationError.malformed(format: "USFM", location: "\(file), line \(index + 1)", detail: "unknown book code “\(code)” after \\id")
                }
                continue
            }
            if skippingBook { continue }
            if let leading = leadingMarker(trimmed), skippedLines.contains(leading) { continue }

            func consume(_ segment: String, pending: inout String?) {
                var segment = segment
                if let marker = pending {
                    pending = nil
                    let scanner = segment.trimmingCharacters(in: .whitespaces)
                    let digits = scanner.prefix { $0.isNumber }
                    guard let number = Int(digits) else { return }
                    // Skip "16-17" (bridged verses) and "16a" suffixes after the number.
                    var rest = scanner.dropFirst(digits.count)
                    while let c = rest.first, !c.isWhitespace { rest = rest.dropFirst() }
                    segment = String(rest)
                    if marker == "c" {
                        finish()
                        chapter = number
                    } else {
                        guard book != nil else { return }
                        finish()
                        current = (number, "")
                    }
                }
                if current != nil { current!.text += segment }
            }

            let ns = trimmed as NSString
            var position = 0
            var pendingNumber: String?   // "c" or "v": the next text starts with its number
            for match in markerPattern.matches(in: trimmed, range: NSRange(location: 0, length: ns.length)) {
                let segment = ns.substring(with: NSRange(location: position, length: match.range.location - position))
                consume(segment, pending: &pendingNumber)
                position = NSMaxRange(match.range)
                let name = ns.substring(with: match.range(at: 2))
                let closing = match.range(at: 3).length > 0
                if !closing && (name == "c" || name == "v") { pendingNumber = name }
            }
            consume(ns.substring(from: position), pending: &pendingNumber)
            if current != nil { current!.text += " " }

        }
        finish()
        if !sawID { throw TranslationError.malformed(format: "USFM", location: file, detail: "there is no \\id line naming the book") }
        return verses
    }

    private static func leadingMarker(_ line: String) -> String? {
        guard line.hasPrefix("\\") else { return nil }
        let name = line.dropFirst().prefix { $0.isLetter }
        return name.isEmpty ? nil : String(name)
    }
}

func collapse(_ text: String) -> String {
    text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        .replacingOccurrences(of: " ,", with: ",").replacingOccurrences(of: " .", with: ".")
        .replacingOccurrences(of: " ;", with: ";").replacingOccurrences(of: " :", with: ":")
        .trimmingCharacters(in: .whitespaces)
}

// MARK: - XML readers

/// Shared plumbing for the SAX readers: errors with line numbers, and a text buffer.
class XMLVerseReader: NSObject, XMLParserDelegate {
    var verses: [Verse] = []
    var warnings: [String] = []
    var failure: TranslationError?
    let formatName: String
    let file: String

    init(formatName: String, file: String) {
        self.formatName = formatName
        self.file = file
    }

    func run(_ url: URL) throws {
        guard let parser = XMLParser(contentsOf: url) else { throw TranslationError.cannotOpen(url.lastPathComponent) }
        parser.delegate = self
        parser.shouldResolveExternalEntities = false
        if !parser.parse() {
            if let failure { throw failure }
            let error = parser.parserError.map { ($0 as NSError).localizedDescription } ?? "unknown error"
            throw TranslationError.malformed(format: formatName, location: "\(file), line \(parser.lineNumber)", detail: "the XML couldn't be read (\(error))")
        }
        if let failure { throw failure }
    }

    func fail(_ parser: XMLParser, _ detail: String) {
        failure = .malformed(format: formatName, location: "\(file), line \(parser.lineNumber)", detail: detail)
        parser.abortParsing()
    }
}

final class OSISReader: XMLVerseReader {
    private var abbreviation = ""
    private var name = ""
    private var license = ""
    private var inHeader = false
    private var headerField: String?
    private var skipDepth = 0
    private var current: (book: String, chapter: Int, verse: Int, text: String, milestone: Bool)?
    private var skippedBooks = Set<String>()
    private var unknownBooks = Set<String>()

    static func read(_ url: URL) throws -> ParsedTranslation {
        let reader = OSISReader(formatName: "OSIS", file: url.lastPathComponent)
        try reader.run(url)
        if !reader.skippedBooks.isEmpty { reader.warnings.append("Skipped books outside the 66-book canon: \(reader.skippedBooks.sorted().joined(separator: ", ")).") }
        if !reader.unknownBooks.isEmpty {
            if reader.verses.isEmpty { throw TranslationError.unknownBooks(reader.unknownBooks.sorted()) }
            reader.warnings.append("Skipped unrecognized books: \(reader.unknownBooks.sorted().prefix(6).joined(separator: ", ")).")
        }
        return ParsedTranslation(format: .osis, abbreviation: reader.abbreviation, name: reader.name, license: reader.license, verses: reader.verses, warnings: reader.warnings)
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        switch element {
        case "osisText":
            if let work = attributes["osisIDWork"], abbreviation.isEmpty { abbreviation = work }
        case "header": inHeader = true
        // Each pattern needs its own `where`: a single trailing one guards only "description",
        // which let body titles (headings, psalm titles) through into the verse text.
        case "title" where inHeader, "rights" where inHeader, "description" where inHeader:
            headerField = element
        case "note", "title":
            skipDepth += 1
        case "verse":
            if attributes["eID"] != nil {
                finish()
            } else if let id = (attributes["sID"] != nil ? attributes["osisID"] ?? attributes["sID"] : attributes["osisID"]) {
                finish()
                begin(id.split(separator: " ").first.map(String.init) ?? id, milestone: attributes["sID"] != nil, parser: parser)
            }
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        switch element {
        case "header": inHeader = false
        case "title" where inHeader, "rights" where inHeader, "description" where inHeader:
            headerField = nil
        case "note", "title":
            skipDepth = max(0, skipDepth - 1)
        case "verse":
            if let current, !current.milestone { finish() }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inHeader, let field = headerField {
            let value = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            switch field {
            case "title" where name.isEmpty: name = value
            case "rights" where license.isEmpty: license = value
            default: break
            }
            return
        }
        if skipDepth == 0, current != nil { current!.text += string }
    }

    private func begin(_ osisID: String, milestone: Bool, parser: XMLParser) {
        let parts = osisID.split(separator: ".")
        guard parts.count >= 3 else { fail(parser, "the verse id “\(osisID)” should look like John.3.16"); return }
        let code = String(parts[0])
        guard let book = TranslationImporter.osisBooks[code] ?? Books.book(code.uppercased())?.id else {
            if TranslationImporter.nonCanonical.contains(code) { skippedBooks.insert(code) } else { unknownBooks.insert(code) }
            return
        }
        guard let chapter = Int(parts[1]), let verse = Int(parts[2]) else { fail(parser, "the verse id “\(osisID)” has no chapter or verse number"); return }
        current = (book, chapter, verse, "", milestone)
    }

    private func finish() {
        if let current { verses.append(Verse(book: current.book, chapter: current.chapter, verse: current.verse, text: collapse(current.text))) }
        current = nil
    }
}

final class USXReader: XMLVerseReader {
    private var book: String?
    private var skippingBook = false
    private var chapter = 0
    private var current: (verse: Int, text: String)?
    private var skipDepth = 0
    private var inBookElement = false
    private var sawBook = false

    static func read(_ url: URL, warnings: inout [String]) throws -> [Verse] {
        let reader = USXReader(formatName: "USX", file: url.lastPathComponent)
        try reader.run(url)
        if !reader.sawBook { throw TranslationError.malformed(format: "USX", location: url.lastPathComponent, detail: "there is no <book code=\"…\"> element") }
        warnings += reader.warnings
        return reader.verses
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        switch element {
        case "book":
            finish()
            sawBook = true
            inBookElement = true
            let code = (attributes["code"] ?? "").uppercased()
            if let known = Books.book(code)?.id {
                book = known
                skippingBook = false
            } else if TranslationImporter.nonCanonical.contains(code) {
                book = nil
                skippingBook = true
                warnings.append("Skipped \(code) in \(file) (not in the 66-book canon).")
            } else {
                fail(parser, "unknown book code “\(code)”")
            }
        case "chapter":
            if let number = attributes["number"].flatMap({ Int($0) }) {
                finish()
                chapter = number
            } else if attributes["eid"] != nil {
                finish()
            }
        case "verse":
            if attributes["eid"] != nil {
                finish()
            } else if let raw = attributes["number"] {
                finish()
                guard let number = Int(raw.prefix { $0.isNumber }) else { fail(parser, "the verse number “\(raw)” isn't a number"); return }
                if !skippingBook, book != nil { current = (number, "") }
            }
        case "para":
            let style = (attributes["style"] ?? "").trimmingCharacters(in: .decimalDigits)
            if USFMReader.skippedLines.contains(style) { skipDepth += 1; paraSkipStack += 1 } else if current != nil { current!.text += " " }
        case "note", "figure", "sidebar":
            skipDepth += 1
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        switch element {
        case "book": inBookElement = false
        case "para":
            // Only paragraphs that were skipped on the way in are counted.
            if paraSkipStack > 0 { skipDepth = max(0, skipDepth - 1); paraSkipStack -= 1 }
        case "note", "figure", "sidebar":
            skipDepth = max(0, skipDepth - 1)
        default: break
        }
    }

    private var paraSkipStack = 0

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !inBookElement, skipDepth == 0, current != nil else { return }
        current!.text += string
    }

    private func finish() {
        if let current, let book, chapter > 0 {
            verses.append(Verse(book: book, chapter: chapter, verse: current.verse, text: collapse(current.text)))
        }
        current = nil
    }
}

final class ZefaniaReader: XMLVerseReader {
    private var name = ""
    private var abbreviation = ""
    private var license = ""
    private var infoField: String?
    private var book: String?
    private var chapter = 0
    private var current: (verse: Int, text: String)?
    private var skipDepth = 0
    private var skippedBooks = 0

    static func read(_ url: URL) throws -> ParsedTranslation {
        let reader = ZefaniaReader(formatName: "Zefania XML", file: url.lastPathComponent)
        try reader.run(url)
        if reader.skippedBooks > 0 { reader.warnings.append("Skipped \(reader.skippedBooks) books outside the 66-book canon.") }
        return ParsedTranslation(format: .zefania, abbreviation: reader.abbreviation, name: reader.name, license: reader.license, verses: reader.verses, warnings: reader.warnings)
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        switch element.uppercased() {
        case "XMLBIBLE":
            if let value = attributes["biblename"] { name = value }
        case "TITLE", "IDENTIFIER", "RIGHTS":
            infoField = element.uppercased()
        case "BIBLEBOOK":
            let number = attributes["bnumber"].flatMap { Int($0) }
            if let number, (1...66).contains(number) {
                book = Books.canonicalOrder[number - 1]
            } else if let number, number > 66 {
                book = nil
                skippedBooks += 1
            } else if let resolved = (attributes["bname"] ?? attributes["bsname"]).flatMap(TranslationImporter.bookID) {
                book = resolved
            } else {
                fail(parser, "a BIBLEBOOK has no usable bnumber or bname")
            }
        case "CHAPTER":
            guard let number = attributes["cnumber"].flatMap({ Int($0) }) else { fail(parser, "a CHAPTER has no cnumber"); return }
            chapter = number
        case "VERS":
            guard let number = attributes["vnumber"].flatMap({ Int($0.prefix { $0.isNumber }) }) else { fail(parser, "a VERS has no vnumber"); return }
            current = book == nil ? nil : (number, "")
        case "NOTE", "DIV", "XREF", "MEDIA":
            skipDepth += 1
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        switch element.uppercased() {
        case "TITLE", "IDENTIFIER", "RIGHTS": infoField = nil
        case "VERS":
            if let current, let book, chapter > 0 {
                verses.append(Verse(book: book, chapter: chapter, verse: current.verse, text: collapse(current.text)))
            }
            current = nil
        case "NOTE", "DIV", "XREF", "MEDIA":
            skipDepth = max(0, skipDepth - 1)
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if let field = infoField {
            let value = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            switch field {
            case "TITLE" where name.isEmpty: name = value
            case "IDENTIFIER" where abbreviation.isEmpty: abbreviation = value.uppercased()
            case "RIGHTS" where license.isEmpty: license = value
            default: break
            }
            return
        }
        if skipDepth == 0, current != nil { current!.text += string }
    }
}
