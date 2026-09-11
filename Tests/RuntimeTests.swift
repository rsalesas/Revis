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

        // Asserted in SCREEN points, which is what `rvHold` is given and what the pane
        // actually takes. The sheet's own width is in the page's coordinate space, and
        // while fitting that space is divided by the zoom — so the two numbers are only
        // the same at 100%. Pinning the raw width instead pinned the arithmetic rather
        // than the meaning, and said nothing at all about a fitted sheet on a wide window,
        // which is every fitted sheet.
        try await page.eval("window.rvHold(200);")
        let givenUp = try await page.int("""
            (function () {
              var page = document.getElementById('rv-page');
              var z = parseFloat(getComputedStyle(page).zoom) || 1;
              return Math.round((\(filled) - parseFloat(page.style.width)) * z);
            })()
            """)
        #expect(abs(givenUp - 200) <= 1, "gave up \(givenUp) points, expected 200")

        // Past the release, which the runtime schedules for itself off the pane's duration.
        try await page.settle(Motion.panel.duration + 0.4)
        #expect(try await page.string("document.getElementById('rv-page').style.width") == "",
                "the sheet never took its width back")
    }

    // MARK: - Laying a document flat

    /// A document that scrolls inside itself is laid flat before anything is measured.
    ///
    /// The sheet IS the document and the margin is positioned inside it, so a page that
    /// hands itself a `height: 100vh; overflow-y: scroll` box — which is how every
    /// generated slide deck is built — leaves the margin one screen tall for a document
    /// twenty times that. Every mark past the first slide then has nowhere to go, and
    /// scrolling the inner box slides the words out from under the marks that are left.
    /// The user's report was "the dots do not stay with their content".
    @Test func aDeckThatScrollsInsideItselfIsLaidFlat() async throws {
        let page = RuntimeHarness.spec("viewport-deck.html")
        _ = await page.wait(for: "ready")

        #expect(page.posts.contains { $0.name == "flattened" },
                "the page never said it had changed the document's layout")

        // Nothing is clipping its own contents any more — asked of the document, not of
        // the stylesheet, because that is the only form of the question that means
        // anything (see `layFlat`).
        #expect(try await page.int("""
        Array.prototype.filter.call(
          document.querySelectorAll('#rv-doc *'),
          function (el) {
            return getComputedStyle(el).overflowY !== 'visible'
                && el.scrollHeight > el.clientHeight + 1;
          }).length
        """) == 0, "something in the document is still hiding part of itself")

        #expect(try await page.int("""
        Array.prototype.filter.call(
          document.querySelectorAll('#rv-doc *'),
          function (el) { return getComputedStyle(el).position === 'fixed'; }).length
        """) == 0, "something in the document is still pinned to the window")

        // And the point of all of it: the sheet is as tall as the document, so the last
        // slide is inside the strip the marks are drawn in rather than thousands of
        // points below it.
        #expect(try await page.int("""
        (function () {
          var gutter = document.getElementById('rv-gutter').getBoundingClientRect();
          var slides = document.querySelectorAll('#rv-doc .slide');
          var last = slides[slides.length - 1].getBoundingClientRect();
          return (last.top >= gutter.top - 1 && last.top <= gutter.bottom + 1) ? 1 : 0;
        })()
        """) == 1, "the last slide is outside the margin, so it can never carry a mark")
    }

    /// Every mark lands in the margin, including the one on the last slide.
    ///
    /// The same fault stated the way it was seen. Before this, a mark on a block below the
    /// first screen was drawn thousands of points down a strip one screen tall — off the
    /// sheet entirely, which reads as a dot that simply is not there.
    @Test func aMarkOnTheLastSlideIsStillInTheMargin() async throws {
        let page = RuntimeHarness.spec("viewport-deck.html")
        let ready = await page.wait(for: "ready")
        let blocks = (ready["blocks"] as? Int) ?? 0
        #expect(blocks > 2, "the fixture stamped \(blocks) blocks")

        try await page.eval("window.rvSetColours(\(AnnotationPalette.json()),"
            + " \(AnnotationSymbols.json()));")
        try await page.setAnnotations([
            ["id": "first", "intent": "change", "status": "open", "blocks": [0],
             "start": 0, "end": 4],
            ["id": "last", "intent": "question", "status": "open", "blocks": [blocks - 1],
             "start": 0, "end": 4],
        ])

        #expect(try await page.int("""
        (function () {
          var gutter = document.getElementById('rv-gutter').getBoundingClientRect();
          return Array.prototype.filter.call(
            document.querySelectorAll('#rv-gutter .rv-marker'),
            function (m) {
              var box = m.getBoundingClientRect();
              return box.top >= gutter.top - 1 && box.bottom <= gutter.bottom + 1;
            }).length;
        })()
        """) == 2, "a mark was drawn outside the strip it lives in")
    }

    /// The margin is above whatever the document stacked.
    ///
    /// A deck builds itself a dot-strip down the right-hand edge at `z-index: 55`; the
    /// marks sit at 2. Nothing used to separate the two, so the document's furniture drew
    /// straight over the gutter and — being a real element — took the press meant for a
    /// mark with it.
    @Test func theDocumentCannotStackItselfOverTheMargin() async throws {
        let page = RuntimeHarness.spec("viewport-deck.html")
        _ = await page.wait(for: "ready")
        // At 100%, and not fitting. A hit test is asked in the viewport's coordinates and
        // a mark is measured in the page's, and inside a `zoom`ed subtree those are two
        // different spaces — see `paintMarkers`. They coincide at 1, which is the only
        // place this test can ask its question and get an answer about stacking rather
        // than about arithmetic.
        try await page.eval("window.rvSetZoom(1);")
        try await page.eval("window.rvSetColours(\(AnnotationPalette.json()),"
            + " \(AnnotationSymbols.json()));")
        try await page.setAnnotations([
            ["id": "a", "intent": "change", "status": "open", "blocks": [0],
             "start": 0, "end": 4],
        ])
        // Asked of the browser's own hit test rather than of the numbers, because the
        // numbers were never the point: what matters is which element the press reaches.
        //
        // Scrolled to first. `elementFromPoint` answers for the viewport and nothing else,
        // and a flattened deck is several screens tall — so a mark below the fold hit-tests
        // as nothing at all, which is not the same finding as a mark that is covered.
        #expect(try await page.string("""
        (function () {
          var mark = document.querySelector('#rv-gutter .rv-marker');
          window.scrollTo(0, mark.getBoundingClientRect().top + window.scrollY
                             - window.innerHeight / 2);
          var box = mark.getBoundingClientRect();
          var hit = document.elementFromPoint(box.left + box.width / 2,
                                              box.top + box.height / 2);
          return hit ? String(hit.className || hit.tagName) : 'nothing';
        })()
        """).contains("rv-marker"), "something in the document is over the mark")
    }

    /// The sheet keeps its margins whatever the document says about `body`.
    ///
    /// `html, body { padding: 0 }` is in every full-bleed page ever generated, and it used
    /// to win outright — the paper ran flush to the window edge and read as a page that had
    /// been cut off rather than one sitting on a desk.
    @Test func theDocumentCannotTakeTheSheetsMargins() async throws {
        let page = RuntimeHarness.spec("viewport-deck.html")
        _ = await page.wait(for: "ready")
        #expect(try await page.int("""
        Math.round(parseFloat(getComputedStyle(document.body).paddingLeft))
        """) > 0, "the document flattened the desk the sheet sits on")
    }
}
