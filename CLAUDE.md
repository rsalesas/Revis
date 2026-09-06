# Revis — notes for working in this repository

Revis reviews untrusted HTML documents and turns the marks on them into instructions a
language model can act on. Read `README.md` first; it explains why the export looks the way
it does, and that reasoning is the design.

## House rules

Same as Vaelora, next door — this is deliberately its sibling.

- **XcodeGen.** `project.yml` is the source of truth; `Revis.xcodeproj` is generated and
  gitignored. Run `./scripts/build.sh` (which regenerates) rather than `xcodebuild` alone,
  or a newly added file will not be in the target.
- **Comments explain *why*, never *what*.** A comment that restates the code earns nothing.
  A comment recording the thing that was tried first and did not work is worth more than
  the code it sits above. Several here name a specific bug on purpose.
- **Named tokens, not typed values.** Colours live in `Theme` and `AnnotationPalette`;
  durations and curves live in `Motion`. A duration typed at a call site is how a set of
  animations stops looking like one system. Three motion tokens are mirrored into
  `review.css` and must stay in step.
- **One source, two readers.** Where the app and the page both need to know something —
  the intent colours, which mark is current — Swift decides and pushes it. The page is
  never allowed a second opinion.

## The two invariants

Both have a bug behind them; do not relax either.

1. **A review is never written over the document it reviews.** Enforced twice, in
   `SourceDetachment` (the window lets go of the source URL on import) and in
   `ReviewDocument.canWrite` (the writer refuses any type but `.revis`). AppKit autosaves a
   document back to the URL it was read from, and declaring HTML unwritable does not stop
   it — the first run of this app against a real document destroyed it.
2. **Nothing leaves the app as a coordinate.** Every annotation carries the words it is
   about, including one drawn as a box. `ReviewExport` is where this is cashed in; if you
   add an annotation kind, it needs an answer to "what text is this about?" before it needs
   anything else.

## Where things are

- `Document/HTMLSanitizer.swift` — the tokenizer. The one place where being wrong is a
  security bug. It is a denylist over elements and an allowlist over attributes; keep it
  that way, and add a test to `Tests/SanitizerTests.swift` for anything you change.
- `Document/DocumentShell.swift` — the CSP. `script-src 'none'` is absolute because the
  runtime is a user script; do not add a nonce or an inline `<script>` to the page.
- `Resources/review.js` — runs in an isolated `WKContentWorld`. It stamps `data-rv`
  indices, computes anchors, and draws. Text highlights use the Custom Highlight API rather
  than wrapping spans, because wrapping mutates the DOM and every stored offset is measured
  against it.
- `Models/Annotation.swift` — the anchor model, and the reasoning for carrying four
  addresses for one place.

## Debugging the page

There is no console to open on a `WKWebView` inside an app, which makes a drawing failure
present as "the margin is empty" with nothing to go on. Two things exist so that never
happens again:

- Set `REVIS_PAGE_LOG=/path/to/log` in the environment and the page's failures — a script
  that would not evaluate, a drawing stage that threw — are written there. Unset, nothing
  is written. Launch with `REVIS_PAGE_LOG=… Revis.app/Contents/MacOS/Revis &` and then
  `open -a Revis <file>` so the running instance (with the variable) gets the document.
- `paint()` guards each stage separately and reports the failure, so one bad stage costs
  one stage rather than the whole page.

`run()` in `DocumentWebView` reports evaluation failures rather than swallowing them. Do
not put that `try?` back.

## The pane-toggle flash (open, and expensive to chase)

Toggling a side pane shows a brief flash at the document's trailing edge. Several things
that looked like the cause were not, and each is now fixed on its own merits — do not undo
them while trying something new:

- **The layout must not animate.** A toggle is wrapped in `withAnimation`, and that
  animation reaches every view in the update, including a hosted `NSView`, which then
  animates its layer through Core Animation. Measured: twelve intermediate widths over
  200 ms for one toggle, each a full WebKit re-layout. `paneContent()` strips it.
- **The panes are three siblings in one row**, not nested containers. Vaelora nests
  because its layout animates and the nesting decides whose width each animation comes
  from; that reason does not apply once the layout is instant.
- **The sheet fills by layout while fitting** (`width: auto`), not by a `zoom` that
  JavaScript has to set. Anything script-driven arrives a process and a resize event
  later — around 30-35 ms, measured — and for those frames the sheet is sized for the
  width before last: wider than the view, so clipped, with text running under the pane.
- **Do not put a transition on the zoom.** Vaelora eases its page because a page is fixed
  paper that need not fill anything; this sheet must exactly fill the viewport, so a late
  zoom is a clipped sheet. `BridgeTests` pins the transition gone.

What remains is the WebKit round trip itself: the view is resized in one step and the page
reports its new layout roughly two frames later. The only thing that would remove it is not
resizing the web view on a toggle at all — panes overlaying the document rather than taking
width from it — which costs the thing the panes exist for, reading a note beside the passage
it is about. Measure before changing anything here: `REVIS_PAGE_LOG` plus an
`onGeometryChange` on the document pane gives both sides of the change with timestamps, and
that is what settled every question above.

## Testing

`xcodebuild -project Revis.xcodeproj -scheme Revis test`, or `./scripts/build.sh` first if
you added a file. Swift Testing, not XCTest. Fixtures are read out of the source tree by
`#filePath` and excluded from the bundle, so a fixture is added by dropping a file into
`Tests/Fixtures`.

`BridgeTests` checks the Swift↔page bridge from the Swift side: that every `window.rv*`
entry point Swift calls is defined, and that every module-level variable the runtime
assigns to is declared. That second one is not paranoia — a search-and-replace that
silently did not match left `images` and `zoom` undeclared, every push threw under
`"use strict"`, and the app simply looked unfinished.

`node --check Revis/Resources/review.js` catches syntax errors if node is to hand. The
runtime's behaviour still has no tests, which is the biggest remaining gap.
