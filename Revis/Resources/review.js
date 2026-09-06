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
  var selectedID = "";
  var tool = "select";
  var ranges = {};         // annotation id -> Range, for hit-testing a click

  function post(name, payload) {
    try {
      window.webkit.messageHandlers.revis.postMessage(
        Object.assign({ kind: name }, payload || {}));
    } catch (e) { /* the app is gone; nothing to tell */ }
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
          var text = flatten(child.textContent);
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

    post("ready", { blocks: blocks.length, outline: outline });
  }

  function flatten(text) {
    return (text || "").replace(/\s+/g, " ").trim();
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

  /* The app asks for this when the reviewer presses Add. Asynchronous by nature — reading
     the DOM from Swift is a round trip — so it is a plain return value the caller
     receives through `evaluateJavaScript`'s completion handler. */
  window.rvCaptureSelection = function () {
    return JSON.stringify(anchorForSelection());
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
      quote: flatten(block.textContent) || describeEmpty(block),
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
      var text = flatten(blocks[i].textContent) || describeEmpty(blocks[i]);
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
    dragging = { x: event.clientX, y: event.clientY };
    dragBox = document.createElement("div");
    dragBox.className = "rv-drag";
    overlay.appendChild(dragBox);
    moveDrag(event);
  }

  function moveDrag(event) {
    if (!dragging || !dragBox) return;
    var rect = rectBetween(dragging, { x: event.clientX, y: event.clientY });
    var origin = overlay.getBoundingClientRect();
    dragBox.style.left = (rect.left - origin.left) + "px";
    dragBox.style.top = (rect.top - origin.top) + "px";
    dragBox.style.width = rect.width + "px";
    dragBox.style.height = rect.height + "px";
  }

  function endDrag(event) {
    if (!dragging) return;
    var rect = rectBetween(dragging, { x: event.clientX, y: event.clientY });
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
    var z = fitting ? fitZoom() : value;
    z = Math.max(0.35, Math.min(3, z));
    page.style.zoom = z;
    zoom = z;
    /* After the reflow, not during it: every mark's position is measured, and measuring
       mid-layout reads the geometry the page is leaving rather than the one it is
       arriving at. */
    requestAnimationFrame(function () {
      paint();
      post("zoom", { value: z });
      post("fit", { value: fitting ? z : fitZoom() });
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
    var natural = page.offsetWidth;
    var available = contentWidth(page.parentElement || document.body);
    if (!available || !natural) return parseFloat(page.style.zoom) || 1;
    return Math.max(0.35, Math.min(3, available / natural));
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
    try { annotations = JSON.parse(json) || []; } catch (e) { annotations = []; }
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
  var SLOT = 21;           // painted; the box a mark lives in
  var MARK = 15;           // painted; the mark drawn inside it
  var SLOT_COLS = 2;       // marks on one line sit side by side, then wrap

  function paintMarkers() {
    gutter.innerHTML = "";
    var origin = gutter.getBoundingClientRect();
    var slot = SLOT / zoom;
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
      var row = Math.round(top / (slot * 0.75));   // marks close together share a row
      var index = rows[row] = (rows[row] === undefined ? 0 : rows[row] + 1);

      var mark = document.createElement("div");
      mark.className = "rv-marker"
        + (a.id === selectedID ? " current" : "")
        + (a.id === "draft" ? " pending" : "");
      mark.style.width = slot + "px";
      mark.style.height = slot + "px";
      mark.style.backgroundSize = (MARK / zoom) + "px";
      mark.style.backgroundImage = imageFor(a);
      mark.style.left = ((index % SLOT_COLS) * slot) + "px";
      mark.style.top = (top - slot / 2
                        + Math.floor(index / SLOT_COLS) * slot) + "px";
      mark.setAttribute("data-rv-for", a.id);
      /* A real control rather than a decorated div: it is the only way to reach an
         annotation from the page without a mouse, and it is what puts the mark in the
         accessibility tree at all. */
      mark.setAttribute("role", "button");
      mark.setAttribute("tabindex", "0");
      mark.setAttribute("aria-label", a.intent + " annotation"
                        + (a.status === "resolved" ? ", resolved" : ""));
      gutter.appendChild(mark);
    }
  }

  /* Which image a mark wears. Asked for by name rather than assembled here, because the
     app owns what an intent looks like and the page is not allowed a second opinion. */
  function imageFor(a) {
    var key = a.id === "draft" ? "pending"
            : (a.status === "resolved" ? a.intent + ":resolved" : a.intent);
    return images[key] ? "url(\"" + images[key] + "\")" : "none";
  }

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

    stamp();

    document.addEventListener("click", handleClick, true);
    document.addEventListener("mousedown", beginDrag, true);
    document.addEventListener("mousemove", moveDrag, true);
    document.addEventListener("mouseup", endDrag, true);
    /* Tell the app whether there is anything to annotate, so Add can be disabled rather
       than offered and then refused. */
    document.addEventListener("selectionchange", function () {
      var sel = window.getSelection();
      post("selection", { has: !!(sel && !sel.isCollapsed && flatten(sel.toString())) });
    });
    /* Marks and boxes are positioned from measured geometry, so anything that reflows the
       page has to redraw them. Debounced: a resize fires continuously and a repaint per
       frame of a window drag is wasted work. */
    var pending = 0;
    window.addEventListener("resize", function () {
      clearTimeout(pending);
      pending = setTimeout(function () {
        // Re-fit FIRST if that is the mode, because fitting reflows the page and the marks
        // are positioned from where the blocks end up.
        if (fitting) {
          window.rvSetZoom(0);
        } else {
          paint();
          post("fit", { value: fitZoom() });
        }
      }, 80);
    });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", ready);
  } else {
    ready();
  }
})();
