import Foundation
import ScriptureDetector
import SongMatcher
import SwiftData

enum ItemKind: String, Codable, CaseIterable {
    case segment, header, song, verse
}

/// How sure a detection is, and whether the operator has looked at it.
enum DetectionStatus: String, Codable {
    case detected, confirmed
}

enum VerseSource: String, Codable {
    /// "John 3:16" was said aloud.
    case reference
    /// The verse was quoted without a reference.
    case quote
    /// The operator added it with ⌘B.
    case manual
}

/// One block in a transcript. Segments, headers, songs, and verse callouts share one model so
/// they can be ordered together by `sortIndex`.
@Model
final class TranscriptItem {
    var id: UUID = UUID()
    var sortIndex: Double = 0
    var kindRaw: String = ItemKind.segment.rawValue
    /// Seconds into the recording.
    var timestamp: TimeInterval = 0
    var endTimestamp: TimeInterval = 0
    var createdAt: Date = Date()

    /// Segment: the transcribed words. Song: unused. Verse: unused (see verseText/spokenText).
    var text: String = ""

    // Header
    var title: String = ""
    var subtitle: String = ""
    var sectionTypeRaw: String = ""
    var isAutomatic: Bool = false
    var isUserEdited: Bool = false

    // Song
    var songID: UUID?
    var artist: String = ""
    var lyricsData: Data?
    /// Segment: the song or verse callout this text was folded into (sung lyrics, a passage read
    /// aloud). Shown under that block, not in the main flow.
    @Attribute(originalName: "songItemID") var parentItemID: UUID?

    // Verse
    var reference: String = ""
    var referenceKey: String = ""
    var versionAbbreviation: String = ""
    var verseText: String = ""
    var spokenText: String = ""
    var verseSourceRaw: String = ""
    var versionNamedBySpeaker: Bool = false
    var versionScoresData: Data?
    /// How sure the parser is that this reference was meant (separate from the version score).
    var referenceConfidence: Double = 1
    var referenceNote: String = ""
    var alternativesData: Data?
    /// True once enough of the passage was heard to settle the version.
    var versionSettled: Bool = false

    // Detections (songs and verses)
    var confidence: Double = 0
    var statusRaw: String = DetectionStatus.detected.rawValue

    var session: Session?

    init(kind: ItemKind, sortIndex: Double, timestamp: TimeInterval) {
        self.kindRaw = kind.rawValue
        self.sortIndex = sortIndex
        self.timestamp = timestamp
        self.endTimestamp = timestamp
    }

    var kind: ItemKind { ItemKind(rawValue: kindRaw) ?? .segment }

    var status: DetectionStatus {
        get { DetectionStatus(rawValue: statusRaw) ?? .detected }
        set { statusRaw = newValue.rawValue }
    }

    var verseSource: VerseSource? {
        get { VerseSource(rawValue: verseSourceRaw) }
        set { verseSourceRaw = newValue?.rawValue ?? "" }
    }

    var sectionType: ServiceSection? {
        get { ServiceSection(rawValue: sectionTypeRaw) }
        set { sectionTypeRaw = newValue?.rawValue ?? "" }
    }

    /// Song sections inserted in place of the sung transcription, in the order they were sung.
    var lyricSections: [SongSection] {
        get { lyricsData.flatMap { try? JSONDecoder().decode([SongSection].self, from: $0) } ?? [] }
        set { lyricsData = try? JSONEncoder().encode(newValue) }
    }

    var alternatives: [BibleReference] {
        get { alternativesData.flatMap { try? JSONDecoder().decode([BibleReference].self, from: $0) } ?? [] }
        set { alternativesData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
    }

    var bibleReference: BibleReference? {
        // referenceKey looks like "JHN.3.16-18" or "PSA.23".
        let parts = referenceKey.split(separator: ".")
        guard parts.count >= 2, let chapter = Int(parts[1]) else { return nil }
        guard parts.count == 3 else { return BibleReference(book: String(parts[0]), chapter: chapter) }
        let verses = parts[2].split(separator: "-").compactMap { Int($0) }
        return BibleReference(book: String(parts[0]), chapter: chapter, verseStart: verses.first, verseEnd: verses.last)
    }

    var versionScores: [VersionScoreValue] {
        get { versionScoresData.flatMap { try? JSONDecoder().decode([VersionScoreValue].self, from: $0) } ?? [] }
        set { versionScoresData = try? JSONEncoder().encode(newValue) }
    }
}

struct VersionScoreValue: Codable, Hashable {
    var abbreviation: String
    var score: Double
}

/// Parts of a church service, used for automatic headers.
enum ServiceSection: String, Codable, CaseIterable, Identifiable {
    case welcome, worship, prayer, announcements, scriptureReading, sermon, offering, altarCall, closing, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .worship: "Worship"
        case .prayer: "Prayer"
        case .announcements: "Announcements"
        case .scriptureReading: "Scripture Reading"
        case .sermon: "Sermon"
        case .offering: "Offering"
        case .altarCall: "Altar Call"
        case .closing: "Closing"
        case .other: "Section"
        }
    }

    var symbol: String {
        switch self {
        case .welcome: "hand.wave"
        case .worship: "music.note"
        case .prayer: "hands.clap"
        case .announcements: "megaphone"
        case .scriptureReading: "book"
        case .sermon: "text.bubble"
        case .offering: "gift"
        case .altarCall: "heart"
        case .closing: "door.left.hand.open"
        case .other: "number"
        }
    }
}
