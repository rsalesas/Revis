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
    static func anchor(_ quote: String, occurrence: Int = 0, block: Int,
                       path: String, role: String = "paragraph",
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
            start: text.distance(from: text.startIndex, to: range.lowerBound),
            end: text.distance(from: text.startIndex, to: range.upperBound),
            rect: nil)
    }
}
