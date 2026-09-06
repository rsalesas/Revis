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

## Testing

`xcodebuild -project Revis.xcodeproj -scheme Revis test`, or `./scripts/build.sh` first if
you added a file. Swift Testing, not XCTest. Fixtures are read out of the source tree by
`#filePath` and excluded from the bundle, so a fixture is added by dropping a file into
`Tests/Fixtures`.

The JavaScript runtime has no tests yet, and that is the biggest gap in the suite.
