import Testing
import Foundation
@testable import Revis

/// A document big enough to be a problem, and a review with marks all through it.
///
/// Everything else here is exercised against four pages of specification, which proves
/// correctness and nothing at all about behaviour at size. The things most likely to fail
/// on a real document only fail when there is a lot of it: the annotations pane builds its
/// rows in a plain `VStack` on the stated grounds that "a review holds tens of rows, not
/// thousands"; `paint()` measures every mark against its block on every resize frame; the
/// outline is one row per heading; and the export walks the lot into one string. None of
/// those are wrong at eight annotations.
///
/// **Generated, not committed.** A megabyte and a half of HTML in the repository would be
/// paid for on every clone forever, to hold text that carries no information — it is the
/// same sentences in a different order. The generator is thirty lines of rules and a seed,
/// and it is reproducible, which a file somebody made once by hand is not.
///
/// **Generated, and also COMMITTED**, into `Samples/`. The two are not in tension: the
/// generator is the source of truth and the artefacts are what it produces, byte for byte,
/// which is why nothing here is allowed to vary run to run — one moving timestamp and every
/// test run would leave the working tree dirty for a change nobody made. Committing them
/// means somebody who clones this can open a three-hundred-page review in one gesture
/// without a toolchain; 880 KB of repetitive prose is 55 KB in the object store.
///
/// - `Samples/large-spec.html` — the document, openable on its own
/// - `Samples/large-review.revis` — a review of it, openable directly
struct LargeDocumentTests {

    /// About three hundred pages of PDF at four hundred and fifty words a page.
    static let targetWords = 135_000
    static let annotationCount = 300

    @Test func writeALargeDocumentAndAReviewOfIt() throws {
        let document = LargeDocument.make(words: Self.targetWords)
        let review = LargeDocument.review(of: document, annotations: Self.annotationCount)

        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Samples")
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        try document.html.write(to: directory.appendingPathComponent("large-spec.html"),
                                atomically: true, encoding: .utf8)
        try JSONEncoder.revis.encode(review).write(
            to: directory.appendingPathComponent("large-review.revis"))

        print("""

        large-spec.html   \(document.html.count / 1024) KB, \(document.words) words, \
        \(document.blocks.count) blocks, \(document.headings) headings
        large-review.revis \(review.annotations.count) annotations, \
        \(review.annotations.filter(\.isDecided).count) decided, \
        \(review.annotations.filter { $0.status == .resolved }.count) resolved, \
        \(review.annotations.flatMap(\.replies).count) replies

        """)

        // The size is the point, so it is asserted rather than hoped for.
        #expect(document.words >= Self.targetWords)
        #expect(document.blocks.count > 2_000)
        #expect(review.annotations.count == Self.annotationCount)

        // Every anchor names a block the document HAS, and quotes text it really contains.
        // This is the failure the specimen taught: a mark whose block is absent is one the
        // runtime declines to draw, silently and correctly, and the document then looks
        // unmarked rather than wrong.
        let text = ReviewFixtures.plainText(document.html)
        for annotation in review.annotations {
            for block in annotation.anchor.blocks {
                #expect(block < document.blocks.count, "block \(block) is not in the document")
            }
            #expect(text.contains(annotation.anchor.quote),
                    "not in the document: \(annotation.anchor.quote.prefix(60))")
            // Stronger, and the one that matters: the quote is in the block the anchor
            // NAMES. Merely being somewhere in the document is satisfied by an anchor
            // pointing at the wrong half of the file.
            guard let block = annotation.anchor.blocks.first else { continue }
            #expect(document.blocks[block].text.contains(annotation.anchor.quote)
                        || annotation.anchor.isRegion,
                    "quote is not in block \(block): \(annotation.anchor.quote.prefix(50))")
        }
        #expect(review.annotations.filter(\.anchor.isRegion).count > 20,
                "a fixture with no regions does not exercise the region path")

        // Offsets are BLOCK-relative, and this is the assertion that says so. Measured
        // against the document they are plausible numbers that place every highlight at the
        // end of its block as an empty range — visible as no highlights at all, with
        // nothing thrown and nothing logged.
        for annotation in review.annotations where !annotation.anchor.isRegion {
            guard let block = annotation.anchor.blocks.first else { continue }
            let blockText = document.blocks[block].text
            #expect(annotation.anchor.end <= blockText.count,
                    "offset \(annotation.anchor.end) is past a block of \(blockText.count)")
            let from = blockText.index(blockText.startIndex, offsetBy: annotation.anchor.start)
            let to = blockText.index(blockText.startIndex, offsetBy: annotation.anchor.end)
            #expect(String(blockText[from..<to]) == annotation.anchor.quote,
                    "the offsets do not select the quote")
        }
    }

    /// The whole thing has to survive a save and a reload, which at this size is the first
    /// time the format is asked to carry anything substantial.
    @Test func aLargeReviewSurvivesBeingWrittenAndReadBack() throws {
        let document = LargeDocument.make(words: 8_000)
        let original = LargeDocument.review(of: document, annotations: 120)
        let data = try JSONEncoder.revis.encode(original)
        let restored = try JSONDecoder.revis.decode(ReviewFile.self, from: data)
        #expect(restored == original)
    }
}

/// The generator.
///
/// Deterministic: one seed, one document. An anchor is measured against the text, so a
/// document that came out differently on the next run would be a review whose every mark
/// pointed at nothing — which is exactly the class of fault this fixture exists to catch.
enum LargeDocument {

    struct Block {
        var index: Int
        var role: String
        var path: String
        var text: String
    }

    struct Made {
        var html: String
        var blocks: [Block]
        var words: Int
        var headings: Int
    }

    /// A small, fast, reproducible source of numbers. `SystemRandomNumberGenerator` is
    /// neither of the last two, and `srand48` is process-global — one other test seeding it
    /// would silently change this document.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        init(_ seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1 }
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
    }

    // MARK: - Words

    private static let subjects = [
        "the retention worker", "each ingestion pipeline", "the deletion ledger",
        "every replica in the fleet", "the aggregation service", "a legal hold",
        "the tombstone writer", "each audit record", "the consent registry",
        "an operator with break-glass access", "the reconciliation pass",
        "every cohort smaller than the disclosure threshold", "the export scheduler",
    ]
    private static let verbs = [
        "must record", "is required to publish", "may not retain", "will reconcile",
        "shall emit", "is expected to acknowledge", "must not propagate", "will withhold",
        "is obliged to redact", "must replay", "shall defer", "is permitted to batch",
    ]
    private static let objects = [
        "a durable tombstone for every deleted row",
        "the identifier of the requesting principal",
        "the point-in-time snapshot the delete was issued against",
        "an entry in the audit log naming both the actor and the reason",
        "the derived aggregates computed from the affected records",
        "each acknowledgement received from a downstream consumer",
        "the retention class the record was admitted under",
        "a signed receipt that the operation completed",
        "the residual copies held in the warm tier",
        "every index entry that would otherwise resurrect the row",
    ]
    private static let qualifiers = [
        "within one scheduling interval", "before the next reconciliation pass",
        "unless a legal hold is in force", "except where the record is under audit",
        "for the duration of the retention period", "in the same transaction",
        "without waiting for downstream acknowledgement", "at the earliest opportunity",
        "subject to the disclosure threshold in §2", "and no later than the stated deadline",
    ]
    private static let openers = [
        "In practice", "By construction", "For the avoidance of doubt", "As a consequence",
        "Where this is not possible", "Under normal operation", "In the degraded case",
        "Historically", "For records admitted before the cutover",
    ]

    private static let topics = [
        "Ingestion", "Classification", "Retention", "Deletion", "Evidence", "Aggregation",
        "Legal holds", "Replication", "Backups", "Auditing", "Consent", "Exports",
        "Reconciliation", "Access control", "Encryption", "Key rotation", "Monitoring",
        "Incident response", "Data subject requests", "Third-party processors",
        "Schema evolution", "Cross-region transfer", "Anonymisation", "Sampling",
    ]
    private static let facets = [
        "scope and definitions", "the ordinary case", "failure modes", "operator duties",
        "evidence and audit", "interaction with legal holds", "downstream effects",
        "open questions",
    ]

    private static func sentence(_ rng: inout Seeded) -> String {
        var parts: [String] = []
        if Int.random(in: 0..<5, using: &rng) == 0 {
            parts.append(openers.randomElement(using: &rng)! + ",")
        }
        parts.append(subjects.randomElement(using: &rng)!)
        parts.append(verbs.randomElement(using: &rng)!)
        parts.append(objects.randomElement(using: &rng)!)
        if Int.random(in: 0..<2, using: &rng) == 0 {
            parts.append(qualifiers.randomElement(using: &rng)!)
        }
        var out = parts.joined(separator: " ") + "."
        out = out.prefix(1).uppercased() + out.dropFirst()
        return out
    }

    private static func paragraph(_ rng: inout Seeded) -> String {
        (0..<Int.random(in: 3...7, using: &rng))
            .map { _ in sentence(&rng) }
            .joined(separator: " ")
    }

    // MARK: - Building

    static func make(words target: Int) -> Made {
        var rng = Seeded(0x5EED_4EA5)
        var html: [String] = []
        var blocks: [Block] = []
        var words = 0
        var headings = 0

        // Mirrors the runtime's own bookkeeping in review.js: a heading trail, and a count
        // per role that resets at each heading. Kept in step deliberately — a path this
        // fixture invented would be a hint pointing somewhere the app would not agree with.
        var trail: [(depth: Int, text: String)] = []
        var counts: [String: Int] = [:]
        var titleSeen = false

        func path() -> String {
            trail.isEmpty ? "(top)" : trail.map(\.text).joined(separator: " › ")
        }

        /// Record a block the runtime will stamp. The index is simply how many have been
        /// stamped before it, because the runtime walks in document order and so does this.
        func stamp(_ role: String, _ text: String, heading depth: Int? = nil) {
            let index = blocks.count
            var blockPath: String
            if let depth {
                if depth == 1 && !titleSeen {
                    titleSeen = true
                    blockPath = "(title)"
                } else {
                    while let last = trail.last, last.depth >= depth { trail.removeLast() }
                    trail.append((depth: depth, text: text))
                    blockPath = path()
                }
                counts = [:]
                headings += 1
            } else {
                counts[role, default: 0] += 1
                blockPath = path() + " › " + role + " " + String(counts[role]!)
            }
            blocks.append(Block(index: index, role: role, path: blockPath, text: text))
            words += text.split(separator: " ").count
        }

        html.append("""
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <title>Customer Data Platform — Retention Specification (Consolidated)</title>
        <style>
          body { font-family: Georgia, serif; color: #23252b; line-height: 1.5; }
          h2 { border-bottom: 1px solid #e3e3e6; padding-bottom: 0.2em; }
          .callout { background: #f5f7fb; border-left: 3px solid #4a7fd0; padding: 0.8em 1em; }
          table { border-collapse: collapse; font-size: 0.94em; }
          td, th { border: 1px solid #dcdce0; padding: 0.3em 0.6em; text-align: left; }
          code { background: #f2f2f4; padding: 0.1em 0.3em; border-radius: 3px; }
        </style>
        </head>
        <body>
        """)

        let title = "Customer Data Platform — Retention Specification (Consolidated)"
        html.append("<h1>\(title)</h1>")
        stamp("heading-1", title, heading: 1)

        var part = 0
        var section = 0
        while words < target {
            part += 1
            let partTitle = "\(part). \(topics[(part - 1) % topics.count]) "
                + (part > topics.count ? "(continued)" : "")
            let partText = partTitle.trimmingCharacters(in: .whitespaces)
            html.append("<h2>\(partText)</h2>")
            stamp("heading-2", partText, heading: 2)

            for facet in facets where words < target {
                section += 1
                let sectionText = "\(part).\(facets.firstIndex(of: facet)! + 1) "
                    + facet.prefix(1).uppercased() + facet.dropFirst()
                html.append("<h3>\(sectionText)</h3>")
                stamp("heading-3", sectionText, heading: 3)

                for paragraphIndex in 0..<Int.random(in: 4...9, using: &rng) {
                    let text = paragraph(&rng)
                    html.append("<p>\(text)</p>")
                    stamp("paragraph", text)

                    // One structural block every few paragraphs, so the review has
                    // something other than prose to point at.
                    guard paragraphIndex == 2 else { continue }
                    switch section % 5 {
                    case 0:
                        html.append("<ul>")
                        for _ in 0..<Int.random(in: 3...6, using: &rng) {
                            let item = sentence(&rng)
                            html.append("<li>\(item)</li>")
                            stamp("list-item", item)
                        }
                        html.append("</ul>")
                    case 1:
                        let rows = (0..<Int.random(in: 3...6, using: &rng)).map { row in
                            ("Class \(section)-\(row)", "\((row + 1) * 30) days",
                             topics.randomElement(using: &rng)!,
                             objects.randomElement(using: &rng)!)
                        }
                        let head = "Class Retention Trigger Evidence"
                        let body = rows.map { "\($0.0) \($0.1) \($0.2) \($0.3)" }
                            .joined(separator: " ")
                        html.append("<table><thead><tr><th>Class</th><th>Retention</th>"
                            + "<th>Trigger</th><th>Evidence</th></tr></thead><tbody>")
                        for row in rows {
                            html.append("<tr><td>\(row.0)</td><td>\(row.1)</td>"
                                + "<td>\(row.2)</td><td>\(row.3)</td></tr>")
                        }
                        html.append("</tbody></table>")
                        stamp("table", head + " " + body)
                    case 2:
                        let quoted = sentence(&rng)
                        html.append("<blockquote><p>\(quoted)</p></blockquote>")
                        // The blockquote holds a block, so the runtime walks past it and
                        // stamps the paragraph inside — which is the rule this fixture
                        // would get wrong if it guessed.
                        stamp("paragraph", quoted)
                    case 3:
                        let code = "retention.apply(class: \"c\(section)\", days: \(section))"
                        html.append("<pre><code>\(code)</code></pre>")
                        stamp("code", code)
                    default:
                        let term = topics.randomElement(using: &rng)!
                        let definition = sentence(&rng)
                        html.append("<dl><dt>\(term)</dt><dd>\(definition)</dd></dl>")
                        stamp("term", term)
                        stamp("definition", definition)
                    }
                }
            }
        }

        html.append("</body>\n</html>")
        return Made(html: html.joined(separator: "\n"), blocks: blocks,
                    words: words, headings: headings)
    }

    // MARK: - The review

    /// Marks spread all the way through, of every kind, in every state.
    ///
    /// Built in ascending block order so the plain text can be searched with one cursor
    /// that only moves forward. Finding three hundred quotes from the start of a
    /// megabyte-and-a-half string is quadratic, and it is the sort of quadratic that only
    /// shows up at the size this fixture exists to reach.
    static func review(of document: Made, annotations count: Int) -> ReviewFile {
        var rng = Seeded(0xA55E_5713)
        // A fixed moment, not `.reviewStamp`, which is now. This review is COMMITTED, so a
        // timestamp that moves makes every test run rewrite the file and leaves the working
        // tree dirty for no change anybody made.
        let when = Date(timeIntervalSince1970: 1_788_690_000)
        // Ids too, and for the same reason: `UUID()` is fresh every run, so a committed
        // review whose ids move is a file that changes on every test with nothing in it
        // different. Derived from the step, which is what makes this reproducible rather
        // than merely repeatable.
        func id(_ n: Int) -> UUID {
            UUID(uuidString: String(format: "5ee00000-0000-4000-8000-%012d", n)) ?? UUID()
        }
        let text = ReviewFixtures.plainText(document.html)
        var cursor = text.startIndex
        var made: [Annotation] = []

        let authors = ["Robert Salesas", "Priya Raman", "Tomas Lind", ""]

        for step in 0..<count {
            // Spread across the WHOLE document, last block included. A fixed stride of
            // `blocks / count` leaves the tail bare — integer division rounds down, so at
            // 2,100 blocks and 300 marks the last three hundred blocks got none, which is
            // precisely the end of the scroll a size fixture is for.
            let span = max(1, document.blocks.count - 2)
            let blockIndex = 1 + (step * span) / count
            let block = document.blocks[blockIndex]
            let intent = Intent.allCases[step % Intent.allCases.count]

            // Locate the BLOCK first, then the phrase inside it — not the phrase directly.
            //
            // Searching for the phrase alone finds its first occurrence after the cursor,
            // and this document is deliberately repetitive: a run of six words recurs, so
            // the match would land in some earlier block while the anchor went on naming
            // this one. Nothing would fail — the quote is in the document, which is all a
            // naive check asks — and the fixture would quietly carry anchors whose block
            // and whose offsets described different places. A whole block's text is long
            // enough not to collide.
            guard let blockRange = text.range(of: block.text, range: cursor..<text.endIndex)
            else { continue }
            cursor = blockRange.lowerBound
            let quote = phrase(from: block.text, &rng)
            guard let range = text.range(of: quote, range: blockRange) else { continue }
            let offsetInBlock = text.distance(from: blockRange.lowerBound,
                                              to: range.lowerBound)

            let head = text.index(range.lowerBound, offsetBy: -64,
                                  limitedBy: text.startIndex) ?? text.startIndex
            let tail = text.index(range.upperBound, offsetBy: 64,
                                  limitedBy: text.endIndex) ?? text.endIndex
            let isRegion = step % 11 == 0

            let anchor = Anchor(
                blocks: [blockIndex],
                path: block.path,
                role: isRegion ? "region" : block.role,
                quote: isRegion ? String(block.text.prefix(1_200)) : quote,
                prefix: isRegion ? "" : String(text[head..<range.lowerBound]),
                suffix: isRegion ? "" : String(text[range.upperBound..<tail]),
                // Offsets are relative to the BLOCK, not to the document — see
                // `positionAt` in review.js, which walks the text nodes inside the block it
                // is handed. Measured document-wide they are hundreds of thousands out of
                // range; `positionAt` then clamps to the end of the block and every
                // highlight becomes an empty range there, which draws as nothing at all.
                // Nothing throws and nothing is logged.
                start: isRegion ? -1 : offsetInBlock,
                end: isRegion ? -1 : offsetInBlock + quote.count,
                rect: isRegion
                    ? NormalizedRect(x: 0, y: 0, width: 1, height: 1) : nil)

            var annotation = Annotation(
                id: id(step),
                created: when,
                author: authors[step % authors.count],
                intent: intent,
                note: instruction(for: intent, &rng),
                anchor: anchor)

            // A spread of states, so the pane's filter, the export's four sections and the
            // margin's three mark styles all have something to show at this size.
            if step % 9 == 0 {
                annotation.decide(step % 18 == 0 ? .approved : .declined, by: "Priya Raman")
            }
            if step % 7 == 0 { annotation.status = .resolved }
            if step % 5 == 0 {
                annotation.replies = [
                    Reply(id: id(10_000 + step), created: when, author: "Claude",
                          text: reply(&rng), isAssistant: true),
                ]
                if step % 10 == 0 {
                    annotation.replies.append(
                        Reply(id: id(20_000 + step), created: when,
                              author: "Robert Salesas", text: reply(&rng)))
                }
            }
            made.append(annotation)
        }

        return ReviewFile(
            source: SourceInfo(name: "large-spec.html", path: nil,
                               capturedAt: Date(timeIntervalSince1970: 1_788_690_000),
                               digest: SourceInfo.digest(of: Data(document.html.utf8))),
            document: DocumentPrep.prepare(html: document.html, baseURL: nil),
            annotations: made)
    }

    /// A run of words from the middle of a block — long enough to be findable, short enough
    /// that the context either side is doing real work.
    private static func phrase(from text: String, _ rng: inout Seeded) -> String {
        let words = text.split(separator: " ")
        guard words.count > 10 else { return text }
        let start = Int.random(in: 2..<max(3, words.count - 7), using: &rng)
        let length = min(Int.random(in: 4...8, using: &rng), words.count - start)
        return words[start..<(start + length)].joined(separator: " ")
    }

    private static func instruction(for intent: Intent, _ rng: inout Seeded) -> String {
        switch intent {
        case .change:   return "Say this the way §2 says it — the two do not match."
        case .insert:   return "Add a sentence here saying what happens when the"
                             + " acknowledgement never arrives."
        case .remove:   return "Covered by the corporate schedule already."
        case .move:     return "This belongs under Evidence, not here."
        case .question: return "Where is this threshold defined? I cannot find it in §2."
        case .comment:  return "Worth keeping exactly as it is — everything downstream"
                             + " leans on this wording."
        }
    }

    private static func reply(_ rng: inout Seeded) -> String {
        [
            "Applied. Note that the summary table still disagrees, which you did not ask"
                + " about, so I have left it and am reporting it here.",
            "I have not changed this: the instruction and the thread above disagree, and"
                + " the instruction is what I followed.",
            "These words are mine — you described what to write rather than giving it.",
            "Not defined anywhere in the document. §2 defines two terms and neither is"
                + " this one.",
        ].randomElement(using: &rng)!
    }
}
