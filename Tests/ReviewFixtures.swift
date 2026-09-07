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
