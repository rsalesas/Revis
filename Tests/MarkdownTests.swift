import Testing
import Foundation
@testable import Revis

/// Reading Markdown, and finding the way back.
///
/// The reason this file is long relative to what it covers: the shadow is the one piece
/// of this app that can be *quietly* wrong. A sanitizer that fails leaves a script in the
/// page and a test catches it; a shadow that drops one character too many still produces
/// an export, still quotes something, and points a reader at the wrong sentence. So the
/// central test here is not that the mapping works on a case somebody thought of — it is
/// that the shadow's text and the RENDERED text are the same string, checked against Apex
/// itself, on a document with one of everything in it.
struct MarkdownTests {

    static func fixture(_ name: String) -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    static var spec: String { fixture("retention-spec.md") }

    /// The visible text of some HTML, the way `review.js` builds a quote: tags out, and a
    /// space wherever a non-inline element separates two words.
    static func visibleText(_ html: String) -> String {
        let inline: Set<String> = [
            "a", "abbr", "b", "bdi", "bdo", "cite", "code", "data", "del", "dfn", "em", "i",
            "ins", "kbd", "mark", "q", "ruby", "s", "samp", "small", "span", "strong",
            "sub", "sup", "time", "u", "var", "wbr",
        ]
        var out = ""
        var i = html.startIndex
        while i < html.endIndex {
            guard html[i] == "<" else {
                out.append(html[i])
                i = html.index(after: i)
                continue
            }
            guard let close = html[i...].firstIndex(of: ">") else { break }
            let raw = html[html.index(after: i)..<close]
                .drop(while: { $0 == "/" })
                .prefix(while: { !$0.isWhitespace && $0 != "/" && $0 != ">" })
            if !inline.contains(raw.lowercased()) { out += " " }
            i = html.index(after: close)
        }
        return HTMLSanitizer.decodeEntities(out)
    }

    static func flatten(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    // MARK: - The shadow says what the page says

    /// The whole map rests on this. If the shadow's text and the page's text are the same
    /// string, then a quote taken off the page can be found in the shadow, and the shadow
    /// knows where in the file each of its characters came from.
    ///
    /// The one permitted difference is generated content — the `↩` Apex puts at the end of
    /// a footnote is not in the file and must not be in the shadow.
    @Test func shadowReproducesTheRenderedText() {
        let options = MarkdownOptions.default
        let rendered = Self.flatten(Self.visibleText(
            MarkdownRenderer.html(for: Self.spec, options: options)))
        let shadow = Self.flatten(
            MarkdownShadow.build(Self.spec, options: options).text
                .replacingOccurrences(of: "\n", with: " "))
        #expect(rendered.replacingOccurrences(of: " ↩", with: "") == shadow)
    }

    @Test func shadowSurvivesAnEmptyDocumentAndOnlyMetadata() {
        #expect(MarkdownShadow.build("", options: .default).text.isEmpty)
        #expect(MarkdownShadow.build("---\ntitle: x\n---\n", options: .default)
            .text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    // MARK: - Finding the words in the file

    private func locate(_ quote: String, prefix: String = "", suffix: String = "",
                        path: String = "") -> MarkdownLocator.Match? {
        let shadow = MarkdownShadow.build(Self.spec, options: .default)
        return MarkdownLocator.locate(
            Anchor(blocks: [0], path: path, role: "paragraph", quote: quote,
                   prefix: prefix, suffix: suffix, start: 0, end: quote.count, rect: nil),
            in: shadow)
    }

    /// The case the whole feature exists for: the words on the page have markup through
    /// the middle of them in the file, and what comes back is the file's spelling.
    @Test func quotesTheSourceWhenMarkupIsInTheWay() throws {
        // §3.2 says the same sentence without the markup, deliberately — so the words
        // either side are what picks §3.1's copy, and the markup comes back with it.
        let found = try #require(locate("is retained for a period of ninety (90) days from",
                                        prefix: "All personal data "))
        #expect(found.sourceQuote == "is **retained for a period of ninety (90) days** from")
        #expect(found.confidence == .byContext)
    }

    /// A quote that starts on the first word of an emphasised run must not come back with
    /// a closing `**` and nothing that opened it.
    @Test func takesTheOpeningDelimiterBackWhenItWouldOtherwiseDangle() throws {
        #expect(try #require(locate("Collection event — the moment")).sourceQuote
                == "**Collection event** --- the moment")
    }

    @Test func findsAQuoteThatCrossesAWrappedLine() throws {
        let found = try #require(locate("from the date of collection"))
        #expect(found.sourceQuote.contains("\n"))
        #expect(Self.flatten(found.sourceQuote) == "from the date of collection")
    }

    @Test func keepsTheLinkAndTheCodeSpanAsTheFileWritesThem() throws {
        #expect(try #require(locate("see the retention policy for the rules")).sourceQuote
                == "see [the retention policy](https://example.com/policy) for the rules")
        #expect(try #require(locate("note that MAX_AGE is not configurable")).sourceQuote
                == "note that `MAX_AGE` is not configurable")
    }

    /// Smart typography is the one setting that makes the file and the screen disagree
    /// about characters rather than about markup, and an em dash is three hyphens.
    @Test func mapsSmartPunctuationBackToTheHyphensThatMadeIt() throws {
        let found = try #require(locate("event — the moment"))
        #expect(found.sourceQuote == "event** --- the moment")
    }

    /// A footnote's marker on the page is a number the renderer assigned, not the label the
    /// author wrote. `[^tok]` reads as `1`, and a quote running through it says `1`.
    @Test func aFootnoteMarkerIsTheNumberThePageShows() throws {
        #expect(try #require(locate("Session tokens1")).sourceQuote == "Session tokens[^tok]")
    }

    /// A table cell is a quote like any other, and must not drag the cell wall with it.
    @Test func quotesATableCellWithoutItsPipes() throws {
        let found = try #require(locate("From last contact"))
        #expect(found.sourceQuote == "From last contact")
    }

    /// A footnote's text is written in the middle of the document and rendered at the
    /// bottom of it. It has to be findable either way.
    @Test func findsTextThatTheRendererMoved() throws {
        #expect(try #require(locate("Tokens are rotated on each sign-in.")).sourceQuote
                == "Tokens are rotated on each sign-in.")
    }

    // MARK: - Saying so when it cannot

    /// The failure that matters. §3.1 and §3.2 say the same sentence on purpose; an
    /// annotation on one of them must not be answered with the other, and where nothing
    /// separates them the export has to be told that too.
    @Test func doesNotSilentlyPickBetweenTwoIdenticalSentences() throws {
        let repeated = "retained for a period of ninety (90) days from the date of collection"
        #expect(try #require(locate(repeated)).confidence == .ambiguous)

        // The words either side are exactly what the anchor keeps them for.
        let picked = try #require(locate(repeated, suffix: ", which is a different rule"))
        #expect(picked.confidence == .byContext)
        #expect(!picked.sourceQuote.contains("**"))   // §3.2's copy, which has no markup
    }

    /// Content the renderer invented has no place in the file, and is reported as absent
    /// rather than approximated to the nearest thing.
    @Test func refusesWordsThatAreNotInTheFile() {
        #expect(locate("↩") == nil)
        #expect(locate("retained for a period of thirty (30) days") == nil)
    }

    @Test func readsATrailingOrdinalOffAPathWithoutEatingAHeading() {
        #expect(MarkdownLocator.headingSegments(of: "3. Retention › 3.1 Personal › paragraph 1")
                == ["3. Retention", "3.1 Personal"])
        #expect(MarkdownLocator.headingSegments(of: "3. Retention › 3.1 Personal")
                == ["3. Retention", "3.1 Personal"])
        // "Section 2" is a heading somebody wrote, not the runtime's counter.
        #expect(MarkdownLocator.headingSegments(of: "Section 2") == ["Section 2"])
    }

    // MARK: - What the document carries

    /// The invariant that makes a review of a Markdown file reopenable: the source and the
    /// settings travel with it, and a review written before either existed still opens.
    @Test func theReviewCarriesTheSourceAndTheSettings() throws {
        let prepared = DocumentPrep.prepare(markdown: Self.spec, baseURL: nil,
                                            options: .default)
        #expect(prepared.markdown?.text == Self.spec)
        #expect(prepared.markdown?.options == .default)
        #expect(prepared.title == "Data Retention Specification")

        let file = ReviewFile(source: SourceInfo(name: "spec.md", path: nil,
                                                 capturedAt: .reviewStamp, digest: ""),
                              document: prepared)
        let round = try JSONDecoder.revis.decode(
            ReviewFile.self, from: try JSONEncoder.revis.encode(file))
        #expect(round.document.markdown == prepared.markdown)
    }

    /// The trap `Annotation.init(from:)` is written up for, checked one type along: a
    /// `.revis` from before Markdown existed has no `markdown` key at all, and must open
    /// as the document it is rather than being mistaken for HTML.
    @Test func aReviewWrittenBeforeMarkdownExistedStillOpens() throws {
        // Written out in full, the way the encoder writes one — including every field of
        // the report, because `SanitizationReport` is decoded by the synthesised decoder
        // too and an absent key there throws just the same.
        let json = """
        {"format":1,"app":"Revis 0.1.0","annotations":[],
         "source":{"name":"a.html","capturedAt":"2025-01-01T00:00:00Z","digest":""},
         "document":{"body":"<p>hi</p>","css":"","missingImages":[],
                     "report":{"scripts":0,"eventHandlers":0,"frames":0,"interactive":0,
                                "remoteResources":0,"dangerousURLs":0}}}
        """
        let file = try JSONDecoder.revis.decode(ReviewFile.self, from: Data(json.utf8))
        #expect(file.document.markdown == nil)
        #expect(file.document.body == "<p>hi</p>")
    }

    // MARK: - Reading it again

    /// Changing the dialect makes a different document, and the annotations were made
    /// against the old one. What matters is not that they survive — some cannot — but that
    /// the ones that do not are handed back rather than left to be noticed.
    @MainActor
    @Test func rereadingReportsTheMarksItCouldNotPlace() {
        let prepared = DocumentPrep.prepare(markdown: Self.spec, baseURL: nil,
                                            options: .default)
        let file = ReviewFile(source: SourceInfo(name: "spec.md", path: nil,
                                                 capturedAt: .reviewStamp, digest: ""),
                              document: prepared)
        let model = ReviewModel(file: file, appSettings: AppSettings(defaults: scratch()))

        // One mark on words that only exist because footnotes are on — the marker is a
        // number the renderer assigned — and one on ordinary prose that is there either way.
        model.annotations = [
            annotation(quote: "Session tokens1"),
            annotation(quote: "Deletion is irreversible."),
        ]

        var options = MarkdownOptions.default
        options.footnotes = false
        let disturbed = model.reread(with: options)

        #expect(model.markdownOptions?.footnotes == false)
        #expect(model.prepared.body.contains("[^tok]"))    // now literal, not a marker
        #expect(disturbed.count == 1)
        #expect(disturbed.first?.anchor.quote == "Session tokens1")
        // Nothing is deleted: a mark that cannot be placed is still in the review.
        #expect(model.annotations.count == 2)
    }

    /// Re-reading with the settings it already has is not a re-render, so it cannot
    /// disturb anything.
    @MainActor
    @Test func rereadingWithTheSameSettingsDoesNothing() {
        let prepared = DocumentPrep.prepare(markdown: Self.spec, baseURL: nil,
                                            options: .default)
        let file = ReviewFile(source: SourceInfo(name: "spec.md", path: nil,
                                                 capturedAt: .reviewStamp, digest: ""),
                              document: prepared)
        let model = ReviewModel(file: file, appSettings: AppSettings(defaults: scratch()))
        model.annotations = [annotation(quote: "Deletion is irreversible.")]
        #expect(model.reread(with: .default).isEmpty)
        #expect(model.prepared == prepared)
    }

    private func annotation(quote: String) -> Annotation {
        Annotation(author: "RS", intent: .change, note: "x",
                   anchor: Anchor(blocks: [0], path: "", role: "paragraph", quote: quote,
                                  prefix: "", suffix: "", start: 0, end: quote.count,
                                  rect: nil))
    }

    /// Preferences that do not touch the reviewer's own.
    private func scratch() -> UserDefaults {
        UserDefaults(suiteName: "app.revis.tests.\(UUID().uuidString)") ?? .standard
    }

    // MARK: - The export

    @Test func theExportQuotesTheSourceAndNamesTheDialect() {
        let prepared = DocumentPrep.prepare(markdown: Self.spec, baseURL: nil,
                                            options: .default)
        let anchor = Anchor(blocks: [0], path: "3. Retention periods › 3.1 Personal data",
                            role: "paragraph",
                            quote: "is retained for a period of ninety (90) days from",
                            prefix: "All personal data ", suffix: " the date of",
                            start: 0, end: 10, rect: nil)
        let file = ReviewFile(
            source: SourceInfo(name: "spec.md", path: nil, capturedAt: .reviewStamp,
                               digest: ""),
            document: prepared,
            annotations: [Annotation(author: "RS", intent: .change,
                                     note: "Make this 30 days.", anchor: anchor)])

        let markdown = ReviewExport.markdown(file)
        #expect(markdown.contains("**Format** Markdown"))
        #expect(markdown.contains("The document is Markdown"))
        // The file's spelling leads; the page's reading is given underneath.
        #expect(markdown.contains("> is **retained for a period of ninety (90) days** from"))
        #expect(markdown.contains("**As it reads on the page**"))

        #expect(ReviewExport.json(file).contains("\"sourceQuote\""))
    }

    /// An HTML document must come out exactly as it did before any of this existed — no
    /// format line, no note about a source file it does not have.
    @Test func anHTMLDocumentIsUntouchedByAnyOfThis() {
        let prepared = DocumentPrep.prepare(html: "<h1>T</h1><p>Hello there</p>", baseURL: nil)
        let file = ReviewFile(
            source: SourceInfo(name: "a.html", path: nil, capturedAt: .reviewStamp,
                               digest: ""),
            document: prepared,
            annotations: [Annotation(
                author: "RS", intent: .change, note: "x",
                anchor: Anchor(blocks: [0], path: "", role: "paragraph",
                               quote: "Hello there", prefix: "", suffix: "",
                               start: 0, end: 11, rect: nil))])
        let markdown = ReviewExport.markdown(file)
        #expect(!markdown.contains("**Format** Markdown"))
        #expect(!markdown.contains("The document is Markdown"))
        #expect(markdown.contains("> Hello there"))
    }

    // MARK: - What the renderer is not allowed to do

    /// Not a preference. A document that can pull in another file is a document that can
    /// read the reviewer's disk, and the containment check that guards images does not
    /// exist inside Apex.
    @Test func aDocumentCannotPullInAnotherFile() {
        let html = MarkdownRenderer.html(
            for: "Before\n\n{{/etc/passwd}}\n\n<<[/etc/hosts]\n\nAfter", options: .default)
        #expect(!html.contains("root:"))
        #expect(html.contains("Before"))
        #expect(html.contains("After"))
    }

    /// The mode presets turn this on for three of the six dialects, and with it on an
    /// ordinary pipe table loses its header row. A specification whose column headings
    /// have quietly become data is not the document that was sent.
    @Test func anOrdinaryTableKeepsItsHeader() {
        let table = "| Field | Days |\n|---|---|\n| Email | 90 |\n"
        for mode in MarkdownMode.allCases {
            var options = MarkdownOptions.default
            options.mode = mode
            #expect(MarkdownRenderer.html(for: table, options: options).contains("<th>"),
                    "\(mode.rawValue) lost the table header")
        }
    }
}
