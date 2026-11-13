import Foundation

/// Turns a stream of per-window matches into song start, section, and end events.
///
/// - A song starts when one window matches strongly (≥ 0.75), or two windows in a row pass the
///   start threshold.
/// - It continues while matches stay above a lower threshold, so a few messy lines don't end it.
/// - It ends after `endAfter` seconds (default 15) without a good match.
public struct SongTracker: Sendable {
    public enum Event: Sendable, Equatable {
        case started(SongMatch)
        case sectionChanged(SongMatch)
        case ended(songID: UUID)
    }

    public var startThreshold: Double
    public var strongThreshold: Double
    public var continueThreshold: Double
    public var endAfter: TimeInterval

    public private(set) var current: SongMatch?
    private var lastGoodMatch: TimeInterval = 0
    private var pending: SongMatch?
    private var suppressed: [UUID: TimeInterval] = [:]

    public init(startThreshold: Double = 0.55, strongThreshold: Double = 0.75, continueThreshold: Double = 0.35, endAfter: TimeInterval = 15) {
        self.startThreshold = startThreshold
        self.strongThreshold = strongThreshold
        self.continueThreshold = continueThreshold
        self.endAfter = endAfter
    }

    public mutating func update(_ match: SongMatch?, at time: TimeInterval) -> [Event] {
        suppressed = suppressed.filter { $0.value > time }

        if let current {
            if let match, match.songID == current.songID, match.confidence >= continueThreshold {
                lastGoodMatch = time
                let changed = match.sectionIndex != current.sectionIndex && match.confidence >= startThreshold
                self.current = changed ? match : SongMatch(songID: current.songID, title: current.title, sectionIndex: current.sectionIndex, sectionName: current.sectionName, confidence: max(current.confidence * 0.7, match.confidence))
                pending = nil
                return changed ? [.sectionChanged(match)] : []
            }
            // A different song, sung clearly, replaces the current one straight away.
            if let match, match.songID != current.songID, match.confidence >= strongThreshold, suppressed[match.songID] == nil {
                self.current = match
                lastGoodMatch = time
                pending = nil
                return [.ended(songID: current.songID), .started(match)]
            }
            return tick(at: time)
        }

        guard let match, match.confidence >= startThreshold, suppressed[match.songID] == nil else {
            pending = nil
            return []
        }
        if match.confidence >= strongThreshold || pending?.songID == match.songID {
            current = match
            lastGoodMatch = time
            pending = nil
            return [.started(match)]
        }
        pending = match
        return []
    }

    /// Call periodically (e.g. every second) so a song can end even when nothing is transcribed.
    public mutating func tick(at time: TimeInterval) -> [Event] {
        guard let current, time - lastGoodMatch > endAfter else { return [] }
        self.current = nil
        pending = nil
        return [.ended(songID: current.songID)]
    }

    /// The operator dismissed or replaced a detection: stop tracking it and don't re-detect it for a while.
    public mutating func dismiss(_ songID: UUID, at time: TimeInterval, for duration: TimeInterval = 180) {
        suppressed[songID] = time + duration
        if current?.songID == songID { current = nil }
        if pending?.songID == songID { pending = nil }
    }

    /// The operator picked the song by hand.
    public mutating func force(_ match: SongMatch, at time: TimeInterval) {
        suppressed[match.songID] = nil
        current = match
        lastGoodMatch = time
        pending = nil
    }

    public mutating func reset() {
        current = nil
        pending = nil
        suppressed.removeAll()
    }
}
