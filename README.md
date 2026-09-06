# Revis

A macOS reviewer for HTML documents that came out of a language model — a specification, a
draft, a report — and a way to mark them up so that the same model can act on what you
said.

It is the other half of [Vaelora](../Vaelora): Vaelora writes a document, Revis reviews
one. There is no editor here. A document opens straight into review mode, rendered exactly
as it was sent, and everything you do to it is an annotation.

## The problem it solves

Marking up a document is easy. Marking it up in a form a model can act on is not.

A highlight, a box round a figure, an arrow into the margin — none of it survives the trip
back to whatever wrote the document, because a model does not see the page. It sees text.
An annotation exported as *"the reviewer drew a rectangle at (412, 880)"* is a description
of a gesture, not an instruction.

So Revis never exports a gesture. Every annotation is three things:

1. **An operation** — Change, Insert, Remove, Move, Question, Approve, Note. A required,
   closed choice, so the reader is told what kind of change is wanted before it reads a
   word of the note.
2. **An address made of text** — the exact quoted string, plus the words either side of it.
   A quote is the only address that survives the document being regenerated. Block indices
   and section paths are exported too, but explicitly as secondary hints, because a reader
   that trusts them after a rewrite will put the edit in the wrong place.
3. **The instruction** — what you actually wrote.

The region tool works the same way. Drag a box over a table and the box contributes the
*choice*; what is exported is **the text the box was drawn over**. That is the whole trick,
and it is why drawing on the page is worth having at all.

### What comes out

```markdown
### 3. Change — 3. Retention periods › 3.1 Personal data › paragraph 1

Rewrite the quoted text.

**Find this text**

> retained for a period of ninety (90) days

**Context**

> …All personal data is «retained for a period of ninety (90) days» from the date of…

**Instruction** — Robert

Make this 30 days, and say what starts the clock.
```

Plus a JSON sidecar carrying the same items as fields, for a script that applies a review
rather than a model that reads one.

## Safety

The document is untrusted input. It is made inert in four independent layers, and none of
them is trusted to be the only one:

| Layer | What it does |
| --- | --- |
| **Sanitizer** | A hand-written tokenizer — not a regular expression — strips every script (contents included), every `on…` attribute, every frame, object and form control, and every URL whose scheme can execute. Runs before a byte reaches WebKit. |
| **Content Security Policy** | The page is served under `default-src 'none'` with `script-src 'none'`, no `connect-src`, `form-action 'none'`, `base-uri 'none'`. A script that survived the sanitizer still cannot run. |
| **Isolated content world** | The review runtime is injected as a user script into its own `WKContentWorld`, which is exempt from the page's CSP — which is precisely what lets that CSP be absolute. Page script, if any existed, could not see or forge the bridge. |
| **Process** | Navigation delegate cancels everything after the initial load; non-persistent data store; release builds ship **without** the network entitlement. |

Images are resolved by the app, from inside the document's own folder, and embedded as data
URLs before the page is shown — the document never gets to ask for a file, and a path that
escapes the folder is refused rather than read.

Whatever had to be removed from a given document is reported in that window's inspector. An
app that rewrites a file before showing it owes the reviewer that much.

## Two things worth knowing

**A review holds a snapshot of the document.** Not a pointer to it. Every anchor is measured
against the text, and the entire point of the exercise is that the document gets
regenerated — at which point a review that only remembered a path would have every mark
silently pointing at something that no longer exists. A `.revis` file says what was
reviewed and what was said about it, identically a year later.

**Reviewing a file never modifies it.** Opening `spec.html` produces an untitled review;
saving asks where to put the `.revis`. This is enforced twice — the window detaches from the
source URL on import, and the writer refuses any content type but `.revis` — because AppKit
autosaves a document back to where it came from, and the first run of this app against a
real document destroyed it. See `SourceDetachment`.

## Building

```bash
./scripts/build.sh -r        # generate, build Debug, relaunch
```

Needs [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`); the
Xcode project is generated from `project.yml` and is not in the repository.

```bash
xcodebuild -project Revis.xcodeproj -scheme Revis test
```

## Layout

```
Revis/
  App/          Scene, document, menu commands, window plumbing
  Models/       Annotation, intents, palette, per-window review model, settings
  Document/     Sanitizer, image resolution, page shell, export
  Views/        Review window, annotations pane, inspector, settings
  Resources/    review.css, review.js — the document runtime
Samples/        A generated spec to try it on, complete with the things it should refuse
Tests/
```

## Showing the document

Two controls, both in the bar along the bottom and both also in View:

**Zoom** uses the CSS `zoom` property rather than a transform, so the page genuinely
re-lays out at the new size — text stays crisp, line breaks fall where they really would,
and mouse coordinates stay in the page's own space, which is what keeps the margin marks
landing on the right lines. *Fit Width* is a measurement taken by the page, not a number
the app guesses.

**Document style / Reading style.** By default a document is drawn with its own stylesheet,
because that is what is under review — the chrome's defaults are all wrapped in `:where()`
so they carry no specificity and lose to anything the document says. The switch sets that
stylesheet aside for a plain reading style, for documents that arrive genuinely hard to
read. It is loud about being on: what you are looking at then is *not* how the document
looks.

## Status

First version, exercised end to end against a real generated document: opening and
sanitizing, text and region annotations with intents, the annotations pane, the outline and
provenance inspector, zoom, the stylesheet switch, saving a `.revis`, and the
Markdown/JSON export.

Not verified yet: whether a model actually applies the export correctly. The export is
prose keyed on quoted text, with block indices marked explicitly as tie-breakers — the open
question is whether that is enough to locate every item without alignment, or whether the
anchors need to be carried in the document itself. That is the next test.

Not done yet: freehand drawing and highlighting on the page, replies to an annotation,
comparing two versions of a document, and the app icon.
