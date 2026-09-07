import Testing
import Foundation
@testable import Revis

/// What the runtime actually does, in the engine that ships it.
@MainActor
struct RuntimeTests {

    // MARK: - Stamping

    /// The blocks the runtime stamps are the blocks `ReviewFixtures` says it stamps.
    ///
    /// This is the test that would have saved the afternoon. The fixtures carried
    /// hand-written block numbers, every one of them wrong, and nothing could tell —
    /// an anchor naming a block that is not there draws no mark, correctly and silently.
    /// Now the mirror is checked against the thing it mirrors.
    @Test func theWalkAgreesWithTheRuntime() async throws {
        let page = RuntimeHarness.spec()
        let ready = await page.wait(for: "ready")
        let mirrored = ReviewFixtures.document().blocks

        let stamped = ready["blocks"] as? Int ?? -1
        #expect(stamped == mirrored.count,
                "runtime stamped \(stamped), the walk says \(mirrored.count)")

        // Not just the count: every index has to name the same words, the same role and the
        // same path, or two walks that happen to agree on how many is a coincidence waiting
        // to be relied on.
        //
        // Read through `rvCaptureBlock`, which is the runtime's own answer to "what is this
        // block" — not through `textContent`, which is a different question and the wrong
        // one: it concatenates a table's cells with nothing between them.
        for block in mirrored {
            let json = try await page.string("window.rvCaptureBlock(\(block.index))")
            let captured = try #require(Anchor.decode(json), "no block \(block.index)")
            #expect(captured.quote == block.text, "block \(block.index) reads differently")
            #expect(captured.role == block.role, "block \(block.index) has another role")
            #expect(captured.path == block.path, "block \(block.index) has another path")
        }
    }

    /// The rule that decides which element carries an anchor, checked where it bites.
    @Test func aContainerYieldsItsBlockAndATableYieldsItself() async throws {
        let page = RuntimeHarness.spec()
        _ = await page.wait(for: "ready")
        // The callout is a div wrapping a paragraph: the paragraph is stamped, not the div.
        #expect(try await page.int("document.querySelectorAll('div[data-rv]').length") == 0)
        #expect(try await page.int("document.querySelectorAll('table[data-rv]').length") == 1)
        #expect(try await page.int("document.querySelectorAll('td[data-rv]').length") == 0)
    }

    // MARK: - Anchoring

    /// A captured selection measures its offsets against its BLOCK.
    ///
    /// The other fault this session found, and the one that hid best: measured against the
    /// document the numbers are plausible, out of range, and `positionAt` clamps rather
    /// than failing — so every highlight became an empty range at the end of its paragraph.
    /// In four pages that looked like a rounding error.
    @Test func aCapturedSelectionMeasuresOffsetsAgainstItsBlock() async throws {
        let page = RuntimeHarness.spec()
        _ = await page.wait(for: "ready")

        // Select "ninety (90) days" where it really occurs, by walking to it rather than by
        // naming an offset — the offset is the thing under test.
        try await page.eval("""
        (function () {
          var block = document.querySelector('[data-rv="12"]');
          var node = block.firstChild;
          var at = node.nodeValue.indexOf('ninety (90) days');
          var range = document.createRange();
          range.setStart(node, at);
          range.setEnd(node, at + 'ninety (90) days'.length);
          var sel = window.getSelection();
          sel.removeAllRanges();
          sel.addRange(range);
        })();
        """)
        let json = try await page.string("window.rvCaptureSelection()")
        let anchor = try #require(Anchor.decode(json))

        #expect(anchor.quote == "ninety (90) days")
        #expect(anchor.blocks == [12])
        // The block is ~200 characters; a document-wide offset would be in the hundreds.
        let blockLength = try await page.int(
            "document.querySelector('[data-rv=\"12\"]').textContent.replace(/\\s+/g,' ')"
                + ".trim().length")
        #expect(anchor.end <= blockLength,
                "offset \(anchor.end) is past a block of \(blockLength)")
        #expect(anchor.start == 46, "expected the offset within the block")
    }

    /// And the fixture builds the same anchor the runtime would have.
    @Test func theFixtureAgreesWithACapturedAnchor() async throws {
        let page = RuntimeHarness.spec()
        _ = await page.wait(for: "ready")
        try await page.eval("""
        (function () {
          var block = document.querySelector('[data-rv="12"]');
          var node = block.firstChild;
          var at = node.nodeValue.indexOf('ninety (90) days');
          var range = document.createRange();
          range.setStart(node, at);
          range.setEnd(node, at + 'ninety (90) days'.length);
          var sel = window.getSelection();
          sel.removeAllRanges();
          sel.addRange(range);
        })();
        """)
        let captured = try #require(
            Anchor.decode(try await page.string("window.rvCaptureSelection()")))
        let built = ReviewFixtures.anchor("ninety (90) days", in: ReviewFixtures.document())

        #expect(built.blocks == captured.blocks)
        #expect(built.start == captured.start)
        #expect(built.end == captured.end)
        #expect(built.role == captured.role)
        #expect(built.path == captured.path)
    }

    // MARK: - Drawing

    /// Marks are drawn, one per annotation, and they carry an image.
    ///
    /// An empty gutter has been diagnosed three different ways in this project — a list
    /// that failed to parse, a block index that was not there, an image map that had not
    /// arrived. All three produce a mark that is present and invisible, or absent and
    /// silent. This asserts both halves.
    @Test func everyAnnotationGetsAMarkWithAnImage() async throws {
        let page = RuntimeHarness.spec()
        _ = await page.wait(for: "ready")
        // Raw, not quoted: the app interpolates these as object literals, and a string
        // where an object belongs leaves `colours` and `images` unusable — which draws
        // marks with no background, the exact "present and invisible" failure this asserts
        // against.
        try await page.eval("window.rvSetColours(\(AnnotationPalette.json()),"
            + " \(AnnotationSymbols.json()));")
        try await page.setAnnotations([
            ["id": "a", "intent": "change", "status": "open", "blocks": [3],
             "start": 0, "end": 4],
            ["id": "b", "intent": "question", "status": "open", "blocks": [9],
             "start": 0, "end": 4],
            ["id": "c", "intent": "comment", "status": "resolved", "blocks": [12],
             "start": 0, "end": 4],
        ])
        #expect(try await page.int("document.querySelectorAll('#rv-gutter .rv-marker').length")
                    == 3)
        // Present is not enough: a mark with no background is a mark nobody can see.
        #expect(try await page.int("""
        Array.prototype.filter.call(
          document.querySelectorAll('#rv-gutter .rv-marker'),
          function (m) { return m.style.backgroundImage
                             && m.style.backgroundImage !== 'none'; }).length
        """) == 3)
    }

    /// A list that will not parse is REPORTED. It used to empty itself in silence.
    @Test func anUnreadableListOfAnnotationsComplains() async throws {
        let page = RuntimeHarness.spec()
        _ = await page.wait(for: "ready")
        try await page.eval("window.rvSetAnnotations('{ not json');")
        try await page.settle()
        let complaint = page.posts.last { $0.name == "error" }
        #expect(complaint != nil, "a broken list said nothing at all")
        #expect(complaint?.payload["stage"] as? String == "annotations")
    }

    /// Pressing a mark says which annotation it was — the route from the page back to the
    /// pane, and the one that presented for a long time as "clicking does nothing".
    @Test func pressingAMarkNamesItsAnnotation() async throws {
        let page = RuntimeHarness.spec()
        _ = await page.wait(for: "ready")
        // Raw, not quoted: the app interpolates these as object literals, and a string
        // where an object belongs leaves `colours` and `images` unusable — which draws
        // marks with no background, the exact "present and invisible" failure this asserts
        // against.
        try await page.eval("window.rvSetColours(\(AnnotationPalette.json()),"
            + " \(AnnotationSymbols.json()));")
        try await page.setAnnotations([
            ["id": "the-one", "intent": "change", "status": "open", "blocks": [3],
             "start": 0, "end": 4],
        ])
        try await page.eval("""
        document.querySelector('#rv-gutter .rv-marker')
          .dispatchEvent(new MouseEvent('mousedown', { bubbles: true }));
        """)
        let picked = await page.wait(for: "pick")
        #expect(picked["id"] as? String == "the-one")
    }

    // MARK: - Fitting

    /// `rvHold` narrows the sheet, and gives the width back on its own.
    ///
    /// Asserted on the width it SETS rather than the width it currently renders, and that
    /// is not a dodge: the sheet eases to its new size over the pane's own beat, and it
    /// releases itself a little after that — a window of about eighty milliseconds in which
    /// a rendered measurement means what you think it means. Racing two timers to read a
    /// number that is on its way somewhere would be a flaky test of the wrong thing. What
    /// the hold promises is an explicit width while a pane is moving and no explicit width
    /// afterwards, and that is exactly what is checked.
    @Test func aHeldSheetGivesTheRoomUpAndTakesItBack() async throws {
        let page = RuntimeHarness.spec()
        _ = await page.wait(for: "ready")
        try await page.eval("window.rvSetZoom(0);")
        try await page.settle()

        #expect(try await page.int("document.body.classList.contains('rv-fitting') ? 1 : 0")
                    == 1, "the sheet is not fitting, so there is nothing to hold")
        let filled = try await page.int("document.getElementById('rv-page').offsetWidth")
        #expect(try await page.string("document.getElementById('rv-page').style.width") == "",
                "a fitting sheet fills by layout and must carry no width of its own")

        try await page.eval("window.rvHold(200);")
        let held = try await page.string("document.getElementById('rv-page').style.width")
        #expect(held == "\(filled - 200)px",
                "held at \(held), expected \(filled - 200)px")

        // Past the release, which the runtime schedules for itself off the pane's duration.
        try await page.settle(Motion.panel.duration + 0.4)
        #expect(try await page.string("document.getElementById('rv-page').style.width") == "",
                "the sheet never took its width back")
    }
}
