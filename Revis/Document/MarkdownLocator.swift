import Foundation

/// Finding the words an annotation is about in the Markdown they were rendered from.
///
/// This is the second half of the answer to a problem the app otherwise does not have. A
/// reviewer reads a rendering and marks a phrase; the assistant that acts on the review
/// opens the source. `MarkdownShadow` says which characters of the source are on the
/// screen; this says which of them are *these* words.
///
/// It is a search, not a coordinate transform, and that is the whole reason it can be
/// trusted. Revis has always addressed text by quoting it — see `ReviewExport` — so asking
/// where a quote lives in another spelling of the same document is the question the app was
/// already built around. What it adds is the honesty the rest of the export has: a quote
/// that cannot be found is **reported as not found**, never approximated. A wrong address
/// that looks right is the one failure this app is not allowed to have.
enum MarkdownLocator {

    /// How sure we are that this is the right occurrence.
    enum Confidence: String, Sendable {
        /// The words occur once in the whole file.
        case unique
        /// They occur several times, and the surrounding words picked one.
        case byContext
        /// They occur several times, and only the section heading picked one.
        case bySection
        /// They occur several times and nothing separated them. The first is returned, and
        /// the export says so rather than pretending.
        case ambiguous
    }

    struct Match: Sendable {
        /// The words as the file actually writes them — markup and all. This is what the
        /// export quotes, because it is what a reader can search for in the file it is
        /// editing.
        var sourceQuote: String
        /// Where in the shadow it was found, for the caller that wants to narrow further.
        var range: Range<Int>
        var confidence: Confidence
    }

    /// Where `anchor`'s words are in the source `shadow` was built from, or nil if they are
    /// not in it at all.
    ///
    /// Nil is a real and expected answer, not a failure to try. Some of what a reviewer can
    /// mark has no source text behind it: a generated table of contents, the `↩` at the end
    /// of a footnote, the numbering Apex assigns. The export names those instead of
    /// inventing a location for them.
    static func locate(_ anchor: Anchor, in shadow: MarkdownShadow) -> Match? {
        let needle = fold(normalise(anchor.quote))
        guard !needle.isEmpty else { return nil }
        let haystack = shadow.characters.map(foldCharacter)

        var hits = occurrences(of: needle, in: haystack)
        if hits.isEmpty { return nil }

        // A quote taken from one block cannot legitimately run into the next, and the
        // block separator is the only newline in the shadow. Without this, a phrase ending
        // one paragraph and starting another matches across the join and the instruction
        // lands on two blocks nobody marked.
        if !anchor.isRegion {
            let contained = hits.filter { !haystack[$0..<($0 + needle.count)].contains("\n") }
            if !contained.isEmpty { hits = contained }
        }

        if hits.count == 1 {
            return match(at: hits[0], length: needle.count, in: shadow, confidence: .unique)
        }

        // Several. The words either side are the better discriminator — they are what the
        // anchor stores them for — so they are tried first, and the heading trail only
        // breaks what they leave tied.
        let byContext = hits.filter { agreesWithContext(anchor, at: $0, length: needle.count,
                                                        in: haystack) }
        if byContext.count == 1 {
            return match(at: byContext[0], length: needle.count, in: shadow,
                         confidence: .byContext)
        }

        let remaining = byContext.isEmpty ? hits : byContext
        let wanted = headingSegments(of: anchor.path)
        if !wanted.isEmpty {
            let scored = remaining
                .map { ($0, sectionScore(at: $0, in: shadow, wanted: wanted)) }
                .filter { $0.1 > 0 }
            if let best = scored.max(by: { $0.1 < $1.1 }),
               scored.filter({ $0.1 == best.1 }).count == 1 {
                return match(at: best.0, length: needle.count, in: shadow,
                             confidence: byContext.isEmpty ? .bySection : .byContext)
            }
        }

        return match(at: remaining[0], length: needle.count, in: shadow, confidence: .ambiguous)
    }

    // MARK: - Pieces

    private static func match(at index: Int, length: Int, in shadow: MarkdownShadow,
                              confidence: Confidence) -> Match? {
        let range = index..<(index + length)
        let text = shadow.sourceText(for: range)
        guard !text.isEmpty else { return nil }
        return Match(sourceQuote: text, range: range, confidence: confidence)
    }

    private static func occurrences(of needle: [Character], in haystack: [Character]) -> [Int] {
        guard !needle.isEmpty, haystack.count >= needle.count else { return [] }
        var found: [Int] = []
        for start in 0...(haystack.count - needle.count) {
            var k = 0
            while k < needle.count, haystack[start + k] == needle[k] { k += 1 }
            if k == needle.count { found.append(start) }
        }
        return found
    }

    /// Whether the words either side of this occurrence are the ones the anchor recorded.
    ///
    /// Compared as a tail and a head rather than in full: the anchor keeps 64 characters of
    /// each, and a match at the very start of a document has fewer. Requiring the whole
    /// stored context would refuse the first paragraph of every file.
    private static func agreesWithContext(_ anchor: Anchor, at index: Int, length: Int,
                                          in haystack: [Character]) -> Bool {
        let before = fold(normalise(anchor.prefix))
        let after = fold(normalise(anchor.suffix))
        if before.isEmpty && after.isEmpty { return false }

        // The space at the join is dropped on one side and not the other, and that is not
        // a detail: `normalise` trims, so a suffix stored as " 1 Rotated" arrives as
        // "1 Rotated", while the shadow still has the space before it. Comparing them
        // literally made every context test fail at the boundary — which showed up as
        // every repeated quote coming back ambiguous, with the context that would have
        // separated them sitting right there unused.
        if !before.isEmpty {
            let want = Array(before.suffix(24))
            var upper = index
            if upper > 0, haystack[upper - 1] == " " { upper -= 1 }
            let lower = max(0, upper - want.count)
            if Array(haystack[lower..<upper]) != want { return false }
        }
        if !after.isEmpty {
            let want = Array(after.prefix(24))
            var lower = min(index + length, haystack.count)
            if lower < haystack.count, haystack[lower] == " " { lower += 1 }
            let upper = min(lower + want.count, haystack.count)
            if Array(haystack[lower..<upper]) != want { return false }
        }
        return true
    }

    /// How well the headings open above this occurrence match the ones the anchor recorded.
    private static func sectionScore(at index: Int, in shadow: MarkdownShadow,
                                     wanted: [String]) -> Int {
        guard let section = shadow.section(at: index) else { return 0 }
        let have = section.headings.map { fold(normalise($0)) }
        var score = 0
        for segment in wanted where have.contains(Array(fold(normalise(segment)))) {
            score += 1
        }
        return score
    }

    /// The heading part of an `Anchor.path`, without the trailing ordinal.
    ///
    /// A path reads `3. Retention periods › 3.1 Personal data › paragraph 1`. The last
    /// segment is the runtime's own counter — "the first paragraph since the last heading"
    /// — and names no heading, so comparing it against a heading trail would always fail.
    static func headingSegments(of path: String) -> [String] {
        var parts = path.split(separator: "›").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        if let last = parts.last, isRoleOrdinal(last) { parts.removeLast() }
        return parts
    }

    private static func isRoleOrdinal(_ segment: String) -> Bool {
        let words = segment.split(separator: " ")
        guard words.count == 2, Int(words[1]) != nil else { return false }
        let roles: Set<String> = [
            "paragraph", "list-item", "quote", "code", "table", "figure", "caption",
            "term", "definition", "rule", "address", "disclosure", "block",
        ]
        return roles.contains(String(words[0])) || words[0].hasPrefix("heading-")
    }

    // MARK: - Normalising

    /// The same shape the page's `flatten()` gives a quote: whitespace runs to one space.
    private static func normalise(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Fold the characters that differ between the file and the screen for no reason a
    /// reader would recognise.
    ///
    /// Only the quotes, and only because smart typography curls them on the way out. The
    /// alternative — curling them in the shadow too — means deciding at every apostrophe
    /// which of `'` and `'` Apex chose, and being wrong about one of them loses every
    /// quote in the document containing the word "don't". Folding both sides flat needs no
    /// such decision. Dashes and ellipses are NOT folded here: the shadow already spells
    /// them the way the page does, and it can, because their direction is not in question.
    private static func fold(_ text: String) -> [Character] {
        text.map(foldCharacter)
    }

    private static func foldCharacter(_ ch: Character) -> Character {
        switch ch {
        case "\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}", "\u{2032}": return "'"
        case "\u{201C}", "\u{201D}", "\u{201E}", "\u{201F}", "\u{2033}": return "\""
        case "\u{00A0}", "\u{2007}", "\u{202F}": return " "
        default: return ch
        }
    }
}
