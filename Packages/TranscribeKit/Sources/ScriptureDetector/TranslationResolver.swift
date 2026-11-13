import Foundation

/// Which translation to show a passage in, and why.
public struct TranslationChoice: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        /// An installed translation (bundled or imported).
        case installed
        /// Fetched from an online provider with the user's own key.
        case online
        /// The requested version isn't available; this is the best installed one instead.
        case fallback
        /// No available translation has this passage.
        case missing
    }

    /// The abbreviation to show the text in.
    public let shown: String
    /// What the speaker or operator asked for, when it's different from `shown` ("NIV requested").
    public let requested: String?
    public let source: Source

    public init(shown: String, requested: String?, source: Source) {
        self.shown = shown
        self.requested = requested
        self.source = source
    }

    /// "NIV requested, showing KJV".
    public var label: String? {
        guard let requested else { return nil }
        if source == .missing { return "\(requested) requested, not available" }
        return requested.caseInsensitiveCompare(shown) == .orderedSame ? nil : "\(requested) requested, showing \(shown)"
    }
}

/// Picks a translation: the requested one if it's installed or online, otherwise the default,
/// then the user's fallback order, then any installed translation that has the passage.
public enum TranslationResolver {
    /// - Parameters:
    ///   - requested: a version named by the speaker or chosen by the operator, if any.
    ///   - installed: installed abbreviations, in library order.
    ///   - online: abbreviations available from configured online providers.
    ///   - defaultVersion: the user's default translation.
    ///   - order: the user's fallback order (may name versions that aren't installed).
    ///   - hasPassage: whether an installed translation contains the passage (imports may be partial).
    public static func resolve(
        requested: String?,
        installed: [String],
        online: [String] = [],
        defaultVersion: String,
        order: [String] = [],
        hasPassage: (String) -> Bool = { _ in true }
    ) -> TranslationChoice {
        func find(_ name: String, in list: [String]) -> String? {
            list.first { $0.caseInsensitiveCompare(name) == .orderedSame }
        }
        if let requested, !requested.isEmpty {
            if let match = find(requested, in: installed), hasPassage(match) {
                return TranslationChoice(shown: match, requested: nil, source: .installed)
            }
            if let match = find(requested, in: online) {
                return TranslationChoice(shown: match, requested: nil, source: .online)
            }
        }
        var candidates: [String] = []
        for name in [defaultVersion] + order + installed {
            if let match = find(name, in: installed), find(match, in: candidates) == nil { candidates.append(match) }
        }
        let requestedName = requested.flatMap { $0.isEmpty ? nil : $0.uppercased() }
        if let shown = candidates.first(where: hasPassage) {
            return TranslationChoice(shown: shown, requested: requestedName, source: requestedName == nil ? .installed : .fallback)
        }
        return TranslationChoice(shown: requestedName ?? defaultVersion, requested: requestedName, source: .missing)
    }

    /// Copyrighted versions people commonly ask for. They can't be bundled; the app explains how to
    /// get each one (a licensed import, or an online provider with the user's own key).
    public static let copyrighted: [(abbreviation: String, name: String, provider: String?)] = [
        ("NIV", "New International Version", "API.Bible (if your key is licensed for it)"),
        ("ESV", "English Standard Version", "ESV API"),
        ("NLT", "New Living Translation", "API.Bible (if your key is licensed for it)"),
        ("NKJV", "New King James Version", "API.Bible (if your key is licensed for it)"),
        ("NASB", "New American Standard Bible", "API.Bible (if your key is licensed for it)"),
        ("CSB", "Christian Standard Bible", "API.Bible (if your key is licensed for it)"),
        ("AMP", "Amplified Bible", "API.Bible (if your key is licensed for it)"),
        ("MSG", "The Message", "API.Bible (if your key is licensed for it)"),
    ]
}
