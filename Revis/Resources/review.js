/*
 * Revis document runtime.
 *
 * Runs inside the review web view, in an isolated content world, injected by the app
 * rather than by the page — which is what lets the page's own Content Security Policy be
 * `script-src 'none'` while this still runs. The document being reviewed therefore has no
 * way to run code, and no way to see or call anything in here even if it did.
 *
 * Its whole job is to answer one question in a form something can act on: *what is the
 * reviewer pointing at?* A mark on a page is not an instruction, so nothing here ever
 * returns a coordinate on its own. Every anchor it hands back carries the words.
 */
(function () {
  "use strict";

  // ------------------------------------------------------------------ constants

  /* Elements that can carry an anchor. An anchor lands on the INNERMOST of these, so a
     `<li>` holding a `<p>` gives the paragraph rather than the item — the paragraph is
     what a person would say they were pointing at. */
  var BLOCK = {
    P: 1, H1: 1, H2: 1, H3: 1, H4: 1, H5: 1, H6: 1, LI: 1, BLOCKQUOTE: 1, PRE: 1,
    TABLE: 1, FIGURE: 1, FIGCAPTION: 1, DT: 1, DD: 1, HR: 1, ADDRESS: 1,
    DIV: 1, SECTION: 1, ARTICLE: 1, ASIDE: 1, HEADER: 1, FOOTER: 1, MAIN: 1, DETAILS: 1,
  };
  var BLOCK_SELECTOR = Object.keys(BLOCK).join(",");

  /* Never descended into: their internals are structure, not prose, and an anchor on one
     table cell says less than an anchor on the table. */
  var ATOMIC = { PRE: 1, TABLE: 1, FIGURE: 1 };

  var ROLE = {
    P: "paragraph", H1: "heading-1", H2: "heading-2", H3: "heading-3",
    H4: "heading-4", H5: "heading-5", H6: "heading-6", LI: "list-item",
    BLOCKQUOTE: "quote", PRE: "code", TABLE: "table", FIGURE: "figure",
    FIGCAPTION: "caption", DT: "term", DD: "definition", HR: "rule",
    ADDRESS: "address", DETAILS: "disclosure",
  };

  /* How much text either side of a quote is kept so it can be re-found. Long enough to
     disambiguate a phrase that recurs, short enough that a review file stays readable. */
  var CONTEXT = 64;
  /* A region can cover half a document; the quote is capped so one drag cannot make the
     export unreadable. The blocks it lists stay complete either way. */
  var REGION_QUOTE_LIMIT = 1200;

  // ------------------------------------------------------------------- state

  var doc = null;          // the element holding the reviewed document
  var gutter = null;       // the strip the markers are drawn in
  var overlay = null;      // region boxes and the drag rectangle
  var blocks = [];         // data-rv index -> element
  var meta = [];           // data-rv index -> { role, path }
  var annotations = [];    // as handed over by the app
  var colours = {};        // intent -> colour, assigned by the app
  var images = {};         // intent (and "…:resolved", "pending") -> the mark, as a data URL
  var zoom = 1;            // the page's own zoom, divided back out of the margin furniture
  var fitting = true;      // whether the zoom is being kept at whatever fits the window
  var reported = -1;       // the last zoom the app was told about
  var selectedID = "";
  var tool = "select";
  var holding = 0;         // a setTimeout id while the sheet is pinned for a pane animation
  var ranges = {};         // annotation id -> Range, for hit-testing a click

  function post(name, payload) {
    try {
      window.webkit.messageHandlers.revis.postMessage(
        Object.assign({ kind: name }, payload || {}));
    } catch (e) { /* the app is gone; nothing to tell */ }
  }

  // --------------------------------------------------------------- laying flat

  /* Undo, in the guest's own layout, the two things a document can do that stop it being a
   * document: scroll inside itself, and pin itself to the window.
   *
   * The sheet IS the document, laid out once, top to bottom, and every mark in the margin
   * is an absolute position inside it. A page that gives itself a viewport-sized scroller
   * — `#deck { height: 100vh; overflow-y: scroll }`, which is how a generated slide deck is
   * built — breaks that at the root. Measured on one: the sheet was 1161 points tall while
   * the deck inside it held 21703, so the gutter had nowhere to put a mark for anything
   * past the first screen, and scrolling the inner box moved the words out from under the
   * marks that were drawn for them — the marks cannot follow, because the sheet they are
   * positioned in did not move and nothing repaints on an inner scroll. That is exactly
   * "the dots do not stay with their content, and do not update in the margin", and no
   * amount of repainting fixes it: there is no room in a one-screen sheet for a
   * twenty-seven-thousand-point document.
   *
   * MEASURED, not matched. Whether a box scrolls is a question about its computed style and
   * about the content in it, which no selector can ask — so this walks the guest once and
   * asks the browser. `overflow: hidden` counts: a deck clipped to one screen has lost the
   * same nineteen twentieths of itself whether or not it offered a scrollbar. A box that
   * merely declares `overflow: auto` and fits inside itself is left alone.
   *
   * Only the VERTICAL clip is undone. Marks are a vertical arrangement, so a sideways
   * scroller — a wide table, a long line of code — costs the margin nothing, and unclipping
   * it would spill the document under the gutter to fix a problem nobody had. Height is
   * released with the overflow because releasing the overflow alone leaves a box the
   * declared height with its contents drawn out of the bottom of it, over whatever follows.
   *
   * Fixed elements are moved to `absolute`, not removed. They are part of what was sent,
   * they are things a reviewer may want to mark, and the claim here is only that nothing in
   * the document is pinned to the window — not that the document's furniture is ours to
   * throw away. They land in the document's own box, which is why `#rv-doc` is positioned
   * (review.css). `sticky` is deliberately untouched: it is relative to the scrollport, and
   * once there is only one scrollport it is already doing the right thing.
   *
   * Runs before `stamp()` and before anything is measured, because everything after it is
   * measured. Once is enough — the page has no script of its own to undo it. */
  function layFlat() {
    var found = 0;
    var all = doc.querySelectorAll("*");
    for (var i = -1; i < all.length; i++) {
      var el = i < 0 ? doc : all[i];
      var style = window.getComputedStyle(el);
      if (style.position === "fixed") {
        el.style.setProperty("position", "absolute", "important");
        found++;
      }
      if (style.overflowY !== "visible" && el.scrollHeight > el.clientHeight + 1) {
        el.style.setProperty("overflow-y", "visible", "important");
        el.style.setProperty("height", "auto", "important");
        el.style.setProperty("max-height", "none", "important");
        found++;
      }
    }
    /* Said out loud, because the alternative is a document that silently looks a little
       different from the file the reviewer was sent and no way to know this touched it. */
    if (found) post("flattened", { count: found });
  }

  // ------------------------------------------------------------------ stamping

  /* Give every anchorable block a number, and work out where it sits.
   *
   * The number is the app's address for a block and is assigned in document order, which
   * makes it stable for as long as the document is — and a review holds its own snapshot
   * of the document, so that is for as long as the review exists. It is deliberately NOT
   * the address a language model is given: see `anchorFor`, which always sends the words
   * as well, because the words are the only address that survives the document being
   * regenerated. */
  function stamp() {
    blocks = [];
    meta = [];
    var headings = [];      // the open heading trail, innermost last
    var documentTitleSeen = false;   // the first h1 is the document's name, not a section
    var counts = {};        // role -> how many since the last heading, for "paragraph 3"
    var outline = [];

    walk(doc);

    function walk(node) {
      for (var child = node.firstElementChild; child; child = child.nextElementSibling) {
        var tag = child.tagName;
        if (!BLOCK[tag]) { walk(child); continue; }
        if (!ATOMIC[tag] && child.querySelector(BLOCK_SELECTOR)) { walk(child); continue; }

        var role = ROLE[tag] || "block";
        var index = blocks.length;
        child.setAttribute("data-rv", String(index));
        blocks.push(child);

        var level = /^H([1-6])$/.exec(tag);
        if (level) {
          var depth = parseInt(level[1], 10);
          while (headings.length && headings[headings.length - 1].depth >= depth) {
            headings.pop();
          }
          var text = flatten(textOf(child));
          /* The document's own title is not a section, so it does not belong in the
             trail. Left in, EVERY path began with it — and since a generated spec's
             title is a sentence, every path in the pane was then truncated from the
             front, hiding the part that says where you actually are. Only the first
             top-level heading is treated this way: a document that uses `h1` per
             section keeps them all but the first. */
          if (depth === 1 && !documentTitleSeen) {
            documentTitleSeen = true;
            outline.push({ level: depth, text: text, block: index });
            counts = {};
            meta.push({ role: role, path: "(title)" });
            continue;
          }
          headings.push({ depth: depth, text: text });
          counts = {};
          outline.push({ level: depth, text: text, block: index });
          meta.push({ role: role, path: trail(headings) });
        } else {
          counts[role] = (counts[role] || 0) + 1;
          /* "…› paragraph 3" — the ordinal is what makes the path point at ONE block
             rather than at a whole section, and it is how a person would say it out loud. */
          meta.push({ role: role, path: trail(headings) + " › " + role + " " + counts[role] });
        }
      }
    }

    function trail(stack) {
      if (!stack.length) return "(top)";
      var parts = [];
      for (var i = 0; i < stack.length; i++) parts.push(stack[i].text);
      return parts.join(" › ");
    }

    /* The sheet's RESOLVED background, for Swift to decide what the chrome must do.
       Reported rather than decided here: the document's declared value can be a
       `var()` chain ending in `oklch()`, which the browser has already resolved by now
       and which Swift would otherwise need a colour converter to read. Measuring is the
       page's job; what it means is not — see `PageBackground.isDark`. */
    var sheet = document.getElementById("rv-sheet");
    post("ready", { blocks: blocks.length, outline: outline,
                    paper: sheet ? resolveColour(getComputedStyle(sheet).backgroundColor) : "" });
  }

  /* A computed colour as plain sRGB bytes, whatever syntax it was written in.
   *
   * `getComputedStyle().backgroundColor` does NOT normalise to `rgb()`: WebKit serialises
   * a colour in the space it was authored in, so a document whose canvas is
   * `oklch(0.26 0.087 260)` reports exactly that string back. Swift read it, failed to
   * parse it, and correctly declined to guess — which presented as a dark document being
   * treated as light paper, with every wash still mixed for white.
   *
   * Converting it here rather than in Swift, because the browser already owns a complete
   * colour engine and Swift would need an OKLab matrix to answer a question WebKit answers
   * for free — and would need another one the day a document arrives in `lab()` or
   * `color(display-p3 …)`. A one-pixel fill goes through the same code path the page is
   * painted with, so whatever CSS grows next is already handled.
   *
   * `getImageData` is UNpremultiplied, so the alpha comes back beside the colour rather
   * than mixed into it — which matters, because a see-through sheet is showing the desk
   * and is not an answer about the document at all. Swift decides that; this only reads.
   *
   * Falls back to the raw string, which Swift can still parse when it is already `rgb()`. */
  function resolveColour(value) {
    if (!value) return "";
    try {
      var canvas = document.createElement("canvas");
      canvas.width = 1; canvas.height = 1;
      var ctx = canvas.getContext("2d");
      if (!ctx) return value;
      ctx.clearRect(0, 0, 1, 1);
      ctx.fillStyle = value;
      ctx.fillRect(0, 0, 1, 1);
      var d = ctx.getImageData(0, 0, 1, 1).data;
      return "rgba(" + d[0] + ", " + d[1] + ", " + d[2] + ", " + (d[3] / 255) + ")";
    } catch (e) {
      return value;
    }
  }

  /* A mouse event's position in the page's OWN coordinate space.
   *
   * Events arrive in viewport coordinates, which include the zoom; every layout API inside
   * the zoomed subtree — `getBoundingClientRect`, and the offsets the marks are placed
   * with — reports the element's own, unzoomed space. The two are the same number at 100%
   * and nowhere else, which is the worst way for a units bug to behave: it works while you
   * are building it and is wrong for every user who touches the zoom. Anything comparing a
   * pointer against laid-out geometry goes through here. */
  function cssPoint(event) {
    return { x: event.clientX / zoom, y: event.clientY / zoom };
  }

  function flatten(text) {
    return (text || "").replace(/\s+/g, " ").trim();
  }

  /* Elements whose text runs on. Everything else is a break, and gets a space.
     Deliberately a list of what is INLINE rather than of what is not: the tags that read
     as part of a sentence are few and known, and a tag nobody thought of is far more
     likely to be a box than a word. */
  var INLINE = {
    A: 1, ABBR: 1, B: 1, BDI: 1, BDO: 1, CITE: 1, CODE: 1, DATA: 1, DEL: 1, DFN: 1, EM: 1,
    I: 1, INS: 1, KBD: 1, MARK: 1, Q: 1, RUBY: 1, S: 1, SAMP: 1, SMALL: 1, SPAN: 1,
    STRONG: 1, SUB: 1, SUP: 1, TIME: 1, U: 1, VAR: 1, WBR: 1,
  };

  /* An element's text, with a space where the words really are separated.
   *
   * NOT `textContent`, which is what this was, and which concatenates with nothing in
   * between: a table came out as "ClassRetentionTriggerEvidence Personal data90 days" and
   * that is what a region drawn over one put in the export. The whole claim of the region
   * tool is that what leaves the app is the text the box was drawn over — mush is not that
   * text, and a reader cannot act on it.
   *
   * Only ever used for a QUOTE, never for an offset. Offsets are walked over real text
   * nodes by `positionAt`, so the two cannot be made to disagree by this; the anchors that
   * quote a whole block or a region carry no character range at all. */
  function textOf(node) {
    var out = "";
    for (var child = node.firstChild; child; child = child.nextSibling) {
      if (child.nodeType === 3) { out += child.nodeValue; continue; }
      if (child.nodeType !== 1) continue;
      var inner = textOf(child);
      out += INLINE[child.tagName] ? inner : " " + inner + " ";
    }
    return out;
  }

  /* Collapsed whitespace, trimmed only on the side away from the quote. `side` names the
     edge that is trimmed: "start" for a prefix, "end" for a suffix. */
  function edged(text, side) {
    var out = (text || "").replace(/\s+/g, " ");
    return side === "start" ? out.replace(/^\s+/, "") : out.replace(/\s+$/, "");
  }

  // ------------------------------------------------------------------- anchors

  /* The innermost stamped block containing `node`. */
  function blockOf(node) {
    var el = node && node.nodeType === 3 ? node.parentElement : node;
    while (el && el !== doc) {
      if (el.hasAttribute && el.hasAttribute("data-rv")) return el;
      el = el.parentElement;
    }
    return null;
  }

  function indexOfBlock(el) {
    return el ? parseInt(el.getAttribute("data-rv"), 10) : -1;
  }

  /* Character offset of a point inside a block's own text.
   *
   * Worked out over the block's TEXT rather than its DOM, because that is the coordinate
   * system an anchor is stored in and the one a model can reproduce: given the block's
   * text, `start` and `end` mean the same thing to the app, to the export, and to
   * whatever reads the export. Walking nodes to find it is an implementation detail that
   * ends here. */
  function offsetWithin(block, node, nodeOffset) {
    var walker = document.createTreeWalker(block, NodeFilter.SHOW_TEXT, null);
    var total = 0, current;
    while ((current = walker.nextNode())) {
      if (current === node) return total + nodeOffset;
      total += current.nodeValue.length;
    }
    return total;
  }

  /* The inverse: a DOM position for a character offset, so a stored anchor can be drawn
     again after a reload. */
  function positionAt(block, offset) {
    var walker = document.createTreeWalker(block, NodeFilter.SHOW_TEXT, null);
    var total = 0, current, last = null;
    while ((current = walker.nextNode())) {
      var length = current.nodeValue.length;
      if (offset <= total + length) return { node: current, offset: offset - total };
      total += length;
      last = current;
    }
    return last ? { node: last, offset: last.nodeValue.length } : null;
  }

  /* Everything the app needs to know about a text selection.
   *
   * Returns null rather than an empty anchor when there is nothing selected, so the
   * caller can tell "no selection" from "a selection of nothing". */
  function anchorForSelection() {
    var sel = window.getSelection();
    if (!sel || sel.isCollapsed || !sel.rangeCount) return null;
    var range = sel.getRangeAt(0);
    var quote = flatten(range.toString());
    if (!quote) return null;

    var first = blockOf(range.startContainer);
    var last = blockOf(range.endContainer);
    if (!first) return null;

    var covered = coveredBlocks(range, first, last);
    var start = offsetWithin(first, range.startContainer, range.startOffset);
    var end = first === last
      ? offsetWithin(last, range.endContainer, range.endOffset)
      : first.textContent.length;

    var text = first.textContent;
    var index = indexOfBlock(first);
    return {
      blocks: covered,
      path: meta[index] ? meta[index].path : "",
      role: meta[index] ? meta[index].role : "block",
      quote: quote,
      /* Trimmed at the outer edge and NOT at the inner one: `flatten` alone ate the
         space between the context and the quote, so the export read
         "…Platform retains«each class of record», what…" — words run together at exactly
         the point a reader is trying to see the boundary. */
      prefix: edged(text.slice(Math.max(0, start - CONTEXT), start), "start"),
      suffix: edged(text.slice(end, end + CONTEXT), "end"),
      start: start,
      end: end,
      rect: null,
    };
  }

  function coveredBlocks(range, first, last) {
    if (first === last) return [indexOfBlock(first)];
    var out = [];
    for (var i = 0; i < blocks.length; i++) {
      if (range.intersectsNode(blocks[i])) out.push(i);
    }
    return out.length ? out : [indexOfBlock(first)];
  }

  /* Where the caret is, when there is no selection.
   *
   * An insertion has no span by nature — you are not marking words, you are naming a
   * place between them — and requiring a selection to say "put something here" makes the
   * reviewer choose an arbitrary word to stand for a gap.
   *
   * The anchor is still made of text, because everything here is: the quote is the words
   * immediately BEFORE the caret, so the instruction reads "insert after …", which is a
   * place a reader can find by searching. `start` and `end` are equal, which is what marks
   * it as a point rather than a span. */
  function anchorForCaret() {
    var sel = window.getSelection();
    if (!sel || !sel.isCollapsed || !sel.rangeCount) return null;
    var range = sel.getRangeAt(0);
    var block = blockOf(range.startContainer);
    if (!block || !doc.contains(block)) return null;

    var at = offsetWithin(block, range.startContainer, range.startOffset);
    var text = block.textContent;
    var index = indexOfBlock(block);
    // Back to a word boundary, so the quote is words rather than a fragment ending
    // mid-syllable — "…the retention worker runs" and not "…the retention worker ru".
    var head = text.slice(Math.max(0, at - CONTEXT), at);
    var space = head.search(/\S/) > 0 ? head.indexOf(" ") : -1;
    if (at - CONTEXT > 0 && space > 0) head = head.slice(space + 1);
    return {
      blocks: [index],
      path: meta[index] ? meta[index].path : "",
      role: meta[index] ? meta[index].role : "block",
      quote: flatten(head),
      prefix: edged(text.slice(Math.max(0, at - CONTEXT * 2), Math.max(0, at - CONTEXT)),
                    "start"),
      suffix: edged(text.slice(at, at + CONTEXT), "end"),
      start: at,
      end: at,
      rect: null,
    };
  }

  /* The app asks for this when the reviewer presses Add. Asynchronous by nature — reading
     the DOM from Swift is a round trip — so it is a plain return value the caller
     receives through `evaluateJavaScript`'s completion handler. */
  window.rvCaptureSelection = function () {
    return JSON.stringify(anchorForSelection() || anchorForCaret());
  };

  /* Anchor a whole block, for annotating something with no text to select — a rule, an
     image, an empty cell. */
  window.rvCaptureBlock = function (index) {
    var block = blocks[index];
    if (!block) return JSON.stringify(null);
    return JSON.stringify({
      blocks: [index],
      path: meta[index] ? meta[index].path : "",
      role: meta[index] ? meta[index].role : "block",
      quote: flatten(textOf(block)) || describeEmpty(block),
      prefix: "", suffix: "", start: -1, end: -1, rect: null,
    });
  };

  /* A block with no words still has to say what it is, or the export would carry an
     instruction about nothing. */
  function describeEmpty(block) {
    var image = block.querySelector ? block.querySelector("img") : null;
    if (image) {
      return "[image: " + (image.getAttribute("alt")
        || image.getAttribute("data-rv-missing") || "untitled") + "]";
    }
    if (block.tagName === "HR") return "[horizontal rule]";
    return "[" + (ROLE[block.tagName] || "block") + " with no text]";
  }

  // -------------------------------------------------------------- region tool

  /* A dragged box, turned into something readable.
   *
   * This is the part the whole design turns on. A rectangle on a page is worthless to a
   * model — it cannot see the page. So a region anchor records the box AND the text of
   * everything the box touched, and the export leads with the text. The reviewer draws;
   * the reader is told what was drawn ON. */
  function anchorForRect(rect) {
    var covered = [], texts = [];
    for (var i = 0; i < blocks.length; i++) {
      var box = blocks[i].getBoundingClientRect();
      if (box.right < rect.left || box.left > rect.right) continue;
      if (box.bottom < rect.top || box.top > rect.bottom) continue;
      covered.push(i);
      var text = flatten(textOf(blocks[i])) || describeEmpty(blocks[i]);
      if (text) texts.push(text);
    }
    if (!covered.length) return null;

    var first = blocks[covered[0]];
    var origin = first.getBoundingClientRect();
    var quote = texts.join(" ⏎ ");
    if (quote.length > REGION_QUOTE_LIMIT) {
      quote = quote.slice(0, REGION_QUOTE_LIMIT) + "…";
    }
    var index = covered[0];
    return {
      blocks: covered,
      path: meta[index] ? meta[index].path : "",
      role: covered.length > 1 ? "region" : (meta[index] ? meta[index].role : "block"),
      quote: quote,
      prefix: "", suffix: "", start: -1, end: -1,
      /* Normalised against the FIRST covered block, not the viewport: the page reflows
         when the window is resized and a viewport rectangle would then point at different
         words. Fractions of a block survive it. */
      rect: {
        x: (rect.left - origin.left) / Math.max(1, origin.width),
        y: (rect.top - origin.top) / Math.max(1, origin.height),
        width: rect.width / Math.max(1, origin.width),
        height: rect.height / Math.max(1, origin.height),
      },
    };
  }

  var dragging = null;
  var dragBox = null;

  function beginDrag(event) {
    if (tool !== "region" || event.button !== 0) return;
    event.preventDefault();
    dragging = cssPoint(event);
    dragBox = document.createElement("div");
    dragBox.className = "rv-drag";
    overlay.appendChild(dragBox);
    moveDrag(event);
  }

  function moveDrag(event) {
    if (!dragging || !dragBox) return;
    var rect = rectBetween(dragging, cssPoint(event));
    var origin = overlay.getBoundingClientRect();
    dragBox.style.left = (rect.left - origin.left) + "px";
    dragBox.style.top = (rect.top - origin.top) + "px";
    dragBox.style.width = rect.width + "px";
    dragBox.style.height = rect.height + "px";
  }

  function endDrag(event) {
    if (!dragging) return;
    var rect = rectBetween(dragging, cssPoint(event));
    dragging = null;
    if (dragBox) { dragBox.remove(); dragBox = null; }
    /* A click is not a drag. Below this the box is smaller than the pointer's own jitter,
       and treating it as a region would annotate whatever happened to be under the
       cursor. */
    if (rect.width < 8 || rect.height < 8) return;
    var anchor = anchorForRect(rect);
    if (anchor) post("region", { anchor: anchor });
  }

  function rectBetween(a, b) {
    var left = Math.min(a.x, b.x), top = Math.min(a.y, b.y);
    return { left: left, top: top,
             right: Math.max(a.x, b.x), bottom: Math.max(a.y, b.y),
             width: Math.abs(a.x - b.x), height: Math.abs(a.y - b.y) };
  }

  // ------------------------------------------------------------------- zoom

  /* Zoom with the CSS `zoom` property rather than a transform.
   *
   * A transform scales a rendered picture: text is resampled, and hit-testing has to be
   * unwound by hand because the page's coordinate space no longer matches the pointer's.
   * `zoom` re-lays the document out at the new size — text stays crisp, line breaks move
   * where they would really move, and `getBoundingClientRect` keeps returning numbers in
   * the same space as a mouse event. The markers and region boxes are positioned from
   * exactly those numbers, so they follow for free; they only need repainting because the
   * reflow moves the blocks they are measured against.
   *
   * Applied to `#rv-page`, which contains the gutter as well as the sheet, so the marks
   * scale with the words they belong to instead of drifting off them. */
  window.rvSetZoom = function (value) {
    var page = document.getElementById("rv-page");
    if (!page) return 1;
    /* Zero means "fit", and fitting is a MODE rather than a measurement taken once: the
       window is resized far more often than the zoom is set, and a page that fitted when
       it opened and not afterwards is a page that stops fitting exactly when you notice. */
    fitting = !(typeof value === "number" && value > 0);
    /* Fitting does not use a SCRIPTED zoom, and that is still the rule: anything script
       sets arrives a process and a resize event later, and for those frames the sheet is
       the wrong size and gets clipped. What changed is that it does not have to be script.
       `body.rv-fitting #rv-page` in review.css carries a `zoom` computed by calc from the
       viewport, so it is resolved in layout, in the same pass as the container — and the
       sheet's width is still `auto`, so it still gets its SIZE from layout exactly as
       before. Both halves land together and there is nothing to wait for.
       So: no inline zoom while fitting, or it would override the stylesheet with a number
       arriving late — precisely the fault the stylesheet is there to avoid. */
    var z = fitting ? 1 : Math.max(0.35, Math.min(3, value));
    /* An explicit zoom is a step, not a chase: pressing + should change the size rather
       than animate toward it. Only a fit follows something and wants easing. */
    var root = document.documentElement;
    if (fitting) root.removeAttribute("data-rv-zooming");
    else root.setAttribute("data-rv-zooming", "");
    document.body.classList.toggle("rv-fitting", fitting);
    page.style.zoom = fitting ? "" : z;
    /* The EFFECTIVE scale, not the inline one. Marks divide their sizes by this so they
       stay the same size on screen, and `pointFor` divides a click by it to reach the
       page's own coordinates; while fitting, both were reading 1 for a page drawn at
       two and a half times. */
    zoom = fitting ? fitZoom() : z;
    /* After the reflow, not during it: every mark's position is measured, and measuring
       mid-layout reads the geometry the page is leaving rather than the one it is
       arriving at. */
    requestAnimationFrame(function () {
      paint();
      /* Only when it has actually moved. Following a pane produces a zoom change per
         frame, and telling the app about each one is a message a frame for a status bar
         that reads "Fit" throughout. A tenth of a percent is below what the readout can
         show. */
      var effective = fitting ? fitZoom() : z;
      if (Math.abs(effective - reported) > 0.001) {
        reported = effective;
        post("zoom", { value: effective });
        post("fit", { value: fitZoom() });
      }
    });
    return z;
  };

  /* The zoom at which the sheet just fills the space it has.
   *
   * Now that the sheet is a fixed measure this is a plain division: how many times its own
   * width fits in the room available. `offsetWidth` is the sheet's UNZOOMED width — inside
   * a `zoom`ed subtree the layout APIs report the element's own coordinate space, which is
   * the same reason the margin marks must not divide their positions by the zoom — so the
   * answer is an absolute zoom and not a ratio to compound with the current one.
   *
   * Measured against the sheet's parent, whose padding is the breathing room, so the gap
   * at the sides is the same number as the gap at the top by construction rather than by
   * two calculations agreeing. `clientWidth` excludes a scrollbar if one is showing, so a
   * document long enough to scroll does not fit a fraction too wide. */
  function fitZoom() {
    var page = document.getElementById("rv-page");
    if (!page) return 1;
    var available = contentWidth(page.parentElement || document.body);
    // The nominal measure, not the current one: while fitting the sheet's own width IS the
    // available width, and dividing a thing by itself always says 100%.
    var natural = NOMINAL;
    if (!available || !natural) return parseFloat(page.style.zoom) || 1;
    /* A pixel short of exact, and deliberately.
     *
     * Fitting to the last pixel puts the sheet on the boundary at which a horizontal
     * scrollbar appears — and a scrollbar takes width away from `clientWidth`, which makes
     * the next fit smaller, which removes the scrollbar, which makes it bigger again. Now
     * that the fit runs on every frame of a pane animation rather than once at the end,
     * that loop would run at sixty hertz. One pixel is invisible beside a
     * twenty-four-point gutter and there is no boundary to sit on. */
    return Math.max(0.35, Math.min(3, (available - 1) / natural));
  }

  /* The width actually available INSIDE an element.
   *
   * `clientWidth` includes padding — it is the padding box, not the content box — and the
   * gutter round the sheet is padding. So fitting against `clientWidth` scaled the sheet to
   * the full width including both gutters, and it ran off the trailing edge by the whole 48
   * points every single time. Read the padding back off the computed style rather than
   * repeating the number here: the stylesheet owns the gutter, and a copy of it in the
   * runtime is a second place for it to be wrong. */
  function contentWidth(el) {
    if (!el) return 0;
    var style = window.getComputedStyle(el);
    var left = parseFloat(style.paddingLeft) || 0;
    var right = parseFloat(style.paddingRight) || 0;
    return Math.max(0, el.clientWidth - left - right);
  }

  /* The sheet is allowed to be too NARROW for a moment. It is never allowed to be too
   * wide, and this is the whole of the difference between the two.
   *
   * WebKit lays the page out in another process, so a view whose width is animating gets a
   * sheet that is behind — measured at 130 points at the peak of a pane's travel, which is
   * far more than any margin could absorb. Behind in the direction of GROWING is harmless:
   * the sheet is smaller than the space it has and takes a moment to fill it. Behind in the
   * direction of SHRINKING is the bug everyone could see: the sheet is wider than the view
   * holding it, so its margin is clipped away and the white runs flush against the pane
   * sliding in beside it.
   *
   * So when the app is about to take width off this view it says so first, and the sheet
   * eases to the new width ITSELF, here, with the same curve and beat the pane is using.
   * The point is where the animation runs: a width the page animates is driven inside the
   * web process, one frame after another with nothing to ask anybody, where following the
   * view means a message and an answer per frame and the answer is always late.
   *
   * The SAME duration, not a shorter one. Shortening it by a tenth was tried, on the
   * argument that early is the safe direction to be wrong in — and it is, but the sheet is
   * centred, so every point it leads by shows as HALF a point of the leading edge drifting
   * out and walking back. A tenth measured 47 points of that. At the same duration the
   * drift is 22, and the closest the sheet ever comes to the pane is six points of margin
   * rather than none. Two small faults in opposite directions; this is the bottom of the
   * curve between them.
   *
   * Taking the width in ONE STEP was tried before either, and was worse than the fault it
   * fixed: half of a three-hundred point step comes off each side, so the leading edge
   * jumped a hundred and fifty points out and then walked back in.
   *
   * `paint()` is skipped while held: the marks are inside the sheet and move with it, so a
   * repaint per resize frame is work that changes nothing and slows the process being
   * waited on. */
  window.rvHold = function (points) {
    var page = document.getElementById("rv-page");
    if (!page) return;
    if (holding) { clearTimeout(holding); holding = 0; }
    if (!fitting || !(points > 0)) { release(page); return; }

    var ms = panelMs();
    var from = page.offsetWidth;
    page.style.transition = "none";
    page.style.width = from + "px";
    void page.offsetWidth;              // the transition needs a start it has already had
    page.style.transition = "width " + ms + "ms " + motionCurve();
    /* `points` is a pane's width on SCREEN; `width` is set in the page's own coordinate
       space, which the zoom divides. Giving up the screen number unconverted made the
       sheet surrender the pane's width times the zoom — at Fit on a wide window, more than
       twice too much. */
    var scale = zoom > 0 ? zoom : 1;
    page.style.width = Math.max(200, from - points / scale) + "px";

    holding = setTimeout(function () {
      holding = 0;
      release(page);
    }, ms + 120);
  };

  /* Back to filling by layout — the width it has arrived at and the width layout would give
     it are the same number by now, so there is nothing to see. Through `rvSetZoom` rather
     than a bare repaint, because a window resized while the sheet was held is a fit the app
     has not been told about. */
  function release(page) {
    page.style.transition = "";
    page.style.width = "";
    if (fitting) window.rvSetZoom(0);
    else requestAnimationFrame(paint);
  }

  /* The pane animation's own beat and curve, read from the stylesheet rather than repeated
     here. Swift mirrors `Motion.panel` into these two properties, so there is exactly one
     place either is written down. */
  function panelMs() {
    var ms = parseFloat(motionValue("--rv-motion-panel-duration"));
    return ms > 0 ? ms : 340;
  }

  function motionCurve() {
    return motionValue("--rv-motion-panel") || "ease-in-out";
  }

  function motionValue(name) {
    return window.getComputedStyle(document.documentElement)
      .getPropertyValue(name).trim();
  }

  /* Which appearance the DESK is drawn in, decided by Swift rather than asked for here.
   *
   * The web view is pinned to a light appearance (see `DocumentWebView`) so that the guest
   * document resolves its LIGHT palette. The sheet is paper-white whatever the reviewer's
   * Mac is set to, and a document with a dark branch was taking it: black panels painted
   * onto white paper, under ink the sheet had already darkened. Pinning the appearance
   * fixes that and costs one thing — `prefers-color-scheme` in our own stylesheet now
   * reads the pin instead of the Mac. The desk is the only part that legitimately follows
   * the reviewer, so the desk is told. */
  window.rvSetDesk = function (dark) {
    document.documentElement.setAttribute("data-rv-desk", dark ? "dark" : "light");
  };

  /* Whether the PAPER is dark — which is a different question from the desk above, and
   * is asked because the document now paints the sheet (see `DocumentShell.sheetPaint`).
   * Every wash, rule and tint in `review.css` was mixed over white; on a dark ground a
   * 26%-alpha highlight is not a mark, it is a smudge.
   *
   * Told by Swift for the same reason the desk is: the page measured its own background
   * and reported it, Swift decided what it means, and the answer comes back here. The
   * page is not allowed a second opinion about it. */
  window.rvSetPaper = function (dark) {
    document.documentElement.setAttribute("data-rv-paper", dark ? "dark" : "light");
  };

  window.rvSetTool = function (name) {
    tool = name === "region" ? "region" : "select";
    document.documentElement.setAttribute("data-rv-tool", tool);
    if (tool === "region") {
      var sel = window.getSelection();
      if (sel) sel.removeAllRanges();   // a live selection under a box reads as two marks
    }
  };

  // ---------------------------------------------------------------- drawing

  window.rvSetColours = function (map, marks) {
    colours = map || {};
    images = marks || images;
    paint();
  };

  window.rvSetAnnotations = function (json) {
    /* REPORTED, not swallowed. This used to be a bare `catch { annotations = [] }`, and a
       list that fails to parse is a page with no marks, no highlights and no complaint —
       the same silence `run()` in DocumentWebView was fixed for, in the same app, for the
       same reason. It cost an hour on a document with two thousand blocks: everything
       looked correct except that nothing was drawn. */
    try {
      annotations = JSON.parse(json) || [];
    } catch (e) {
      annotations = [];
      post("error", { stage: "annotations",
                      message: "could not read the list: " + ((e && e.message) || e) });
    }
    paint();
  };

  window.rvSelect = function (id) {
    selectedID = id || "";
    paint();
  };

  window.rvScrollTo = function (id) {
    var target = null;
    for (var i = 0; i < annotations.length; i++) {
      if (annotations[i].id === id) { target = annotations[i]; break; }
    }
    if (!target) return;
    var block = blocks[target.blocks[0]];
    if (block) block.scrollIntoView({ block: "center", behavior: "smooth" });
  };

  window.rvScrollToBlock = function (index) {
    if (blocks[index]) blocks[index].scrollIntoView({ block: "start", behavior: "smooth" });
  };

  /* Redraw everything the annotations put on the page: the text highlights, the boxes
     over regions, and the markers in the gutter.
   *
   * Done wholesale on every change rather than incrementally, and that is a deliberate
   * choice: a review holds tens of annotations, not thousands, and the alternative is
   * two representations of the same list that can disagree — which is exactly the class
   * of bug that shows up as a marker left behind after something was resolved. */
  function paint() {
    ranges = {};
    /* Each stage guarded separately, and each failure reported.
     *
     * Everything the page draws is drawn from measured geometry, and a single throw in
     * here used to take the rest of the drawing with it — the marks vanished, the
     * highlights vanished, and there was NOTHING to see: no console anybody can open, no
     * error, just a page that had quietly stopped painting. Reported, one bad stage costs
     * one stage; unreported, the only symptom is an app that looks like it does not work. */
    guarded("highlights", paintHighlights);
    guarded("regions", paintRegions);
    guarded("markers", paintMarkers);
  }

  function guarded(stage, work) {
    try {
      work();
    } catch (e) {
      post("error", { stage: stage, message: (e && e.message) || String(e) });
    }
  }

  /* Text highlights are drawn with the Custom Highlight API rather than by wrapping the
     text in spans.
   *
   * Wrapping mutates the document, and every offset stored in every other annotation is
   * measured against the document's text — so inserting one span silently moves the
   * anchors of everything after it. Highlight ranges sit beside the DOM instead: the
   * document the reviewer is looking at is character-for-character the document that was
   * loaded, which is what makes an offset mean the same thing tomorrow. */
  function paintHighlights() {
    if (!window.CSS || !CSS.highlights) return;
    CSS.highlights.clear();
    var byIntent = {};
    for (var i = 0; i < annotations.length; i++) {
      var a = annotations[i];
      if (a.start < 0 || a.rect) continue;      // block or region: no text run to mark
      var block = blocks[a.blocks[0]];
      if (!block) continue;
      var from = positionAt(block, a.start), to = positionAt(block, a.end);
      if (!from || !to) continue;
      var range = document.createRange();
      try {
        range.setStart(from.node, from.offset);
        range.setEnd(to.node, to.offset);
      } catch (e) { continue; }
      ranges[a.id] = range;
      /* Always in its intent's highlight, and additionally in `current` when it is the
         chosen one. Both, not one or the other: the current mark used to swap its wash
         for a single blue, which lost the intent — the reader could no longer see that
         the thing they were reading was a deletion — and looked exactly like the live
         text selection into the bargain. `current` now carries only an underline
         (see review.css), so it layers rather than replaces. */
      (byIntent[a.intent] = byIntent[a.intent] || []).push(range);
      if (a.id === selectedID) {
        (byIntent.current = byIntent.current || []).push(range);
      }
    }
    for (var name in byIntent) {
      if (!Object.prototype.hasOwnProperty.call(byIntent, name)) continue;
      /* Built one range at a time rather than by spreading the list into the
         constructor: `new Highlight(...ranges)` is the documented form, and it is also
         the form that cannot be written with `.apply`, since `new` and `apply` do not
         compose. `add` is the same API and reads as what it does. */
      var highlight = new Highlight();
      for (var j = 0; j < byIntent[name].length; j++) highlight.add(byIntent[name][j]);
      CSS.highlights.set("rv-" + name, highlight);
    }
  }

  function paintRegions() {
    overlay.innerHTML = "";
    var origin = overlay.getBoundingClientRect();
    for (var i = 0; i < annotations.length; i++) {
      var a = annotations[i];
      if (!a.rect) continue;
      var block = blocks[a.blocks[0]];
      if (!block) continue;
      var box = block.getBoundingClientRect();
      var el = document.createElement("div");
      el.className = "rv-region" + (a.id === selectedID ? " current" : "");
      el.style.left = (box.left - origin.left + a.rect.x * box.width) + "px";
      el.style.top = (box.top - origin.top + a.rect.y * box.height) + "px";
      el.style.width = (a.rect.width * box.width) + "px";
      el.style.height = (a.rect.height * box.height) + "px";
      el.style.setProperty("--rv-colour", colours[a.intent] || "#9a9a9e");
      el.setAttribute("data-rv-for", a.id);
      overlay.appendChild(el);
    }
  }

  /* One mark per annotation, out in the gutter beside the block it is about.
   *
   * Beside the BLOCK, not beside the selected words: an annotation on the third sentence
   * of a paragraph belongs beside the paragraph, because that is the thing being talked
   * about.
   *
   * Each element IS a slot; the mark is drawn inside it as a centred background image at a
   * fixed painted size. That is what lets a mark grow under the pointer without moving
   * anything beside it — it scales about the middle of a slot that does not move.
   *
   * Sizes are PAINTED, then divided by the page zoom. A mark is furniture, not content: it
   * should be the same size on screen at 200% as at 50%, because it is a control. Left to
   * inherit the zoom it grew with the words, which is how the margin ended up with a
   * fifteen-point mark painted at twenty-six.
   */
  /* The mark is fifteen points; the box you can click is thirty by twenty-two.
   *
   * They were the same size, and a fifteen-point target in a margin is one you miss — and
   * missing it now does nothing at all, which reads as a mark that is not clickable. The
   * visible mark stays small because it is furniture beside somebody's document; the thing
   * that catches the pointer does not have to be.
   *
   * One column, not several. Vaelora stacks its marks three across because it has a whole
   * page margin to play with; this gutter is thirty-four points wide, and two columns of a
   * hittable box do not fit in it. Marks on the same line stack downward instead. */
  /* The element is the mark plus half a point — just enough for the chosen state's ring
     to sit against it rather than out at arm's length. It does not have to be a big target any more: pressing anywhere on the
     line does that (see `pressGutter`), so the box can be the size the mark wants to be
     rather than the size a pointer needs. */
  /* Big enough for the RINGED image, not just the mark.
     It was the size of the mark, and a chosen mark's picture is wider than that — the ring
     is part of it — so the element clipped its own ring off and the chosen state became
     invisible. The box is the ringed size; the unringed mark simply sits in the middle of
     it with room to spare, which is no bad thing for something you press. */
  /* The sheet's nominal measure, matching `#rv-page { width: 920px }` in review.css. */
  var NOMINAL = 920;

  var SLOT_W = 30;         // painted; the box a mark lives in
  var SLOT_H = 30;
  var MARK = 19;           // painted; the mark drawn inside it
  var SLOT_COLS = 1;

  /* Pressing anywhere in the gutter chooses the mark on that line.
   *
   * The marks are furniture — small on purpose, because they sit beside somebody else's
   * document — and a small thing is a thing you miss. Nothing else lives in this strip, so
   * there is no reason to make the reviewer hit the fifteen points of ink rather than the
   * line it is on. Bound once, on the gutter, rather than per mark: the marks are rebuilt
   * on every repaint and this is not. */
  function pressGutter(event) {
    if (!gutter) return;
    var origin = gutter.getBoundingClientRect();
    var y = cssPoint(event).y - origin.top;
    var best = null, bestGap = Infinity;
    for (var i = 0; i < gutter.children.length; i++) {
      var el = gutter.children[i];
      var top = parseFloat(el.style.top) || 0;
      var height = parseFloat(el.style.height) || 0;
      var gap = Math.abs(y - (top + height / 2));
      if (gap < bestGap) { bestGap = gap; best = el; }
    }
    // Within half a row of a mark, and no further: the strip runs the height of the page,
    // and a press level with nothing should stay a press level with nothing.
    if (!best || bestGap > (SLOT_H / zoom)) return;
    event.preventDefault();
    post("pick", { id: best.getAttribute("data-rv-for") });
  }

  function paintMarkers() {
    gutter.innerHTML = "";
    var origin = gutter.getBoundingClientRect();
    var slotW = SLOT_W / zoom, slotH = SLOT_H / zoom;
    // The strip has to be as wide as the boxes in it, at every zoom. Its stylesheet width
    // is in the page's units and the boxes are in painted ones, so at a small zoom a fixed
    // width would clip them.
    gutter.style.width = slotW + "px";
    var rows = {};
    for (var i = 0; i < annotations.length; i++) {
      var a = annotations[i];
      var block = blocks[a.blocks[0]];
      if (!block) continue;
      var box = block.getBoundingClientRect();
      /* Against the block's FIRST LINE rather than its middle: a mark beside a
         twelve-line paragraph should point at where the paragraph starts, which is where
         the eye is when it meets it.
         NOT divided by the zoom, unlike the sizes below. `getBoundingClientRect` reports
         CSS pixels — the element's own, unzoomed coordinate space — for anything inside a
         `zoom`ed subtree, and `style.top` is read in that same space. Dividing put every
         mark a proportion of the way up the page: at 119% they sat forty points high, next
         to the heading above the paragraph they belonged to. The SIZES are a different
         question and do divide: a mark should be the same size on screen at any zoom. */
      var top = box.top - origin.top;
      var row = Math.round(top / (slotH * 0.75));   // marks close together share a row
      var index = rows[row] = (rows[row] === undefined ? 0 : rows[row] + 1);

      var mark = document.createElement("div");
      mark.className = "rv-marker"
        + (a.id === "draft" ? " pending" : "");
      mark.style.width = slotW + "px";
      mark.style.height = slotH + "px";
      // The draft is never drawn as the chosen one. It is the only thing being worked on,
      // the pane has the keyboard, and a ring round it on top of its own unfilled circle
      // is two rings saying one thing.
      var current = a.id !== "draft" && a.id === selectedID;
      mark.style.backgroundSize =
        (MARK / (current ? DISC_FRACTION : 1) / zoom) + "px";
      mark.style.backgroundImage = imageFor(a, current);
      mark.style.left = ((index % SLOT_COLS) * slotW) + "px";
      mark.style.top = (top - slotH / 2
                        + Math.floor(index / SLOT_COLS) * slotH) + "px";
      mark.setAttribute("data-rv-for", a.id);
      /* A real control rather than a decorated div: it is the only way to reach an
         annotation from the page without a mouse, and it is what puts the mark in the
         accessibility tree at all. */
      mark.setAttribute("role", "button");
      mark.setAttribute("tabindex", "0");
      mark.setAttribute("aria-label", a.intent + " annotation"
                        + (a.status === "resolved" ? ", resolved" : ""));
      /* On MOUSEDOWN, and bound to the element rather than delegated from the document.
       *
       * A `click` is only delivered to the element if the press AND the release both land
       * on it; drift a pixel off a small mark between the two and the browser dispatches
       * the click to the common ancestor instead — here the gutter, which is transparent
       * to the pointer, so it lands on the sheet and nothing happens. That is not a rare
       * accident with a hand-held mouse on a target this size, and it presents exactly as
       * "clicking does nothing". Pressing is unambiguous, and it is what a button-like
       * control should answer to anyway.
       *
       * `preventDefault` so pressing a mark does not also start selecting the page. */
      mark.addEventListener("mousedown", function (event) {
        event.preventDefault();
        event.stopPropagation();
        post("pick", { id: this.getAttribute("data-rv-for") });
      });
      gutter.appendChild(mark);
    }
  }

  /* Which image a mark wears. Asked for by name rather than assembled here, because the
     app owns what an intent looks like and the page is not allowed a second opinion. */
  function imageFor(a, current) {
    var key;
    if (a.id === "draft") key = a.intent + ":pending";
    else if (a.status === "resolved") key = a.intent + ":resolved";
    else key = a.intent + (current ? ":current" : "");
    return images[key] ? "url(\"" + images[key] + "\")" : "none";
  }

  /* How big to draw a mark so its DISC is always MARK points across.
   *
   * A chosen mark's image carries its ring, so the disc is only part of the picture and
   * the picture has to be drawn larger to keep the disc the same size. Without this,
   * choosing a mark would appear to shrink it. */
  var DISC_FRACTION = 0.70;

  // ----------------------------------------------------------------- picking

  /* Clicking a mark, a region box, or the highlighted words all mean the same thing:
     show me that annotation. The first two are elements and hit-test themselves; the
     third is not — a Custom Highlight paints without an element — so the click is
     resolved against the stored ranges instead. */
  function handleClick(event) {
    var target = event.target;
    var walker = target;
    while (walker && walker !== document.body) {
      var id = walker.getAttribute && walker.getAttribute("data-rv-for");
      if (id) { post("pick", { id: id }); return; }
      walker = walker.parentElement;
    }
    if (tool !== "select") return;
    /* Only inside the document itself.
     *
     * Below this the click is resolved by asking which annotation's text is under the
     * pointer — and out in the margin there is no text under the pointer, so
     * `caretRangeFromPoint` answers with the nearest position it can find, which is the
     * end of some line beside it. A click that MISSED a marker was therefore picking
     * whatever annotation happened to own that line: the wrong card, and worse, usually a
     * plausible-looking one. Markers hit-test themselves in the walk above; if the walk did
     * not find one, a click out here meant nothing. */
    if (!doc || !doc.contains(target)) return;
    var caret = document.caretRangeFromPoint
      ? document.caretRangeFromPoint(event.clientX, event.clientY) : null;
    if (!caret) return;
    for (var key in ranges) {
      if (!Object.prototype.hasOwnProperty.call(ranges, key)) continue;
      var r = ranges[key];
      if (r.comparePoint(caret.startContainer, caret.startOffset) === 0) {
        post("pick", { id: key });
        return;
      }
    }
  }

  // ------------------------------------------------------------------- setup

  function ready() {
    doc = document.getElementById("rv-doc");
    gutter = document.getElementById("rv-gutter");
    overlay = document.getElementById("rv-regions");
    if (!doc) return;

    layFlat();
    stamp();

    document.addEventListener("click", handleClick, true);
    gutter.addEventListener("mousedown", pressGutter);
    document.addEventListener("mousedown", beginDrag, true);
    document.addEventListener("mousemove", moveDrag, true);
    document.addEventListener("mouseup", endDrag, true);
    /* Tell the app whether there is anything to annotate, so Add can be disabled rather
       than offered and then refused. */
    document.addEventListener("selectionchange", function () {
      var sel = window.getSelection();
      var has = !!(sel && !sel.isCollapsed && flatten(sel.toString()));
      // A caret inside the document is enough to insert AT — a place, rather than a run of
      // words — so the toolbar is told about it separately.
      var caret = !has && !!(sel && sel.isCollapsed && sel.rangeCount
                             && doc && doc.contains(
                               sel.getRangeAt(0).startContainer.nodeType === 3
                                 ? sel.getRangeAt(0).startContainer.parentElement
                                 : sel.getRangeAt(0).startContainer));
      post("selection", { has: has, caret: caret });
    });
    /* Marks and boxes are positioned from measured geometry, so anything that reflows the
       page has to redraw them.
     *
     * While FITTING, the refit happens on every resize event with no debounce at all.
     * That is the whole difference between a page that follows its pane and one that
     * snaps: a pane sliding open animates its width over a quarter of a second, and the
     * web view is resized the whole way — so a debounced refit does nothing until the
     * movement stops and then jumps to the answer. Worse on the way in than out, because
     * for those frames the sheet is wider than the pane it is in and slides under the
     * neighbour.
     *
     * It costs a repaint per frame of the animation, which is a repaint of a few dozen
     * marks — cheap, and it is what the resize is FOR. Vaelora reaches the same place by
     * the opposite road: it is handed the pane's final width immediately, works out the
     * fit itself, and eases the page to it over the same beat with the same curve. Here
     * the web view is resized frame by frame, so following it is both simpler and more
     * exact.
     *
     * Not fitting, there is nothing to track: the zoom is a number the reviewer chose, and
     * only the marks need moving. That stays debounced. */
    var pending = 0;
    window.addEventListener("resize", function () {
      // Held, the sheet has already been given its answer and the marks travel with it.
      if (holding) return;
      if (fitting) {
        window.rvSetZoom(0);
        return;
      }
      clearTimeout(pending);
      pending = setTimeout(function () {
        paint();
        post("fit", { value: fitZoom() });
      }, 80);
    });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", ready);
  } else {
    ready();
  }
})();
