import Foundation

/// Splits a passage into slides that fit on screen: whole verses where possible, a long verse at
/// sentence or clause breaks, never mid-word.
public enum SlideSplitter {
    /// - Parameters:
    ///   - units: the passage in reading order, usually one string per verse (with its number).
    ///   - maxWords: the most words a slide should hold.
    public static func split(_ units: [String], maxWords: Int) -> [String] {
        let limit = max(8, maxWords)
        var slides: [String] = []
        var current: [String] = []
        var count = 0
        func flush() {
            if !current.isEmpty { slides.append(current.joined(separator: " ")) }
            current = []
            count = 0
        }
        for unit in units.flatMap({ pieces(of: $0, limit: limit) }) {
            let words = wordCount(unit)
            if count > 0 && count + words > limit { flush() }
            current.append(unit)
            count += words
        }
        flush()
        // Avoid a final slide with a word or two on its own.
        if slides.count >= 2, wordCount(slides[slides.count - 1]) < limit / 5,
           wordCount(slides[slides.count - 2]) + wordCount(slides[slides.count - 1]) <= limit + limit / 4 {
            let last = slides.removeLast()
            slides[slides.count - 1] += " " + last
        }
        return slides
    }

    /// A unit longer than `limit`, broken at sentence ends, then clause marks, then evenly.
    static func pieces(of unit: String, limit: Int) -> [String] {
        guard wordCount(unit) > limit else { return [unit] }
        for marks in [".?!", ";:", ","] {
            let parts = splitKeeping(unit, after: marks)
            if parts.count > 1 && parts.allSatisfy({ wordCount($0) <= limit }) { return parts }
            if parts.count > 1 {
                return parts.flatMap { pieces(of: $0, limit: limit) }
            }
        }
        let words = unit.split(separator: " ")
        let chunks = Int((Double(words.count) / Double(limit)).rounded(.up))
        let size = Int((Double(words.count) / Double(chunks)).rounded(.up))
        return stride(from: 0, to: words.count, by: size).map { words[$0..<min($0 + size, words.count)].joined(separator: " ") }
    }

    private static func splitKeeping(_ text: String, after marks: String) -> [String] {
        var parts: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if marks.contains(character) {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { parts.append(rest) }
        return parts.filter { !$0.isEmpty }
    }

    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}
