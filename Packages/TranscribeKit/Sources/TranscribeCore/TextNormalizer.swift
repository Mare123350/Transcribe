import Foundation

/// Turns messy transcript text into comparable word tokens.
/// "Charity suffereth long, and is kind;" -> ["charity", "suffereth", "long", "and", "is", "kind"]
public enum TextNormalizer {
    private static let locale = Locale(identifier: "en_US_POSIX")

    /// Lowercased word tokens with punctuation removed, accents folded, and apostrophes dropped
    /// ("Lord's" -> "lords"). Hyphens and dashes split words.
    public static func tokens(_ text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: locale)
        var tokens: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.append(scalar)
            } else if scalar == "'" || scalar == "\u{2019}" || scalar == "`" {
                continue
            } else if !current.isEmpty {
                tokens.append(String(current))
                current = String.UnicodeScalarView()
            }
        }
        if !current.isEmpty { tokens.append(String(current)) }
        return tokens
    }

    public static func normalized(_ text: String) -> String {
        tokens(text).joined(separator: " ")
    }

    /// Very common English words. N-grams made only of these say nothing about which verse or song is meant.
    public static let stopwords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "but", "by", "for", "from", "he", "her", "him", "his", "i", "in",
        "is", "it", "me", "my", "not", "of", "on", "or", "our", "say", "so", "that", "the", "their", "them", "they",
        "this", "to", "unto", "us", "was", "we", "were", "with", "you", "your", "ye", "thee", "thou", "thy", "shall",
        "will", "all", "have", "hath", "had", "which", "who", "what", "when", "there", "then", "do", "did", "if", "no",
        "oh", "o", "yeah", "come", "let", "into", "up", "out", "said", "saith",
    ]
}
