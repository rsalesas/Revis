import Foundation

/// Reading a reply document — the other half of `ReviewExport`, and deliberately its
/// sibling in this folder.
///
/// **Why Markdown and not JSON.** JSON was the first choice and it is the wrong one. A JSON
/// syntax error is total: one unescaped newline in item 4 and items 1 through 8 are gone
/// with it, and the reviewer is told "could not read the file" about six answers that were
/// perfectly fine. Markdown degrades one reply at a time, and the one that broke can be
/// named. The payload here is multi-paragraph prose, which is the single thing JSON is
/// worst at and the only field that matters. And a person can hand-write one of these to
/// record what a colleague said in a meeting; nobody hand-writes an escape sequence.
///
/// **The heading rule is what makes that safe.** A reply may contain anything — headings,
/// fenced code, tables, block quotes — because a heading only starts a new reply when its
/// text IS an id. The delimiter validates itself, so there is no escaping to get wrong and
/// no way for a body to be mistaken for structure.
///
/// Scanned by hand rather than with a regular expression, for the sanitizer's reason: this
/// reads text somebody else produced, and a pattern that is nearly right fails in ways
/// nobody can see.
enum ReplyImport {

    // MARK: - What the document says

    /// One reply as the document names it, before anything has been decided about where it
    /// goes.
    struct ParsedReply: Equatable, Identifiable {
        let id = UUID()
        /// The id **exactly as written**, kept whole so one that matches nothing can be
        /// shown back as the reviewer will find it in the file, rather than reported as
        /// "an id".
        var rawID: String
        var author: String?
        var text: String
        /// 1-based line of its heading, so a problem can name a place.
        var line: Int

        static func == (a: ParsedReply, b: ParsedReply) -> Bool {
            a.rawID == b.rawID && a.author == b.author && a.text == b.text && a.line == b.line
        }
    }

    /// What was in the file. Never a failure: a document with four good replies and one
    /// mangled heading is four replies and one thing to tell the reviewer.
    struct Reading: Equatable {
        var replies: [ParsedReply] = []
        var problems: [Problem] = []
        /// The document's own `# ` title, where it gave one.
        var title: String?
    }

    enum Problem: Equatable {
        /// Nothing in the file looked like an id — almost always the wrong file picked.
        case noRepliesFound(head: String)
        case emptyReply(line: Int, rawID: String)
        case ambiguousID(line: Int, rawID: String, candidates: Int)
    }

    // MARK: - Reading

    static func read(_ markdown: String) -> Reading {
        var reading = Reading()
        var current: (rawID: String, line: Int)?
        var author: String?
        var body: [String] = []
        var expectingAuthor = false

        func flush() {
            guard let current else { return }
            let text = body.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                reading.problems.append(.emptyReply(line: current.line, rawID: current.rawID))
            } else {
                reading.replies.append(ParsedReply(rawID: current.rawID, author: author,
                                                   text: text, line: current.line))
            }
            body = []
            author = nil
        }

        for (offset, raw) in markdown.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let heading = headingText(line) {
                if isID(heading) {
                    flush()
                    current = (rawID: heading, line: offset + 1)
                    expectingAuthor = true
                    continue
                }
                // A heading that is not an id is somebody's prose — unless it is the
                // document's own title, before any reply has started.
                if current == nil, reading.title == nil, line.hasPrefix("# ") {
                    reading.title = heading
                    continue
                }
            }
            guard current != nil else { continue }   // chatter before the first reply
            if expectingAuthor {
                if line.isEmpty { continue }         // the blank line after a heading
                if let name = authorLine(line) {
                    author = name
                    expectingAuthor = false
                    continue
                }
                expectingAuthor = false
            }
            body.append(raw)
        }
        flush()

        if reading.replies.isEmpty && reading.problems.isEmpty {
            let head = markdown.components(separatedBy: .newlines)
                .prefix(6).joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            reading.problems.append(.noRepliesFound(head: head))
        }
        return reading
    }

    /// The text of an ATX heading, or nil. Setext headings are not recognised: an id
    /// underlined with `===` is not something anybody writes, and accepting it would make
    /// every line potentially a heading depending on the next one.
    private static func headingText(_ line: String) -> String? {
        var hashes = 0
        var rest = Substring(line)
        while rest.first == "#", hashes < 6 { hashes += 1; rest = rest.dropFirst() }
        guard hashes > 0, rest.first == " " || rest.isEmpty else { return nil }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    /// `**Answered by** Claude`, `Answered by: Claude`, `_Answered by_ Claude`.
    private static func authorLine(_ line: String) -> String? {
        let bare = line.replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "_", with: "")
            .trimmingCharacters(in: .whitespaces)
        let prefixes = ["answered by", "replied by", "reply from", "from"]
        let lowered = bare.lowercased()
        for prefix in prefixes where lowered.hasPrefix(prefix) {
            let name = bare.dropFirst(prefix.count)
                .trimmingCharacters(in: CharacterSet(charactersIn: " :—-"))
            return name.isEmpty ? nil : name
        }
        return nil
    }

    // MARK: - Identity

    /// The comparable form of an id: hex digits only, lowercased.
    ///
    /// Case, hyphens, backticks and a leading "Reply to" are all things that vary between
    /// one writer and the next and none of them mean anything. Refusing somebody's answer
    /// over punctuation would be the app losing work to a formality.
    static func normalize(_ raw: String) -> String {
        var text = raw.lowercased()
        for noise in ["reply to", "item", "`", "*"] {
            text = text.replacingOccurrences(of: noise, with: " ")
        }
        return String(text.filter { $0.isHexDigit })
    }

    /// Whether a heading's text is an id at all. Eight is the shortest accepted, which is
    /// what Git settled on for the same problem; below that a "match" is a coincidence.
    private static func isID(_ raw: String) -> Bool {
        let hex = normalize(raw)
        guard hex.count >= 8, hex.count <= 32 else { return false }
        // Only if what is left, after the noise, was ESSENTIALLY all hex — otherwise
        // "## Section 3 deleted" normalises to "3ded" plus enough letters to pass.
        let meaningful = raw.filter { !$0.isWhitespace && $0 != "-" && $0 != "`" && $0 != "*" }
        return Double(hex.count) / Double(max(meaningful.count, 1)) > 0.85
    }

    // MARK: - Where it would land

    enum Match: Equatable {
        case exact
        /// Resolved from a short id, the way Git resolves a short SHA.
        case prefix(length: Int)
    }

    /// One reply and the item it would attach to, worked out **before** anything changes —
    /// so the sheet that shows the reviewer what will happen and the code that makes it
    /// happen are reading the same answer rather than computing it twice.
    struct Landing: Identifiable, Equatable {
        var id: UUID { reply.id }
        var reply: ParsedReply
        var target: UUID?
        var match: Match?
        var problem: Problem?
        var isAttachable: Bool { target != nil }
    }

    /// Match every reply against the review.
    ///
    /// **Item numbers are never accepted, not even as a last resort**, and this is the most
    /// important rule here. An id that is wrong matches nothing and gets reported. A number
    /// that is wrong still matches *something* — and an answer silently filed under the
    /// wrong annotation is worse than an answer that never arrived, because nothing about
    /// it looks wrong afterwards.
    static func plan(_ reading: Reading, against annotations: [Annotation]) -> [Landing] {
        let keys = annotations.map { (id: $0.id, hex: normalize($0.exportID)) }
        return reading.replies.map { reply in
            let hex = normalize(reply.rawID)
            if let hit = keys.first(where: { $0.hex == hex }) {
                return Landing(reply: reply, target: hit.id, match: .exact)
            }
            let candidates = keys.filter { $0.hex.hasPrefix(hex) }
            if candidates.count == 1, hex.count >= 8 {
                return Landing(reply: reply, target: candidates[0].id,
                               match: .prefix(length: hex.count))
            }
            if candidates.count > 1 {
                return Landing(reply: reply, target: nil, match: nil,
                               problem: .ambiguousID(line: reply.line, rawID: reply.rawID,
                                                     candidates: candidates.count))
            }
            return Landing(reply: reply, target: nil, match: nil)
        }
    }

    // MARK: - Attaching

    /// Apply a plan.
    ///
    /// `isAssistant` is set **here**, and the document has no say in it — see `Reply`.
    @discardableResult
    static func attach(_ landings: [Landing], to annotations: inout [Annotation],
                       signedBy fallbackAuthor: String,
                       isAssistant: Bool = true) -> Result {
        var attached = 0
        var unmatched: [ParsedReply] = []
        for landing in landings {
            guard let target = landing.target,
                  let index = annotations.firstIndex(where: { $0.id == target }) else {
                unmatched.append(landing.reply)
                continue
            }
            let author = landing.reply.author?.trimmingCharacters(in: .whitespaces)
            annotations[index].replies.append(
                Reply(author: (author?.isEmpty == false ? author! : fallbackAuthor),
                      text: landing.reply.text, isAssistant: isAssistant))
            attached += 1
        }
        return Result(attached: attached, unmatched: unmatched,
                      problems: landings.compactMap(\.problem),
                      // Worth saying once rather than N times: a file none of whose ids are
                      // here is a reply to a different review, and telling somebody that is
                      // more use than telling them six ids are unknown.
                      looksLikeAnotherReview: attached == 0 && !landings.isEmpty)
    }

    /// What an import did, in the reviewer's terms.
    struct Result: Equatable {
        var attached: Int
        /// Kept WHOLE, not counted. What the model said is the valuable part, and a
        /// reviewer told "1 reply did not match" has been told the least useful fact
        /// about it.
        var unmatched: [ParsedReply]
        var problems: [Problem]
        var looksLikeAnotherReview: Bool
    }
}
