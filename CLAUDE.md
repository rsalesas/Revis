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

- `Document/MarkdownRenderer.swift` — the only place Revis talks to Apex, and the only
  place that knows `apex_options` exists. Three things in it are load-bearing. It uses the
  **`ApexC`** product, not the `Apex` Swift wrapper: the wrapper's targets carry
  `.unsafeFlags`, which SwiftPM refuses outright when a package is depended on by version,
  and its `ApexOptions` exposes twelve of the ninety-odd flags — none of the ones a reviewer
  wants. Calls are serialised behind a lock, because two threads in
  `apex_markdown_to_html` at once abort inside libsystem_c (found by the parallel test run;
  a sequential run never sees it). And `relaxed_tables` is forced OFF against the mode
  presets, which enable it for Kramdown, Unified and Quarto — with it on, an ordinary pipe
  table that has a header rule loses its header, `<th>` cells coming out as `<td>`.
- `Document/MarkdownShadow.swift` and `MarkdownLocator.swift` — carrying a quote from the
  page back to the file. The shadow is the piece here that can be *quietly* wrong, so the
  test that matters is `shadowReproducesTheRenderedText`: its text and Apex's rendered text
  must be the same string, checked against Apex itself. If you touch the scanner, run it —
  and remember that a construct's handling has to be gated on the same option Apex was
  given, or the shadow reads a `[^1]` the page rendered as literal text.
- `Document/PageBackground.swift` — what colour the document says its page is, and
  whether that is a dark one. It exists because the sheet was paper-white always, which
  made the app honour a document's ink and override its paper: invisible for a document
  designed light, fatal for one designed dark. Two rules to keep. Only TOP-LEVEL
  `html`/`body`/`:root` rules count — a `@media (prefers-color-scheme: dark)` branch is not
  what renders, because the web view is pinned light so the guest resolves its light
  palette. And the value is handed on UNRESOLVED: the browser converts it and reports back,
  because `getComputedStyle` does not normalise to `rgb()` — a document authored in
  `oklch()` reports `oklch()`, and resolving that in Swift means an OKLab matrix to answer
  what WebKit answers for free. `resolveColour` in review.js fills a one-pixel canvas and
  reads the bytes, so `lab()` and `color(display-p3 …)` are already handled. Swift decides
  what the answer MEANS — `data-rv-paper`, pushed like `rvSetDesk`, one source two readers.
- `Document/HTMLSanitizer.swift` — the tokenizer. The one place where being wrong is a
  security bug. It is a denylist over elements and an allowlist over attributes; keep it
  that way, and add a test to `Tests/SanitizerTests.swift` for anything you change.
- `Document/DocumentShell.swift` — the CSP. `script-src 'none'` is absolute because the
  runtime is a user script; do not add a nonce or an inline `<script>` to the page.
- `Resources/review.js` — runs in an isolated `WKContentWorld`. It stamps `data-rv`
  indices, computes anchors, and draws. Text highlights use the Custom Highlight API rather
  than wrapping spans, because wrapping mutates the DOM and every stored offset is measured
  against it.
- `Models/MarkdownOptions.swift` — what a Markdown document was read as. Stored in the
  review, not just in the preferences: the same file read as CommonMark and as Kramdown is
  two different documents, and the annotations were made against one of them. Hand-written
  `init(from:)` for the reason below.
- `Models/Annotation.swift` — the anchor model, and the reasoning for carrying four
  addresses for one place. Also `Annotation.init(from:)`, which is hand-written and must
  stay that way: Swift's synthesised decoder throws on a missing key even when the property
  has a default, and `ReviewDocument` turns a decode failure into "this is HTML" — so a
  field added without it does not fail loudly, it makes every saved review reopen empty.
- `Document/ReplyImport.swift` — reading a reply document. Forgiving about how an id is
  written, rigid about which item it names, and it never accepts an item number: a wrong id
  matches nothing and is reported, a wrong number matches something.

## Adding a field to anything that goes in a `.revis`

The trap is written up in `Annotation.init(from:)` and it is worth reading before touching
any of these types. Swift's synthesised decoder throws on a missing key even where the
property has a default; `ReviewDocument` turns a decode failure into "this must be HTML";
so a field added carelessly does not fail loudly — it makes every review already on disk
reopen empty, as a review of its own JSON.

`Annotation`, `Intent` and `MarkdownOptions` decode by hand and are safe. `PreparedDocument`
and `SanitizationReport` still use the synthesised decoder, which is why `markdown` was
added to `PreparedDocument` as an **Optional** — Optionals are the one kind the synthesised
decoder tolerates missing. Anything non-optional added to either of those needs a
hand-written `init(from:)` first.

## The updater, and what it cost

Revis used to ship **sandboxed with no network entitlement**, and `release.sh` refused to
publish a build that was anything else. Both of those are gone, deliberately, and the
trade is the thing to understand before touching any of it: a sandboxed app cannot replace
itself in `/Applications` — from inside a container `isWritableFile` answers false and the
write fails with `NSFileWriteNoPermissionError` — so an in-place update can only ever be
refused at its very last step. Vaelora hit exactly this and dropped its sandbox for the
same reason.

What replaced it is *not* nothing, and it is written out in
`Revis/Revis.DeveloperID.entitlements`. The containment that mattered was always below the
sandbox: the sanitizer, the CSP, the isolated content world, the navigation delegate. The
app now holds one entitlement, `com.apple.security.network.client`, and `release.sh`
asserts on the **signed bundle** that it is not sandboxed, that it holds that entitlement,
and that it holds *nothing else* — the last of those because the README makes the claim to
a reader and a claim that can be checked should be.

- `Revis/Update/UpdateChecker.swift` — the manifest, and what a fetched one means. Fails
  closed everywhere: an unparseable version, a 404, a build needing a newer macOS all end
  as "up to date" or a reported failure, never as an offer. `URLSession` does not throw on
  an HTTP error status, so the status is checked by hand — without it a captive portal's
  login page goes to the JSON decoder.
- `Revis/Update/AppUpdater.swift` — installing one. Doing the swap ourselves bypasses the
  Gatekeeper check a fresh download would get, so this has to do Gatekeeper's job:
  SHA-256 against the manifest, a code-signing requirement pinned to the Developer ID
  **chain** (team alone accepts our own Debug builds — a test caught that), and strictly
  newer than the running copy. Everything before the hand-off is reversible.
- `Updater/` — the `revis-updater` helper, its own `tool` target. It exists because a
  bundle cannot replace itself while its own code is mapped. Two traps live in its target
  settings and are commented there: `SKIP_INSTALL` (without it the archive holds two
  installed products and *every* distribution method is rejected), and a module name that
  must not near-miss the app's on case-insensitive APFS.
- `Revis/Update/SemanticVersion.swift` — not `AppVersion`, which is taken by "what am I".
  A type with tests rather than an inline `<`, because `"0.2.10" < "0.2.9"` is true.

## Releasing

`./scripts/release.sh` builds and publishes four assets in one act: the DMG, the updater's
ZIP, `appcast.json`, and a copy of the DMG under a stable name. `--dry-run` stops after
signing and verifying, with nothing having left the Mac.

Two orderings in it are load-bearing, and both are guarded on the artifact rather than on
the sequence that produced it:

1. **The app is notarized and stapled BEFORE the DMG is built around it**, and the DMG is
   then notarized and stapled itself. A ticket on the disk image says nothing about the app
   inside it, and an app without its own ticket can only prove it was notarized by asking
   Apple at first launch — which stalls offline or behind a captive portal. The finished
   image is mounted again and the app inside it validated, because Vaelora shipped this bug
   for many releases with every step reporting success.
2. **The helper is re-signed with a real timestamp after export**, and the app re-sealed
   around it. The post-build script signs it `--timestamp=none` to keep Debug builds
   offline and fast; the notary service will not accept that.

The manifest points at the **immutable per-tag** URLs, never `releases/latest/` — a client
holding a checksum must not have the bytes swapped underneath it. The one thing that reads
`latest` is the manifest URL itself, which is how GitHub serves a stable address for the
newest release. `UpdateTests` guards that seam from the Swift side: it reads `release.sh`
out of the source tree and checks the keys it writes against what `UpdateManifest`
decodes, and that both files name the same repository. Nothing else would catch a drift —
an unreadable manifest is a failed check, and a failed check looks exactly like being up
to date.

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
