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
  addresses for one place. Also `Annotation.init(from:)`, which is hand-written and must
  stay that way: Swift's synthesised decoder throws on a missing key even when the property
  has a default, and `ReviewDocument` turns a decode failure into "this is HTML" — so a
  field added without it does not fail loudly, it makes every saved review reopen empty.
- `Document/ReplyImport.swift` — reading a reply document. Forgiving about how an id is
  written, rigid about which item it names, and it never accepts an item number: a wrong id
  matches nothing and is reported, a wrong number matches something.

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

## The pane toggle (settled, after a great many wrong turns)

Toggling a side pane animates the slot's width, and the document follows it — the plain
thing, which is where this started. It works because of two changes made much later:

- **The fitted sheet fills by LAYOUT** (`body.rv-fitting #rv-page { width: auto }`), not by
  a `zoom` that JavaScript sets. Script-driven sizing arrives a process and a resize event
  later — 30-35 ms, measured — so on every frame of an animating width the sheet was sized
  for the width before last. Filling by layout happens in the reflow WebKit already
  performs, with nothing to wait for and nobody to tell.

- **The sheet is told to give the room up BEFORE the pane takes it** (`rvHold`, review.js;
  every route to a pane goes through `ReviewModel.setPane`). Filling by layout is still a
  reflow in another process, and a reflow in another process is behind: measured at 130
  points at the peak of a pane's travel, which no margin can absorb. Behind while GROWING
  is harmless — the sheet is smaller than its room and takes a moment to fill it. Behind
  while SHRINKING is the bug everybody could see: the sheet is wider than the view, so its
  margin is clipped off and the white runs flush against the pane sliding in beside it.
  So on opening the sheet EASES ITSELF to the new width, with the pane's own curve and
  beat, as a CSS transition — which runs inside the web process, frame after frame, with
  nothing to ask anybody. Closing needs no hold: growing late is only a margin that fills
  in late.

  Taking the width in one step instead was worse than the fault: the sheet is centred, so
  half of a 300-point step comes off each side and the leading edge jumps 150 points out
  and walks back. Shortening the sheet's transition to lead the pane trades the same fault
  smaller — 47 points of drift at nine tenths, 22 at parity — against how close the sheet
  comes to the pane. Parity is the bottom of that curve.

- **`Motion.panel` starts slowly on purpose** — `cubic-bezier(0.65, 0, 0.35, 1)` over
  340 ms, not the hard ease-out it was. The old curve covered two thirds of the distance in
  the first sixty milliseconds, which is faster than WebKit can repaint a reflowing
  document however the sizing is done; the document translated with the pane and then
  snapped. The gentle start is what the growing direction has instead of a hold.

Measured, not guessed, and the instrument is worth keeping: `screencapture -x -v -V 5 -D 1
out.mp4` records the screen at ~50 fps, `ffmpeg -i out.mp4 -vsync 0 f/%04d.png` cuts it into
frames, and a dozen lines of PIL reading one scanline gives the sheet's left and right edge
per frame. Two numbers settle every argument here: the edge AWAY from the moving pane must
not move, and the gap between the sheet and the pane must never fall below the gutter.

Three shapes were tried before that and each was worse; do not reach for them again:

- Snapping the slot and sliding only its CONTENT leaves the slot standing open and empty
  for a quarter of a second. An empty hole is more obviously wrong than a lagging document.
- Not animating at all removes the hole and the lag, and the one cue saying where the pane
  came from.
- Easing the page's zoom to match the pane makes it worse still: this sheet must exactly
  fill the viewport, so a late zoom IS a clipped sheet. Vaelora can ease its page because a
  page is fixed paper that need not fill anything. `BridgeTests` pins the transition gone.

Two things the document keeps and must not lose: its own layer clipped
(`layer.masksToBounds`, since SwiftUI's clip masks only what SwiftUI draws), and no
separate animation from the pane — they are two halves of one width.

Measure before changing any of this. `REVIS_PAGE_LOG` plus an `onGeometryChange` on the
document pane gives both sides of a toggle with timestamps, and that is what settled every
question here. Guessing cost far more than measuring did, every single time.

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
