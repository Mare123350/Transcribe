import Foundation
import SongMatcher
import SwiftData

/// A song in the library. Lyrics are stored as JSON so sections keep their order.
@Model
final class StoredSong {
    var id: UUID = UUID()
    var title: String = ""
    var artist: String = ""
    var sectionsData: Data?
    var isBundled: Bool = false
    var addedAt: Date = Date()
    var ccliNumber: String = ""
    var copyright: String = ""
    /// Themes, comma-separated: "Grace, Easter".
    var themesRaw: String = ""
    var isFavorite: Bool = false
    var lastUsed: Date?

    init(record: SongRecord, isBundled: Bool = false) {
        self.id = record.id
        self.title = record.title
        self.artist = record.artist
        self.isBundled = isBundled
        self.ccliNumber = record.ccliNumber
        self.copyright = record.copyright
        self.themesRaw = record.themes.joined(separator: ", ")
        self.sections = record.sections
    }

    var themes: [String] {
        get { themesRaw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        set { themesRaw = newValue.joined(separator: ", ") }
    }

    var sections: [SongSection] {
        get { sectionsData.flatMap { try? JSONDecoder().decode([SongSection].self, from: $0) } ?? [] }
        set { sectionsData = try? JSONEncoder().encode(newValue) }
    }

    /// "© 2004 sixsteps Music · CCLI 4348399", for lyric slides.
    var copyrightLine: String {
        [copyright, ccliNumber.isEmpty ? "" : "CCLI \(ccliNumber)"].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var record: SongRecord {
        SongRecord(id: id, title: title, artist: artist, sections: sections, ccliNumber: ccliNumber, copyright: copyright, themes: themes)
    }
}
