import Foundation

/// What Dubplate believes a bounce filename means.
public struct ParsedFilename: Hashable, Sendable {
    /// A leading number, if the filename carries one: `04 Midnight.wav` → 4.
    public var trackNumber: Int?
    /// The title with numbering and version markers removed.
    public var title: String
    /// Human version marker found in the name: "Mix 5", "Master 2", "Rough".
    public var versionLabel: String?
    /// The number inside that marker, when there is one.
    public var versionOrdinal: Int?
    /// Featured artists lifted out of a `(feat. …)` group.
    public var featuredArtists: String?
    /// Lowercased, punctuation-free title used to match bounces to each other.
    public var matchKey: String
    /// Everything that was stripped as a version marker, lowercased.
    public var versionTokens: [String]
    /// True when the marker describes a different rendering — an instrumental, an
    /// acapella, a radio edit — rather than a newer mix. Such a bounce is added as
    /// a version but never becomes the current one.
    public var isVariant: Bool

    public init(
        trackNumber: Int? = nil,
        title: String = "",
        versionLabel: String? = nil,
        versionOrdinal: Int? = nil,
        featuredArtists: String? = nil,
        matchKey: String = "",
        versionTokens: [String] = [],
        isVariant: Bool = false
    ) {
        self.trackNumber = trackNumber
        self.title = title
        self.versionLabel = versionLabel
        self.versionOrdinal = versionOrdinal
        self.featuredArtists = featuredArtists
        self.matchKey = matchKey
        self.versionTokens = versionTokens
        self.isVariant = isVariant
    }
}

/// Reads meaning out of the names producers actually give their bounces.
///
/// Deliberately deterministic and dependency-free: the same filename always
/// produces the same result, and every rule here is covered by a test in
/// Tests/CoreTests/FilenameParserTests.swift. Nothing this type decides is ever
/// applied silently — it only ever proposes.
public enum FilenameParser {

    /// Words that mark a bounce revision rather than part of a song title.
    /// Anything here is stripped off the end of a filename unconditionally, so the
    /// list only contains words nobody names a song after.
    static let versionKeywords: Set<String> = [
        "v", "ver", "version", "mix", "mixes", "master", "mastered", "mstr",
        "bounce", "take", "pass", "print", "rough", "demo", "sketch", "idea",
        "final", "alt", "alternate", "edit", "ref", "reference", "wip", "draft",
        "comp", "rev", "revision", "test", "tweak", "tweaks", "fix", "fixed",
        "backup", "copy", "revised"
    ]

    /// Words that describe a bounce but make perfectly good song titles.
    /// "Midnight drums.wav" is a mix of Midnight; "05 Bass.wav" is a track called
    /// Bass. Only ever stripped when a real word survives behind them.
    static let descriptorWords: Set<String> = [
        "drums", "drum", "vox", "vocal", "vocals", "bass", "keys", "gtr",
        "guitar", "synth", "stems", "inst", "instrumental", "acapella",
        "clean", "dirty", "wet", "dry", "loud", "quiet", "louder", "quieter",
        "radio", "extended"
    ]

    /// A different rendering of the same song rather than a newer one. An
    /// instrumental is worth keeping next to the vocal; it is never worth silently
    /// becoming the mix everyone hears.
    static let variantWords: Set<String> = [
        "instrumental", "inst", "acapella", "clean", "radio", "extended", "stems"
    ]

    /// Ordinary English words that only count as revision markers when they sit in
    /// front of one: the "new" in "Midnight new drums", never the "Down" in
    /// "Come Down".
    static let modifierWords: Set<String> = [
        "new", "old", "more", "less", "no", "without", "with", "extra", "another"
    ]

    /// Words that can trail a title without making it a different song. Used for
    /// matching tolerance only — matching proposes, it never renames anything.
    static let weakTokens: Set<String> = versionKeywords
        .union(descriptorWords)
        .union(modifierWords)
        .union(["up", "down", "long", "short", "only"])

    /// Filename extensions Dubplate will attempt to open as audio.
    public static let audioExtensions: Set<String> = [
        "wav", "wave", "aif", "aiff", "aifc", "caf", "flac", "m4a", "mp4",
        "alac", "aac", "mp3", "m4b"
    ]

    public static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif"]
    public static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]

    public static func isAudio(_ filename: String) -> Bool {
        audioExtensions.contains(fileExtension(of: filename))
    }

    public static func isImage(_ filename: String) -> Bool {
        imageExtensions.contains(fileExtension(of: filename))
    }

    /// `.mp4` is ambiguous; it is treated as video only when it is not audio-only,
    /// which the caller determines by inspecting the file. Name-level answer here.
    public static func isVideo(_ filename: String) -> Bool {
        videoExtensions.contains(fileExtension(of: filename))
    }

    public static func fileExtension(of filename: String) -> String {
        guard let dot = filename.lastIndex(of: "."), dot != filename.startIndex else { return "" }
        return String(filename[filename.index(after: dot)...]).lowercased()
    }

    public static func stem(of filename: String) -> String {
        guard let dot = filename.lastIndex(of: "."), dot != filename.startIndex else { return filename }
        return String(filename[..<dot])
    }

    // MARK: - Parsing

    public static func parse(_ filename: String) -> ParsedFilename {
        var working = stem(of: filename)
        var result = ParsedFilename()

        let (withoutGroups, featured, groupVersionTokens) = extractParentheticals(from: working)
        working = withoutGroups
        result.featuredArtists = featured

        // "NO SIGNAL - 02 - Dust" style: prefer the segment that looks like a title.
        let segments = working
            .components(separatedBy: " - ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if segments.count > 1 {
            if let numeric = segments.first(where: { Int($0) != nil }), let value = Int(numeric) {
                result.trackNumber = value
            }
            working = segments.last(where: { Int($0) == nil }) ?? working
        }

        var words = tokenize(working)
        // A number lifted out of an "Artist - 02 - Title" segment is as explicit as
        // a zero-padded one.
        var numberNamesASlot = result.trackNumber != nil
        if let lead = leadingTrackNumber(in: words) {
            result.trackNumber = result.trackNumber ?? lead.number
            words = lead.remaining
            numberNamesASlot = numberNamesASlot || lead.namesASlot
        }

        var consumed: [String] = []
        words = stripVersionTail(from: words, numberNamesASlot: numberNamesASlot, consumed: &consumed)
        consumed.append(contentsOf: groupVersionTokens)

        result.versionTokens = consumed.map { $0.lowercased() }
        result.isVariant = result.versionTokens.contains { variantWords.contains($0) }
        if !consumed.isEmpty {
            result.versionLabel = presentableLabel(from: consumed)
            result.versionOrdinal = ordinal(in: consumed)
        }

        let titleWords = words
        result.title = presentableTitle(from: titleWords, trackNumber: result.trackNumber, fallback: stem(of: filename))
        result.matchKey = matchKey(from: titleWords)
        if result.matchKey.isEmpty {
            result.matchKey = normalize(result.title)
        }
        return result
    }

    /// A short, human label for a version derived from its source filename.
    public static func prettyVersionLabel(for filename: String) -> String {
        let parsed = parse(filename)
        if let label = parsed.versionLabel, !label.isEmpty { return label }
        return stem(of: filename)
    }

    /// Lowercased, with spacing and punctuation removed. Used for equality tests
    /// between titles.
    ///
    /// Pictographs survive. Producers do name records ✧, 🜃 or 💿, and dropping
    /// every such scalar left the match key empty — so two bounces of the same
    /// song came in as two separate tracks, which is the one mistake import is
    /// there to avoid. Only "other symbol" is kept: arithmetic and currency signs
    /// stay out, as they always were.
    public static func normalize(_ text: String) -> String {
        String(
            text.lowercased().unicodeScalars.filter { scalar in
                CharacterSet.alphanumerics.contains(scalar)
                    || scalar.properties.generalCategory == .otherSymbol
            }
        )
    }

    // MARK: - Steps

    private static func extractParentheticals(from text: String) -> (String, String?, [String]) {
        var output = ""
        var featured: String?
        var versionTokens: [String] = []
        var depth = 0
        var group = ""
        for character in text {
            if character == "(" || character == "[" {
                depth += 1
                if depth == 1 { group = "" ; continue }
            }
            if character == ")" || character == "]" {
                depth -= 1
                if depth == 0 {
                    classifyGroup(group, featured: &featured, versionTokens: &versionTokens, passthrough: &output)
                    continue
                }
            }
            if depth > 0 { group.append(character) } else { output.append(character) }
        }
        if depth > 0 {
            // Unbalanced bracket: keep the text rather than losing it.
            output += group
        }
        return (output.trimmingCharacters(in: .whitespaces), featured, versionTokens)
    }

    private static func classifyGroup(
        _ group: String,
        featured: inout String?,
        versionTokens: inout [String],
        passthrough: inout String
    ) {
        let trimmed = group.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let lower = trimmed.lowercased()
        for marker in ["feat.", "feat ", "ft.", "ft ", "featuring "] where lower.hasPrefix(marker) {
            featured = String(trimmed.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            return
        }
        let words = tokenize(trimmed)
        let allWeak = !words.isEmpty && words.allSatisfy { isWeak($0) || Int($0) != nil }
        if allWeak {
            versionTokens.append(contentsOf: words)
        } else {
            passthrough += " " + trimmed
        }
    }

    private static func tokenize(_ text: String) -> [String] {
        var separated = ""
        for character in text {
            if character == "_" || character == "-" || character == "." || character == "–" {
                separated.append(" ")
            } else {
                separated.append(character)
            }
        }
        return separated.split(whereSeparator: { $0 == " " }).map(String.init)
    }

    /// A leading number, and whether the filename actually named a track slot.
    ///
    /// "04 Midnight" names slot four and the number is not part of the title.
    /// "24 Hours" is a song. The only reliable difference is the padding, so an
    /// unpadded number is recorded for ordering and left in the title.
    private static func leadingTrackNumber(
        in words: [String]
    ) -> (number: Int, remaining: [String], namesASlot: Bool)? {
        guard let first = words.first else { return nil }
        let lower = first.lowercased()
        if (lower == "track" || lower == "trk" || lower == "tk"), words.count > 1,
           let value = Int(words[1]), (1...99).contains(value) {
            return (value, Array(words.dropFirst(2)), true)
        }
        if let value = Int(first), first.count <= 3, (1...199).contains(value), words.count > 1 {
            let padded = first.hasPrefix("0")
            return (value, padded ? Array(words.dropFirst()) : words, padded)
        }
        // "A1" / "B2" vinyl sides: keep the number, drop the side letter.
        if first.count == 2, let digit = first.last?.wholeNumberValue,
           let side = first.first, side.isLetter, ("a"..."d").contains(String(side).lowercased()),
           words.count > 1 {
            return (digit, Array(words.dropFirst()), true)
        }
        return nil
    }

    /// Peels version markers off the end of the word list, right to left.
    private static func stripVersionTail(
        from words: [String],
        numberNamesASlot: Bool,
        consumed: inout [String]
    ) -> [String] {
        var remaining = words
        var tail: [String] = []
        while let last = remaining.last {
            let lower = last.lowercased()
            if let split = splitLetterDigit(lower), versionKeywords.contains(split.0) {
                tail.insert(last, at: 0)
                remaining.removeLast()
                continue
            }
            if versionKeywords.contains(lower) {
                tail.insert(last, at: 0)
                remaining.removeLast()
                continue
            }
            // A descriptor is only a marker when a real word survives it.
            if descriptorWords.contains(lower), remaining.count > 1 {
                tail.insert(last, at: 0)
                remaining.removeLast()
                continue
            }
            if modifierWords.contains(lower), !tail.isEmpty {
                tail.insert(last, at: 0)
                remaining.removeLast()
                continue
            }
            if Int(lower) != nil, remaining.count >= 2 {
                let previous = remaining[remaining.count - 2].lowercased()
                if versionKeywords.contains(previous) || splitLetterDigit(previous).map({ versionKeywords.contains($0.0) }) == true {
                    tail.insert(last, at: 0)
                    remaining.removeLast()
                    continue
                }
            }
            break
        }
        // A bare trailing number with nothing else left is a track number, not a version.
        if remaining.isEmpty, tail.count == 1, Int(tail[0]) != nil {
            return words
        }
        // Never strip a name down to nothing unless the filename actually named a
        // slot: "Drums idea.wav" is a track called "Drums idea".
        if remaining.isEmpty, !numberNamesASlot {
            return words
        }
        consumed.append(contentsOf: tail)
        return remaining
    }

    /// "mix5" → ("mix", 5)
    private static func splitLetterDigit(_ token: String) -> (String, Int)? {
        let letters = token.prefix { $0.isLetter }
        let digits = token.dropFirst(letters.count)
        guard !letters.isEmpty, !digits.isEmpty, digits.allSatisfy({ $0.isNumber }),
              let value = Int(digits) else { return nil }
        return (String(letters), value)
    }

    private static func isWeak(_ token: String) -> Bool {
        let lower = token.lowercased()
        if weakTokens.contains(lower) { return true }
        if let split = splitLetterDigit(lower), weakTokens.contains(split.0) { return true }
        return false
    }
    private static func ordinal(in tokens: [String]) -> Int? {
        for token in tokens.reversed() {
            if let value = Int(token) { return value }
            if let split = splitLetterDigit(token.lowercased()) { return split.1 }
        }
        return nil
    }

    private static func presentableLabel(from tokens: [String]) -> String {
        tokens
            .map { token -> String in
                if let split = splitLetterDigit(token.lowercased()) {
                    if split.0 == "v" { return "v\(split.1)" }
                    return "\(split.0.capitalized) \(split.1)"
                }
                if token.lowercased() == "v" { return "v" }
                // "Mix 01" and "Mix 1" are the same marker.
                if let value = Int(token) { return String(value) }
                // "FINAL" was shouted on purpose. Leave shouting alone.
                if token.contains(where: { $0.isLetter }), token.uppercased() == token {
                    return token
                }
                return token.capitalized
            }
            .joined(separator: " ")
    }

    private static func presentableTitle(from words: [String], trackNumber: Int?, fallback: String) -> String {
        let joined = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if joined.isEmpty {
            if let trackNumber { return "Track \(trackNumber)" }
            return fallback
        }
        let hasLowercase = joined.contains { $0.isLowercase }
        let hasUppercase = joined.contains { $0.isUppercase }
        if hasUppercase {
            // "NO SIGNAL" and "Midnight" are both intentional. Leave them alone.
            return joined
        }
        if hasLowercase {
            return joined
                .split(separator: " ")
                .map { $0.count <= 2 ? String($0) : $0.capitalized }
                .joined(separator: " ")
        }
        return joined
    }

    private static func matchKey(from words: [String]) -> String {
        normalize(words.joined())
    }
}
