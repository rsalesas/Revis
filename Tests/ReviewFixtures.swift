import Testing
import Foundation
@testable import Revis

/// Building a review against the REAL sample document.
///
/// Extracted because three test files were each cutting quotes out of the same document by
/// hand, and one of them was doing it wrongly: `FileFormatTests` wrote its specimen with a
/// stub body and anchors pointing at blocks 3 and 8–11 of a document that had one block.
/// Nothing failed — a mark whose block is not there is a mark the runtime declines to draw,
/// which is correct — so the specimen simply opened with an empty margin, and the first
/// person to open it looking at the annotations pane assumed the app had broken.
///
/// An anchor built here is built the way the runtime builds one: the exact quote, plus up to
/// sixty-four characters either side, measured against the whitespace-collapsed text.
enum ReviewFixtures {

    static func html(_ name: String = "data-retention-spec.html") -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// The document's visible text, whitespace collapsed — what the runtime measures offsets
    /// and context against.
    static func plainText(_ html: String) -> String {
        var out = ""
        var inTag = false
        for character in HTMLSanitizer.sanitize(html).body {
            if character == "<" { inTag = true; out.append(" ") }
            else if character == ">" { inTag = false }
            else if !inTag { out.append(character) }
        }
        return out.replacingOccurrences(of: "\\s+", with: " ",
                                        options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// An anchor built the way the runtime builds one: the exact quote, plus up to 64
    /// characters either side, trimmed only on the outer edge.
    ///
    /// **`within` is the block's own text, and the offsets are measured against it.** They
    /// used to be measured against the whole document, which is wrong and was invisible:
    /// `positionAt` in review.js walks the text nodes INSIDE the block it is given, so a
    /// document-wide offset is out of range, and it clamps to the end of the block rather
    /// than failing. Every highlight became an empty range sitting at the end of its
    /// paragraph — nothing thrown, nothing logged, and in a short document just close
    /// enough to the right place to look like a rounding error. Passing the block's text
    /// makes the offsets mean what the runtime will read them as.
    static func anchor(_ quote: String, occurrence: Int = 0, block: Int,
                       path: String, role: String = "paragraph",
                       within: String? = nil,
                       in text: String) -> Anchor {
        var searchFrom = text.startIndex
        var found: Range<String.Index>?
        for _ in 0...occurrence {
            guard let hit = text.range(of: quote, range: searchFrom..<text.endIndex) else {
                break
            }
            found = hit
            searchFrom = hit.upperBound
        }
        guard let range = found else {
            Issue.record("the fixture does not contain \"\(quote)\"")
            return Anchor(blocks: [block], path: path, role: role, quote: quote,
                          prefix: "", suffix: "", start: -1, end: -1, rect: nil)
        }
        // Where the quote sits inside its own block. Falling back to the document-wide
        // position when no block text is given keeps old call sites compiling, but every
        // anchor that will be OPENED should pass `within`.
        let offset = within.flatMap { block in
            block.range(of: quote).map { block.distance(from: block.startIndex,
                                                        to: $0.lowerBound) }
        } ?? text.distance(from: text.startIndex, to: range.lowerBound)
        let head = text.index(range.lowerBound, offsetBy: -64,
                              limitedBy: text.startIndex) ?? text.startIndex
        let tail = text.index(range.upperBound, offsetBy: 64,
                              limitedBy: text.endIndex) ?? text.endIndex
        return Anchor(
            blocks: [block], path: path, role: role, quote: quote,
            prefix: String(text[head..<range.lowerBound]).replacingOccurrences(
                of: "^\\s+", with: "", options: .regularExpression),
            suffix: String(text[range.upperBound..<tail]).replacingOccurrences(
                of: "\\s+$", with: "", options: .regularExpression),
            start: offset,
            end: offset + quote.count,
            rect: nil)
    }
}

/// The document as the runtime will index it.
///
/// **Block numbers are not written down anywhere any more, and that is the point.** They
/// were, and every one of them was wrong: the fixtures claimed the summary table was block
/// 19 when 19 is the paragraph under "4. Deletion mechanics", and claimed "ninety (90)
/// days" was 11 when 11 is the heading above it. Marks were drawn beside the wrong
/// paragraphs for as long as those fixtures have existed. Nothing failed, because the
/// export treats a block index as a hint and says so — the only way to see it was to open
/// one and look, which is how it was finally caught, at a region box drawn around the wrong
/// block and overhanging the sheet.
///
/// So an anchor now names its quote and the index is derived. The walk mirrors `stamp()` in
/// review.js exactly: an element is stamped when its tag can carry an anchor AND it is
/// either atomic or contains no such element of its own — which is why a `blockquote`
/// holding a paragraph yields the paragraph, and a `table` yields itself.
extension ReviewFixtures {

    struct IndexedBlock {
        var index: Int
        var tag: String
        var role: String
        var path: String
        var text: String
    }

    struct Document {
        var html: String
        /// The whole visible text, whitespace collapsed — what prefix and suffix are cut from.
        var text: String
        var blocks: [IndexedBlock]

        /// The block holding the Nth occurrence of this quote, and where it sits inside it.
        ///
        /// Counted across blocks in document order, NOT per block — because the case this
        /// exists for is "Worker log", which occurs twice inside one table. Counting blocks
        /// would look for a second block containing it, find none, and report the fixture
        /// broken; counting occurrences finds the same block twice with different offsets,
        /// which is what "the second one" means to the person who marked it.
        func locate(_ quote: String, occurrence: Int = 0) -> (IndexedBlock, Int)? {
            var seen = 0
            for block in blocks {
                var searchFrom = block.text.startIndex
                while let hit = block.text.range(of: quote,
                                                 range: searchFrom..<block.text.endIndex) {
                    if seen == occurrence {
                        return (block, block.text.distance(from: block.text.startIndex,
                                                           to: hit.lowerBound))
                    }
                    seen += 1
                    searchFrom = hit.upperBound
                }
            }
            return nil
        }

        /// The block holding a quote, ignoring where in it. For a drawn box, which covers
        /// the block rather than a run of words.
        func block(containing quote: String) -> IndexedBlock? {
            blocks.first { $0.text.contains(quote) }
        }
    }

    private static let blockTags: Set<String> = [
        "P", "H1", "H2", "H3", "H4", "H5", "H6", "LI", "BLOCKQUOTE", "PRE", "TABLE",
        "FIGURE", "FIGCAPTION", "DT", "DD", "HR", "ADDRESS", "DIV", "SECTION", "ARTICLE",
        "ASIDE", "HEADER", "FOOTER", "MAIN", "DETAILS",
    ]
    private static let atomicTags: Set<String> = ["PRE", "TABLE", "FIGURE"]
    private static let roles: [String: String] = [
        "P": "paragraph", "H1": "heading-1", "H2": "heading-2", "H3": "heading-3",
        "H4": "heading-4", "H5": "heading-5", "H6": "heading-6", "LI": "list-item",
        "BLOCKQUOTE": "quote", "PRE": "code", "TABLE": "table", "FIGURE": "figure",
        "FIGCAPTION": "caption", "DT": "term", "DD": "definition", "HR": "rule",
        "ADDRESS": "address", "DETAILS": "disclosure",
    ]

    static func document(_ name: String = "data-retention-spec.html") -> Document {
        let raw = html(name)
        let body = HTMLSanitizer.sanitize(raw).body
        let scanned = elements(in: body)

        var blocks: [IndexedBlock] = []
        var trail: [(depth: Int, text: String)] = []
        var counts: [String: Int] = [:]
        var titleSeen = false

        for element in scanned {
            guard blockTags.contains(element.tag) else { continue }
            let inner = String(body[element.inner])
            if !atomicTags.contains(element.tag), containsBlock(inner) { continue }

            let role = roles[element.tag] ?? "block"
            let text = flatten(inner)
            var path: String
            if let depth = headingDepth(element.tag) {
                if depth == 1 && !titleSeen {
                    titleSeen = true
                    path = "(title)"
                } else {
                    while let last = trail.last, last.depth >= depth { trail.removeLast() }
                    trail.append((depth: depth, text: text))
                    path = trail.isEmpty ? "(top)" : trail.map(\.text).joined(separator: " › ")
                }
                counts = [:]
            } else {
                counts[role, default: 0] += 1
                let head = trail.isEmpty ? "(top)"
                                         : trail.map(\.text).joined(separator: " › ")
                path = head + " › " + role + " " + String(counts[role]!)
            }
            blocks.append(IndexedBlock(index: blocks.count, tag: element.tag, role: role,
                                       path: path, text: text))
        }
        return Document(html: raw, text: plainText(raw), blocks: blocks)
    }

    private static func headingDepth(_ tag: String) -> Int? {
        guard tag.count == 2, tag.hasPrefix("H"), let depth = Int(tag.dropFirst()) else {
            return nil
        }
        return (1...6).contains(depth) ? depth : nil
    }

    private static func containsBlock(_ inner: String) -> Bool {
        var scanner = inner[...]
        while let open = scanner.firstIndex(of: "<") {
            let after = scanner.index(after: open)
            guard after < scanner.endIndex else { return false }
            let name = scanner[after...].prefix { $0.isLetter || $0.isNumber }
            if blockTags.contains(name.uppercased()) { return true }
            scanner = scanner[after...]
        }
        return false
    }

    /// Tags stripped, entities resolved, whitespace collapsed — the same shape `plainText`
    /// produces, so an offset measured in one means the same thing in the other.
    private static func flatten(_ inner: String) -> String {
        var out = ""
        var inTag = false
        for character in inner {
            if character == "<" { inTag = true; out.append(" ") }
            else if character == ">" { inTag = false }
            else if !inTag { out.append(character) }
        }
        return out.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private struct Element { var tag: String; var inner: Range<String.Index> }

    /// Every element, in the document order of its OPENING tag — which is the order the
    /// runtime's walk visits them in.
    private static func elements(in body: String) -> [Element] {
        // `hr` stamps but holds nothing; the rest of these never stamp and never close.
        let empty: Set<String> = ["IMG", "BR", "META", "LINK", "INPUT", "SOURCE", "COL", "HR"]
        var found: [Element] = []
        var open: [(tag: String, inner: String.Index)] = []
        var cursor = body.startIndex

        while let start = body[cursor...].firstIndex(of: "<") {
            guard let close = body[start...].firstIndex(of: ">") else { break }
            let after = body.index(after: start)
            let isClosing = after < body.endIndex && body[after] == "/"
            let nameStart = isClosing ? body.index(after: after) : after
            let name = body[nameStart..<close].prefix { $0.isLetter || $0.isNumber }
            let tag = name.uppercased()
            let end = body.index(after: close)

            if tag.isEmpty {                        // a comment or a doctype
                cursor = end
                continue
            }
            if empty.contains(tag) {
                if tag == "HR" { found.append(Element(tag: tag, inner: end..<end)) }
            } else if isClosing {
                if let match = open.lastIndex(where: { $0.tag == tag }) {
                    found.append(Element(tag: tag, inner: open[match].inner..<start))
                    open.removeSubrange(match...)
                }
            } else if !body[nameStart..<close].hasSuffix("/") {
                open.append((tag: tag, inner: end))
            }
            cursor = end
        }
        return found.sorted { $0.inner.lowerBound < $1.inner.lowerBound }
    }

    /// An anchor that finds its own block. Nothing here is written down twice: the index,
    /// the role and the path all come from the walk, and the offsets are measured inside
    /// the block the quote was found in.
    static func anchor(_ quote: String, occurrence: Int = 0,
                       in document: Document) -> Anchor {
        guard let (block, offset) = document.locate(quote, occurrence: occurrence) else {
            Issue.record("the fixture has no occurrence \(occurrence) of that quote")
            return Anchor(blocks: [0], path: "", role: "paragraph", quote: quote,
                          prefix: "", suffix: "", start: -1, end: -1, rect: nil)
        }
        // Context comes from the whole document, since that is what the reader searches;
        // the offsets come from the block, since that is what the runtime walks.
        var searchFrom = document.text.startIndex
        var found: Range<String.Index>?
        for _ in 0...occurrence {
            guard let hit = document.text.range(of: quote,
                                                range: searchFrom..<document.text.endIndex)
            else { break }
            found = hit
            searchFrom = hit.upperBound
        }
        let head = found.map {
            document.text.index($0.lowerBound, offsetBy: -64,
                                limitedBy: document.text.startIndex)
                ?? document.text.startIndex
        }
        let tail = found.map {
            document.text.index($0.upperBound, offsetBy: 64,
                                limitedBy: document.text.endIndex) ?? document.text.endIndex
        }
        return Anchor(
            blocks: [block.index], path: block.path, role: block.role, quote: quote,
            prefix: found.map {
                String(document.text[head!..<$0.lowerBound])
                    .replacingOccurrences(of: "^\\s+", with: "",
                                          options: .regularExpression)
            } ?? "",
            suffix: found.map {
                String(document.text[$0.upperBound..<tail!])
                    .replacingOccurrences(of: "\\s+$", with: "",
                                          options: .regularExpression)
            } ?? "",
            start: offset, end: offset + quote.count, rect: nil)
    }

    /// A drawn box over a whole block, as the region tool would leave it.
    static func region(over quote: String, in document: Document) -> Anchor {
        guard let block = document.block(containing: quote) else {
            Issue.record("no block of the fixture contains \"\(quote)\"")
            return Anchor(blocks: [0], path: "", role: "region", quote: quote,
                          prefix: "", suffix: "", start: -1, end: -1, rect: nil)
        }
        return Anchor(
            blocks: [block.index], path: block.path, role: "region",
            quote: String(block.text.prefix(1_200)), prefix: "", suffix: "",
            start: -1, end: -1,
            // The whole block and no more. It was `1.79` wide by `1.23` tall starting above
            // and to the left — arbitrary numbers that round-tripped fine and drew a box
            // eighty per cent wider than the sheet.
            rect: NormalizedRect(x: 0, y: 0, width: 1, height: 1))
    }
}

/// The walk has to agree with `stamp()` in review.js, and nothing but a test says so.
struct BlockWalkTests {

    @Test func theWalkStampsWhatTheRuntimeStamps() {
        let document = ReviewFixtures.document()
        // Spot-checked against the runtime's own numbering of this fixture. These are the
        // indices the app reports, not the ones the fixtures used to claim.
        let expected: [(Int, String, String)] = [
            (0, "H1", "Customer Data Platform"),
            (3, "P", "This document specifies"),
            (4, "P", "Anything not named in §3"),
            (9, "DD", "Irreversible removal"),
            (12, "P", "All personal data is retained"),
            (15, "P", "Aggregates computed from"),
            (17, "TABLE", "Class Retention Trigger"),
            (19, "P", "The retention worker runs hourly"),
        ]
        for (index, tag, opening) in expected {
            guard index < document.blocks.count else {
                Issue.record("no block \(index)"); continue
            }
            let block = document.blocks[index]
            #expect(block.tag == tag, "block \(index) is a \(block.tag), expected \(tag)")
            #expect(block.text.hasPrefix(opening),
                    "block \(index) begins \"\(block.text.prefix(30))\"")
        }
    }

    /// The rule that is easiest to get wrong: a container holding a block yields the block
    /// inside it, an atomic one yields itself.
    @Test func aContainerYieldsWhatIsInsideItAndATableYieldsItself() {
        let document = ReviewFixtures.document()
        // The callout is a <div> wrapping a <p>: the paragraph is stamped, the div is not.
        #expect(document.blocks.contains { $0.tag == "P" && $0.text.hasPrefix("Anything not") })
        #expect(!document.blocks.contains { $0.tag == "DIV" })
        // The table is atomic, so its cells are not blocks of their own.
        #expect(document.blocks.contains { $0.tag == "TABLE" })
        #expect(!document.blocks.contains { $0.tag == "TD" })
    }
}
