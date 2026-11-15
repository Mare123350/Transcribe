import Foundation

public struct SongSection: Codable, Hashable, Sendable {
    /// "Verse 1", "Chorus", "Bridge"…
    public var name: String
    public var lyrics: String

    public init(name: String, lyrics: String) {
        self.name = name
        self.lyrics = lyrics
    }
}

public struct SongRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var artist: String
    public var sections: [SongSection]
    /// CCLI song number, if known.
    public var ccliNumber: String
    public var copyright: String
    /// Themes from the source (OpenLyrics, SongSelect) or added by the operator: "Grace", "Easter".
    public var themes: [String]

    public init(id: UUID = UUID(), title: String, artist: String = "", sections: [SongSection], ccliNumber: String = "", copyright: String = "", themes: [String] = []) {
        self.id = id
        self.title = title
        self.artist = artist
        self.sections = sections
        self.ccliNumber = ccliNumber
        self.copyright = copyright
        self.themes = themes
    }

    enum CodingKeys: String, CodingKey { case id, title, artist, sections, ccliNumber, copyright, themes }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decode(String.self, forKey: .title)
        artist = try container.decodeIfPresent(String.self, forKey: .artist) ?? ""
        sections = try container.decodeIfPresent([SongSection].self, forKey: .sections) ?? []
        ccliNumber = try container.decodeIfPresent(String.self, forKey: .ccliNumber) ?? ""
        copyright = try container.decodeIfPresent(String.self, forKey: .copyright) ?? ""
        themes = try container.decodeIfPresent([String].self, forKey: .themes) ?? []
    }
}
