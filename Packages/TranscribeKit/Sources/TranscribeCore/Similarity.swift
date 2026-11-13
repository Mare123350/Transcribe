import Foundation

/// Word- and character-level similarity measures shared by song matching and verse scoring.
public enum Similarity {
    /// Edit distance between two strings, counting a swap of adjacent letters as one edit
    /// (optimal string alignment). Stops early once it exceeds `limit`.
    public static func levenshtein(_ a: String, _ b: String, limit: Int = .max) -> Int {
        let a = Array(a.unicodeScalars), b = Array(b.unicodeScalars)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        if abs(a.count - b.count) > limit { return limit + 1 }
        var beforePrevious = [Int](repeating: 0, count: b.count + 1)
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            var rowMin = current[0]
            for j in 1...b.count {
                var cost = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    cost = min(cost, beforePrevious[j - 2] + 1)
                }
                current[j] = cost
                rowMin = min(rowMin, cost)
            }
            if rowMin > limit { return limit + 1 }
            (beforePrevious, previous, current) = (previous, current, beforePrevious)
        }
        return previous[b.count]
    }

    /// Two transcribed words count as the same if they're equal, or long and one edit apart
    /// ("believeth" / "beleiveth"). Short words must match exactly.
    public static func wordsMatch(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard min(a.count, b.count) >= 5 else { return false }
        return levenshtein(a, b, limit: 1) <= 1
    }

    /// Length of the longest common subsequence of two word lists, i.e. how many words of `a`
    /// appear in `b` in the same order.
    public static func lcsLength(_ a: [String], _ b: [String], equal: (String, String) -> Bool = wordsMatch) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: b.count + 1)
        var current = previous
        for i in 1...a.count {
            for j in 1...b.count {
                current[j] = equal(a[i - 1], b[j - 1]) ? previous[j - 1] + 1 : max(previous[j], current[j - 1])
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    public static func ngrams(_ tokens: [String], n: Int) -> [String] {
        guard n > 0, tokens.count >= n else { return [] }
        return (0...(tokens.count - n)).map { tokens[$0..<($0 + n)].joined(separator: " ") }
    }

    public static func jaccard<T: Hashable>(_ a: Set<T>, _ b: Set<T>) -> Double {
        let union = a.union(b).count
        return union == 0 ? 0 : Double(a.intersection(b).count) / Double(union)
    }

    /// Fraction of `a` that is also in `b`.
    public static func containment<T: Hashable>(_ a: Set<T>, in b: Set<T>) -> Double {
        a.isEmpty ? 0 : Double(a.intersection(b).count) / Double(a.count)
    }

    /// Stable 64-bit FNV-1a hash of a word sequence, used as a compact n-gram key.
    public static func hash<S: Sequence>(words: S) -> UInt64 where S.Element == String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for word in words {
            for byte in word.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
            hash ^= 0x20
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}
