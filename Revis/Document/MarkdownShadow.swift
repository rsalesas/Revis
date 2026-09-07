import Foundation

/// The text of a Markdown file as a reader sees it, with every character still knowing
/// where in the file it came from.
///
/// **Why this exists.** A reviewer marks up a rendering; the assistant that acts on the
/// review edits the source. Those are two documents, and an annotation that quotes
/// "retained for ninety days" is not an address in a file that says
/// `retained for **ninety** days`. Something has to carry a quote back across the render,
/// and Apex cannot: it has no source positions in its HTML, none in its C API, and none in
/// its JSON AST — and it could not have useful ones anyway, because a dozen of its
/// extensions rewrite the source text before cmark ever parses it.
///
/// **Why not simply parse the Markdown again.** Because a second parser is a second
/// opinion. Ask cmark whether that block is a table and it will sometimes disagree with
/// Apex — precisely on the documents where dialects differ, which is precisely where a
/// wrong answer would be believed. So this does not parse the document. It decides one
/// thing only: which characters of the file are *text a reader sees*, and where the runs
/// of them begin and end. Where it is unsure it drops the characters, which costs a quote
/// that cannot be found; being unsure and guessing would cost a quote found in the wrong
/// place, and `MarkdownLocator` would have no way to tell.
///
/// The text it builds is normalised the way the page's own `flatten()` normalises a quote:
/// runs of whitespace collapsed to one space. Blocks are separated by a newline, which is
/// the only character in `text` that is not a space or a word — see `MarkdownLocator`,
/// which uses it to refuse a match that runs from one paragraph into the next.
private extension Array {
    subscript(safe index: Int) -> Element? {
        index >= 0 && index < count ? self[index] : nil
    }
}

struct MarkdownShadow {

    /// A run of the shadow that came from one block, and the headings open above it.
    ///
    /// The headings are what let a quote occurring six times be found in the right place:
    /// the annotation carries the same trail in `Anchor.path`. They are compared as text,
    /// not as positions, for the reason the whole app is built on.
    struct Section: Equatable, Sendable {
        var range: Range<Int>       // in `characters`
        var headings: [String]      // outermost first
        var kind: Kind

        enum Kind: Equatable, Sendable {
            case prose, heading, code, table
        }
    }

    /// Reader-visible text.
    let text: String
    /// `text` as characters, so an index into it is an integer.
    let characters: [Character]
    /// For each character of `characters`, the range of source characters it came from —
    /// start, and one past the end. A shadow character usually stands for one source
    /// character, but not always: `---` is one em dash, `&amp;` is one ampersand.
    let origin: [Int]
    let originEnd: [Int]
    /// The source, as characters — the thing `origin` indexes.
    let source: [Character]
    let sections: [Section]

    /// The source text a shadow range came from, as it is actually written in the file.
    ///
    /// From the first character's start to the last character's end. Everything between
    /// two visible characters — skipped markup, a wrapped line's newline — falls inside
    /// and is kept, which is the point: `**bold**` is what the file says and what a reader
    /// must search for. What is NOT kept is anything past the last visible character, and
    /// that took a rewrite to get right: reaching to where the next one begins instead
    /// swept up the table cell's closing `|`, a code block's indent, and a trailing space
    /// on every quote in the document.
    func sourceText(for range: Range<Int>) -> String {
        guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= origin.count else {
            return ""
        }
        var from = origin[range.lowerBound]
        let to = originEnd[range.upperBound - 1]
        guard from < to, to <= source.count else { return "" }
        let gapStart = range.lowerBound > 0 ? originEnd[range.lowerBound - 1] : 0
        from = balancingOpener(before: from, upTo: to, notBefore: gapStart) ?? from
        return String(source[from..<to])
    }

    /// Where to start instead, when the quote begins on the first word of an emphasised run.
    ///
    /// Mark "Collection event" in `**Collection event** --- the moment` and the words begin
    /// at the `C`, so the source they came from begins at the `C` too — and ends past the
    /// closing `**`, which is then hanging there with nothing that opened it. Literally
    /// correct, and it reads as though the asterisks were part of the sentence.
    ///
    /// So the opener is taken back in, but only when it is genuinely missing: the run
    /// immediately before the quote is only pulled in if the same run appears an odd number
    /// of times inside it. A quote that already contains its own pair is left alone.
    private func balancingOpener(before start: Int, upTo end: Int, notBefore floor: Int) -> Int? {
        var runStart = start
        while runStart > floor, isDelimiter(source[runStart - 1]) { runStart -= 1 }
        guard runStart < start, let marker = source[safe: start - 1] else { return nil }
        var length = 0
        while start - length - 1 >= runStart, source[start - length - 1] == marker { length += 1 }
        guard runs(of: marker, length: length, in: start..<end) % 2 == 1 else { return nil }
        return start - length
    }

    private func isDelimiter(_ ch: Character) -> Bool {
        ch == "*" || ch == "_" || ch == "~" || ch == "`"
    }

    /// How many maximal runs of exactly `length` `marker`s there are in a stretch of source.
    private func runs(of marker: Character, length: Int, in range: Range<Int>) -> Int {
        var count = 0
        var i = range.lowerBound
        while i < range.upperBound {
            guard source[i] == marker else { i += 1; continue }
            var run = 0
            while i + run < range.upperBound, source[i + run] == marker { run += 1 }
            if run == length { count += 1 }
            i += run
        }
        return count
    }

    /// The section a shadow index falls in.
    ///
    func section(at index: Int) -> Section? {
        sections.first { $0.range.contains(index) }
    }
}

// MARK: - Building one

extension MarkdownShadow {

    /// Read `markdown` the way `options` says Apex read it.
    ///
    /// The options matter to exactly two things here, and both are things that change what
    /// characters reach the page: smart typography, which turns three hyphens into one
    /// dash and so makes the file and the screen disagree, and the metadata block, which
    /// is either shown or set aside. Everything else in `MarkdownOptions` changes what the
    /// markup *means*, and this deliberately never has an opinion about that.
    static func build(_ markdown: String, options: MarkdownOptions) -> MarkdownShadow {
        var builder = Builder(source: Array(markdown), options: options)
        builder.run()
        return MarkdownShadow(text: String(builder.out), characters: builder.out,
                              origin: builder.origin, originEnd: builder.originEnd,
                              source: builder.source, sections: builder.sections)
    }
}

// MARK: - The scanner

private struct Builder {
    let source: [Character]
    let options: MarkdownOptions

    var out: [Character] = []
    var origin: [Int] = []
    var originEnd: [Int] = []
    var sections: [MarkdownShadow.Section] = []

    /// The open heading trail, outermost first, with the level each was opened at.
    private var headings: [(level: Int, text: String)] = []
    /// Footnote label -> the number it is rendered as.
    ///
    /// The label is not on the page. `[^tok]` renders as a `1`, because a renderer numbers
    /// footnotes in the order they are first referred to and throws the author's name for
    /// them away. Emitting the label instead put "tok" in the shadow where the page said
    /// "1", which cost every quote that ran through a footnote marker.
    private var footnoteNumbers: [String: Int] = [:]
    /// Where the current block started in `out`.
    private var blockStart = 0
    /// Whether the last thing emitted was a space, so runs collapse.
    private var pendingSpace = false

    init(source: [Character], options: MarkdownOptions) {
        self.source = source
        self.options = options
    }

    // MARK: Emitting

    private mutating func emit(_ ch: Character, from index: Int) {
        emit(ch, standingFor: index..<(index + 1))
    }

    /// A character, and the run of source it stands for — one character usually, three for
    /// the `---` behind an em dash, five for the `&amp;` behind an ampersand.
    private mutating func emit(_ ch: Character, standingFor range: Range<Int>) {
        if ch.isWhitespace {
            // Collapsed here rather than afterwards, because collapsing a built string
            // would have to rebuild the map alongside it and the two would drift.
            pendingSpace = !out.isEmpty
            return
        }
        if pendingSpace, !out.isEmpty, out.last != "\n" {
            out.append(" ")
            origin.append(range.lowerBound)
            originEnd.append(range.lowerBound)
        }
        pendingSpace = false
        out.append(ch)
        origin.append(range.lowerBound)
        originEnd.append(range.upperBound)
    }

    /// End the current block and record what was above it.
    private mutating func closeBlock(_ kind: MarkdownShadow.Section.Kind) {
        guard out.count > blockStart else { pendingSpace = false; return }
        sections.append(.init(range: blockStart..<out.count,
                              headings: headings.map(\.text), kind: kind))
        pendingSpace = false
        out.append("\n")
        // A separator belongs to nothing, so it points at whatever came last rather than
        // inventing an origin — `sourceText` never reads it, because a range that ends on
        // one is a range the locator has already refused.
        origin.append(origin.last ?? 0)
        originEnd.append(originEnd.last ?? 0)
        blockStart = out.count
    }

    // MARK: Lines

    /// Start offset and end offset (exclusive, not counting the newline) of each line.
    private var lines: [(start: Int, end: Int)] {
        var result: [(Int, Int)] = []
        var start = 0
        var i = 0
        while i < source.count {
            if source[i] == "\n" { result.append((start, i)); start = i + 1 }
            i += 1
        }
        if start < source.count { result.append((start, source.count)) }
        return result
    }

    mutating func run() {
        let lines = self.lines
        var i = 0

        // Footnote definitions are written where the author found it convenient and
        // rendered in a section at the foot of the page. The shadow follows the PAGE,
        // because the page is what the reviewer read and what the quote came off: a
        // definition left where it was written puts its words in the middle of a section
        // they are not in, and `Anchor.path` then narrows the search away from them.
        let footnotes = options.footnotes ? footnoteDefinitionLines(lines) : []

        // A metadata block, if the file opens with one. Set aside or shown, but either way
        // it must be accounted for: skipping it silently would leave every origin after it
        // correct (they are absolute) while showing text Apex did not render.
        if !options.showMetadata, let end = frontmatterEnd(lines) { i = end }

        while i < lines.count {
            if footnotes.contains(i) { i += 1; continue }
            let line = lines[i]
            let body = trimmedLead(line)

            if body.isEmpty { closeBlock(.prose); i += 1; continue }

            if let fence = fenceMarker(line) {
                i = emitFencedCode(from: i, lines: lines, fence: fence)
                continue
            }
            if isThematicBreak(line) { closeBlock(.prose); i += 1; continue }
            if let heading = atxHeading(line) {
                emitHeading(heading.text, level: heading.level)
                i += 1
                continue
            }
            if isSetextUnderline(line), !sections.isEmpty || out.count > blockStart {
                // The paragraph just gathered was a heading all along. Retitling it is
                // cheaper than looking ahead from every paragraph.
                promoteLastBlockToHeading(level: source[line.start] == "=" ? 1 : 2)
                i += 1
                continue
            }
            if isLinkReferenceDefinition(line) { i += 1; continue }
            if isTableSeparator(line) { i += 1; continue }
            if isTableRow(line) {
                emitTableRow(line)
                i += 1
                // A table is one block to the runtime, so its rows are one block here.
                if i >= lines.count || !(isTableRow(lines[i]) || isTableSeparator(lines[i])) {
                    closeBlock(.table)
                }
                continue
            }
            if isIndentedCode(line) {
                emitVerbatim(line, skipping: 4)
                i += 1
                if i >= lines.count || !isIndentedCode(lines[i]) { closeBlock(.code) }
                continue
            }

            // Anything else is prose: a paragraph, a list item, a quoted line, a footnote
            // definition. Each starts a block where its marker says it does, because the
            // runtime anchors on the innermost block and a `<li>` is one.
            let content = stripBlockMarkers(line)
            if content.startsNewBlock { closeBlock(.prose) }
            emitInline(from: content.start, to: line.end)
            // The newline ending a wrapped line is a space on the page. Not emitting one
            // welded the last word of each source line to the first word of the next, and
            // a quote spanning a line break then matched nothing — the single most common
            // shape a quote has, in a document wrapped at any width.
            pendingSpace = true
            i += 1
        }
        closeBlock(.prose)

        for index in footnotes.sorted() {
            let line = lines[index]
            let content = stripBlockMarkers(line)
            if content.startsNewBlock { closeBlock(.prose) }
            emitInline(from: content.start, to: line.end)
            pendingSpace = true
        }
        closeBlock(.prose)
    }

    /// Which lines belong to a footnote definition — the `[^1]: …` line and whatever is
    /// indented under it.
    private func footnoteDefinitionLines(_ lines: [(start: Int, end: Int)]) -> Set<Int> {
        var found: Set<Int> = []
        var i = 0
        while i < lines.count {
            guard footnoteDefinition(at: lines[i].start, limit: lines[i].end) != nil else {
                i += 1
                continue
            }
            found.insert(i)
            i += 1
            // Continuation: indented, or a blank line followed by more indented text.
            while i < lines.count {
                if trimmedLead(lines[i]).isEmpty,
                   i + 1 < lines.count, isIndentedCode(lines[i + 1]) {
                    found.insert(i); found.insert(i + 1)
                    i += 2
                    continue
                }
                guard isIndentedCode(lines[i]) else { break }
                found.insert(i)
                i += 1
            }
        }
        return found
    }

    // MARK: Block shapes

    private func frontmatterEnd(_ lines: [(start: Int, end: Int)]) -> Int? {
        guard let first = lines.first else { return nil }
        let opener = String(source[first.start..<first.end])
        guard opener == "---" || opener == "..." else { return nil }
        for i in 1..<lines.count {
            let text = String(source[lines[i].start..<lines[i].end])
            if text == "---" || text == "..." { return i + 1 }
        }
        return nil
    }

    private func trimmedLead(_ line: (start: Int, end: Int)) -> ArraySlice<Character> {
        var i = line.start
        while i < line.end, source[i] == " " || source[i] == "\t" { i += 1 }
        return source[i..<line.end]
    }

    private func fenceMarker(_ line: (start: Int, end: Int)) -> Character? {
        let body = trimmedLead(line)
        guard let first = body.first, first == "`" || first == "~" else { return nil }
        return body.prefix(3).count == 3 && body.prefix(3).allSatisfy({ $0 == first })
            ? first : nil
    }

    private func isThematicBreak(_ line: (start: Int, end: Int)) -> Bool {
        let body = trimmedLead(line).filter { !$0.isWhitespace }
        guard body.count >= 3, let first = body.first,
              first == "-" || first == "*" || first == "_" else { return false }
        return body.allSatisfy { $0 == first }
    }

    private func atxHeading(_ line: (start: Int, end: Int)) -> (level: Int, text: Range<Int>)? {
        var i = line.start
        while i < line.end, source[i] == " " { i += 1 }
        var level = 0
        while i < line.end, source[i] == "#", level < 7 { level += 1; i += 1 }
        guard (1...6).contains(level) else { return nil }
        guard i == line.end || source[i] == " " || source[i] == "\t" else { return nil }
        while i < line.end, source[i] == " " || source[i] == "\t" { i += 1 }
        // A closing run of hashes is decoration, not words.
        var end = line.end
        while end > i, source[end - 1] == " " { end -= 1 }
        var trailing = end
        while trailing > i, source[trailing - 1] == "#" { trailing -= 1 }
        if trailing < end, trailing > i, source[trailing - 1] == " " { end = trailing - 1 }
        return (level, i..<max(i, end))
    }

    private func isSetextUnderline(_ line: (start: Int, end: Int)) -> Bool {
        let body = trimmedLead(line)
        guard let first = body.first, first == "=" || first == "-" else { return false }
        return body.count >= 2 && body.allSatisfy { $0 == first }
    }

    private func isLinkReferenceDefinition(_ line: (start: Int, end: Int)) -> Bool {
        let body = trimmedLead(line)
        guard body.first == "[", !body.starts(with: ["[", "^"]) else { return false }
        guard let close = body.firstIndex(of: "]"), body.index(after: close) < body.endIndex
        else { return false }
        return body[body.index(after: close)] == ":"
    }

    private func isTableSeparator(_ line: (start: Int, end: Int)) -> Bool {
        let body = trimmedLead(line).filter { !$0.isWhitespace }
        guard body.count >= 3, body.contains("-") else { return false }
        return body.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" || $0 == "+" }
    }

    private func isTableRow(_ line: (start: Int, end: Int)) -> Bool {
        trimmedLead(line).first == "|"
    }

    private func isIndentedCode(_ line: (start: Int, end: Int)) -> Bool {
        guard line.end - line.start >= 4 else { return false }
        return source[line.start..<line.start + 4].allSatisfy { $0 == " " }
    }

    // MARK: Block emission

    private mutating func emitHeading(_ range: Range<Int>, level: Int) {
        closeBlock(.prose)
        let from = out.count
        emitInline(from: range.lowerBound, to: range.upperBound)
        let title = String(out[from..<out.count])
        while let last = headings.last, last.level >= level { headings.removeLast() }
        // Recorded BEFORE the block is closed, so a heading's own section carries itself —
        // which is what makes an annotation on a heading findable by its own path.
        sections.append(.init(range: from..<out.count, headings: headings.map(\.text) + [title],
                              kind: .heading))
        pendingSpace = false
        out.append("\n")
        origin.append(origin.last ?? 0)
        originEnd.append(originEnd.last ?? 0)
        blockStart = out.count
        headings.append((level, title))
    }

    private mutating func promoteLastBlockToHeading(level: Int) {
        // The paragraph it underlines is still open — a setext heading has no blank line
        // between the words and the rule — so it has to be closed before it can be found.
        closeBlock(.prose)
        guard let last = sections.indices.last else { return }
        let title = String(out[sections[last].range])
        sections[last].kind = .heading
        while let open = headings.last, open.level >= level { headings.removeLast() }
        sections[last].headings = headings.map(\.text) + [title]
        headings.append((level, title))
    }

    private mutating func emitFencedCode(from index: Int, lines: [(start: Int, end: Int)],
                                         fence: Character) -> Int {
        closeBlock(.prose)
        var i = index + 1
        while i < lines.count {
            let body = trimmedLead(lines[i])
            if body.count >= 3, body.prefix(3).allSatisfy({ $0 == fence }) { i += 1; break }
            // Verbatim: inside a fence there is no markup, and a `*` is a `*`.
            emitVerbatim(lines[i], skipping: 0)
            emit("\n", from: lines[i].end)
            i += 1
        }
        closeBlock(.code)
        return i
    }

    private mutating func emitVerbatim(_ line: (start: Int, end: Int), skipping: Int) {
        var i = min(line.start + skipping, line.end)
        while i < line.end { emit(source[i], from: i); i += 1 }
    }

    private mutating func emitTableRow(_ line: (start: Int, end: Int)) {
        var i = line.start
        while i < line.end, source[i] != "|" { i += 1 }
        var cellStart = i + 1
        i = cellStart
        while i < line.end {
            if source[i] == "|" && !isEscaped(i) {
                emitInline(from: cellStart, to: i)
                // The runtime puts a space between cells, because a `<td>` is not inline.
                pendingSpace = true
                cellStart = i + 1
            }
            i += 1
        }
        if cellStart < line.end { emitInline(from: cellStart, to: line.end) }
        pendingSpace = true
    }

    /// Where a line's content starts once its list, quote or footnote marker is off, and
    /// whether that marker begins a new block.
    private func stripBlockMarkers(_ line: (start: Int, end: Int))
        -> (start: Int, startsNewBlock: Bool) {
        var i = line.start
        var started = false
        while i < line.end {
            while i < line.end, source[i] == " " || source[i] == "\t" { i += 1 }
            if i < line.end, source[i] == ">" {
                i += 1
                if i < line.end, source[i] == " " { i += 1 }
                continue    // a quote marker does not itself open a block; its content does
            }
            if let after = listMarker(at: i, limit: line.end) { i = after; started = true; continue }
            // A definition's `:` is the marker that makes a `<dd>`, not a colon on the
            // page. The term above it needs no stripping: it is a plain line.
            if options.definitionLists, i < line.end, source[i] == ":",
               i + 1 < line.end, source[i + 1] == " " || source[i + 1] == "\t" {
                i += 1
                while i < line.end, source[i] == " " || source[i] == "\t" { i += 1 }
                started = true
                continue
            }
            if let after = footnoteDefinition(at: i, limit: line.end) { i = after; started = true }
            break
        }
        return (i, started)
    }

    private func listMarker(at index: Int, limit: Int) -> Int? {
        var i = index
        guard i < limit else { return nil }
        if source[i] == "-" || source[i] == "+" || source[i] == "*" {
            i += 1
        } else if source[i].isNumber {
            while i < limit, source[i].isNumber { i += 1 }
            guard i < limit, source[i] == "." || source[i] == ")" else { return nil }
            i += 1
        } else {
            return nil
        }
        guard i < limit, source[i] == " " || source[i] == "\t" else { return nil }
        while i < limit, source[i] == " " || source[i] == "\t" { i += 1 }
        // A task list's box is a control, not a word. The runtime reads the checkbox as an
        // element with no text, so the shadow must not read it as "[x]".
        if i + 2 < limit, source[i] == "[",
           source[i + 1] == " " || source[i + 1] == "x" || source[i + 1] == "X",
           source[i + 2] == "]" {
            i += 3
            while i < limit, source[i] == " " { i += 1 }
        }
        return i
    }

    private func footnoteDefinition(at index: Int, limit: Int) -> Int? {
        guard index + 1 < limit, source[index] == "[", source[index + 1] == "^" else { return nil }
        var i = index + 2
        while i < limit, source[i] != "]" { i += 1 }
        guard i + 1 < limit, source[i] == "]", source[i + 1] == ":" else { return nil }
        i += 2
        while i < limit, source[i] == " " { i += 1 }
        return i
    }

    private func isEscaped(_ index: Int) -> Bool {
        var backslashes = 0
        var i = index - 1
        while i >= 0, source[i] == "\\" { backslashes += 1; i -= 1 }
        return backslashes % 2 == 1
    }

    // MARK: Inline

    /// Emit the visible text of `from..<to`, dropping the markup around it.
    ///
    /// Everything it drops it drops for one reason: the character is not on the screen. A
    /// reader never sees the asterisks around a bold word, the URL behind a link, or the
    /// backticks around a code span — and neither does the runtime, which builds its quote
    /// from the DOM's text nodes.
    private mutating func emitInline(from: Int, to: Int) {
        var i = from
        while i < to {
            let ch = source[i]

            if ch == "\\", i + 1 < to, source[i + 1].isPunctuation || source[i + 1].isSymbol {
                emit(source[i + 1], from: i + 1)
                i += 2
                continue
            }

            if ch == "`" {
                var run = 0
                while i + run < to, source[i + run] == "`" { run += 1 }
                if let close = closingBacktickRun(after: i + run, to: to, length: run) {
                    var j = i + run
                    while j < close { emit(source[j], from: j); j += 1 }
                    i = close + run
                    continue
                }
            }

            // An image contributes no text at all: `<img>` has no text node, so the
            // runtime's quote steps straight over it. Its alt text is only ever read for a
            // block that would otherwise be empty — see `describeEmpty` in review.js.
            if ch == "!", i + 1 < to, source[i + 1] == "[", !isEscaped(i) {
                if let end = skipLinkLike(openBracket: i + 1, to: to) { i = end; continue }
            }

            if ch == "[", !isEscaped(i) {
                // A wiki link shows its label and hides its target — but only where the
                // dialect has wiki links at all. Switched off, `[[Page]]` is four brackets
                // and a word, and the page says so.
                if options.wikiLinks, i + 1 < to, source[i + 1] == "[",
                   let wiki = wikiLink(at: i, to: to) {
                    var j = wiki.label.lowerBound
                    while j < wiki.label.upperBound { emit(source[j], from: j); j += 1 }
                    i = wiki.end
                    continue
                }
                // A footnote reference renders as a number in a `<sup>`, and `<sup>` is
                // inline — so the number IS part of the quote, with no space around it.
                if options.footnotes, i + 1 < to, source[i + 1] == "^" {
                    var j = i + 2
                    var label = ""
                    while j < to, source[j] != "]" { label.append(source[j]); j += 1 }
                    if j < to {
                        // Spelled out rather than written with `??` and a closure: the
                        // short form reads the dictionary on one side and writes it on the
                        // other, which is two overlapping accesses to the same property
                        // inside a `mutating` method.
                        let number: Int
                        if let existing = footnoteNumbers[label] {
                            number = existing
                        } else {
                            number = footnoteNumbers.count + 1
                            footnoteNumbers[label] = number
                        }
                        // Every digit stands for the whole `[^label]`, so a quote ending on
                        // the marker takes the marker's source with it and no more.
                        for digit in String(number) { emit(digit, standingFor: i..<(j + 1)) }
                        i = j + 1
                        continue
                    }
                }
                if let text = linkText(openBracket: i, to: to) {
                    emitInline(from: text.textRange.lowerBound, to: text.textRange.upperBound)
                    i = text.end
                    continue
                }
            }

            if ch == "<", let end = autolink(at: i, to: to) {
                var j = i + 1
                while j < end - 1 { emit(source[j], from: j); j += 1 }
                i = end
                continue
            }

            if ch == "{", options.criticMarkup, let critic = criticSpan(at: i, to: to) {
                emitInline(from: critic.inner.lowerBound, to: critic.inner.upperBound)
                i = critic.end
                continue
            }

            if isEmphasisMarker(at: i, to: to) {
                let marker = ch
                while i < to, source[i] == marker { i += 1 }
                continue
            }

            if ch == "&", let entity = entity(at: i, to: to) {
                emit(entity.character, standingFor: i..<entity.end)
                i = entity.end
                continue
            }

            if options.smartTypography, let smart = smartRun(at: i, to: to) {
                emit(smart.character, standingFor: i..<smart.end)
                i = smart.end
                continue
            }

            emit(ch, from: i)
            i += 1
        }
    }

    private func closingBacktickRun(after index: Int, to: Int, length: Int) -> Int? {
        var i = index
        while i < to {
            if source[i] == "`" {
                var run = 0
                while i + run < to, source[i + run] == "`" { run += 1 }
                if run == length { return i }
                i += run
            } else {
                i += 1
            }
        }
        return nil
    }

    /// `[text](url)`, `[text][ref]`, `[text]` — the text and where the whole thing ends.
    private func linkText(openBracket: Int, to: Int)
        -> (textRange: Range<Int>, end: Int)? {
        var depth = 0
        var i = openBracket
        while i < to {
            if source[i] == "[", !isEscaped(i) { depth += 1 }
            else if source[i] == "]", !isEscaped(i) {
                depth -= 1
                if depth == 0 { break }
            }
            i += 1
        }
        guard i < to, depth == 0 else { return nil }
        let text = (openBracket + 1)..<i
        var end = i + 1
        if end < to, source[end] == "(" {
            var parens = 0
            var j = end
            while j < to {
                if source[j] == "(", !isEscaped(j) { parens += 1 }
                else if source[j] == ")", !isEscaped(j) {
                    parens -= 1
                    if parens == 0 { end = j + 1; break }
                }
                j += 1
            }
        } else if end < to, source[end] == "[" {
            var j = end
            while j < to, source[j] != "]" { j += 1 }
            if j < to { end = j + 1 }
        }
        return (text, end)
    }

    private func skipLinkLike(openBracket: Int, to: Int) -> Int? {
        linkText(openBracket: openBracket, to: to)?.end
    }

    /// `[[Target]]` or `[[Target|Label]]` — what is shown, and where it ends.
    private func wikiLink(at index: Int, to: Int) -> (label: Range<Int>, end: Int)? {
        var i = index + 2
        var pipe: Int?
        while i + 1 < to {
            if source[i] == "|", pipe == nil { pipe = i }
            if source[i] == "]", source[i + 1] == "]" {
                let start = pipe.map { $0 + 1 } ?? (index + 2)
                return (start..<i, i + 2)
            }
            i += 1
        }
        return nil
    }

    private func autolink(at index: Int, to: Int) -> Int? {
        var i = index + 1
        var sawColon = false
        while i < to, source[i] != ">" {
            if source[i].isWhitespace { return nil }
            if source[i] == ":" || source[i] == "@" { sawColon = true }
            i += 1
        }
        guard i < to, sawColon, i > index + 1 else { return nil }
        return i + 1
    }

    /// `{++inserted++}` and its siblings. The braces and markers are drawn as a mark, not
    /// as text; what is inside them is the words.
    private func criticSpan(at index: Int, to: Int) -> (inner: Range<Int>, end: Int)? {
        let openers = ["++", "--", "==", ">>", "~~"]
        guard index + 3 < to else { return nil }
        let marker = String(source[(index + 1)...(index + 2)])
        guard openers.contains(marker) else { return nil }
        // `{>> comment <<}` is the one that does not close with what it opened with.
        let closer = Array(marker == ">>" ? "<<}" : marker + "}")
        var i = index + 3
        while i + closer.count <= to {
            if Array(source[i..<(i + closer.count)]) == closer {
                return ((index + 3)..<i, i + closer.count)
            }
            i += 1
        }
        return nil
    }

    /// Whether the run of markers at `index` is emphasis rather than punctuation.
    ///
    /// Deliberately crude, and crude in the safe direction. `*` and `_` in a run are taken
    /// as markers; a lone `~` is not, because a subscript and a stray tilde look identical
    /// and dropping a real character is worse than keeping a marker — a kept marker fails
    /// to match and gets reported, a dropped character matches the wrong place.
    private func isEmphasisMarker(at index: Int, to: Int) -> Bool {
        guard !isEscaped(index) else { return false }
        let ch = source[index]
        guard ch == "*" || ch == "_" || ch == "~" || ch == "^" else { return false }
        var run = 0
        while index + run < to, source[index + run] == ch { run += 1 }
        if ch == "~" { return run == 2 && options.strikethrough }
        if ch == "^" { return options.supSub && run == 1 }
        // A marker has something on one side of it and not whitespace on the other.
        let before: Character? = index > 0 ? source[index - 1] : nil
        let after: Character? = index + run < to ? source[index + run] : nil
        if before == nil || before!.isWhitespace { return after != nil && !after!.isWhitespace }
        if after == nil || after!.isWhitespace { return true }
        return true
    }

    private func entity(at index: Int, to: Int) -> (character: Character, end: Int)? {
        var i = index + 1
        var name = ""
        while i < to, source[i] != ";", name.count < 10 { name.append(source[i]); i += 1 }
        guard i < to, source[i] == ";" else { return nil }
        let map: [String: Character] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
            "mdash": "—", "ndash": "–", "hellip": "…", "copy": "©", "reg": "®",
        ]
        guard let ch = map[name] else { return nil }
        return (ch, i + 1)
    }

    /// What smart typography does to the file on its way to the screen.
    ///
    /// Only the length-changing ones are handled here. Quotes are left straight on purpose:
    /// `MarkdownLocator` folds the curly ones out of the rendered quote instead, which
    /// avoids having to work out which of `"` and `"` Apex chose at a given point — and
    /// getting that wrong would break every quote containing an apostrophe.
    private func smartRun(at index: Int, to: Int) -> (character: Character, end: Int)? {
        if source[index] == "-" {
            if index + 2 < to, source[index + 1] == "-", source[index + 2] == "-" {
                return ("—", index + 3)
            }
            if index + 1 < to, source[index + 1] == "-" { return ("–", index + 2) }
        }
        if source[index] == ".", index + 2 < to, source[index + 1] == ".", source[index + 2] == "." {
            return ("…", index + 3)
        }
        return nil
    }
}
