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

1. **An operation** — Change, Insert, Remove, Move, Question, Comment. A required, closed
   choice, so the reader is told what kind of change is wanted before it reads a word of
   the note. There is a button for each in the toolbar, so marking something up is one
   click; the kind can still be changed afterwards from the row.
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

### Agreeing and disagreeing

A second reviewer does not annotate the document to say "yes, do that" — they give a
**verdict** on the annotation itself: Approve or Decline. This matters to the export more
than it does on screen. A declined request is one somebody refused, so it is taken out of
the instructions entirely and listed under *Declined* with "do not act on them" — handing
it over as work would have an assistant make a change that had been explicitly turned down.
An approved one is marked as agreed, which is the difference between one person's opinion
and a decision.

Short of a verdict there are **replies**: a thread under one annotation. Anyone may reply
to anyone, on a decided annotation as much as an open one — a verdict settles what is being
*asked*, not whether anybody may remark on it, and "declined because the scan dominates the
cost" belongs exactly there. What you may not do is rewrite somebody else's instruction,
which is what replying is for.

A thread is exported as a record of a discussion and never as an instruction. Where a reply
asks for something the instruction above it does not, the reader is told to **do what the
instruction says and report that the two disagree** — the same rule the export already
applies to a fact corrected in one place and left wrong in another. Every reply goes out
quoted and attributed, which is also what stops one that begins `### 8. Change —` from
forging an item in the next review.

### Answering back

The export tells a model that a question wants an answer rather than an edit, and that
words it drafted itself should be declared. Both of those need somewhere to go, so a review
comes back as well as out. A **reply document** is Markdown, one heading per item, the
heading being the item's id:

```markdown
## a6c4e2f0-9d31-4b7e-8f52-1c0d7e5a3b91

**Answered by** Claude

The fifty-individual threshold is not defined anywhere in this document. §2 defines
"Collection event" and "Deletion" and nothing else. I have not changed the text.
```

*File ▸ Import Replies…* takes that — pasted straight out of a chat window, or from a file
— and files each reply under the item it names. It shows you what it is about to attach,
against the annotation it matched, before attaching anything.

Ids, never item numbers. Numbers are assigned at export and differ in the next one; more
to the point, a wrong id matches nothing and is reported, where a wrong number would match
*something*, and an answer filed under the wrong question looks correct forever after.

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

## Trying it on something

`Samples/data-retention-spec.html` is four pages, complete with the things the sanitizer
should refuse. `Samples/large-review.revis` is the other end of the range: a review of a
three-hundred-page specification — 2,013 blocks, 135,000 words — carrying 300 annotations
of every kind, with verdicts, resolutions, drawn regions and reply threads spread all the
way through. Open it to see what the app does at a size worth worrying about.

Both are generated by `LargeDocumentTests` from a seed and committed, which is not a
contradiction: the generator is the source of truth, nothing in it varies run to run, and
the files it writes are byte-identical every time. 880 KB of repetitive prose is 55 KB in
the object store, and it means a clone can open a large review without a toolchain.

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
Samples/        Documents to try it on, including a 300-page one and a review of it, complete with the things it should refuse
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

Verified against real models, twice. Given only the document and the export — no other
context — two model instances applied a deliberately awkward review: a phrase occurring
twice where only the second was meant, a box over a table narrowed by its instruction, a
question to answer rather than act on, and a request a reviewer had declined. Both located
every item from the quoted text alone, neither needed a character offset, and the two
edited documents came out byte-identical everywhere the review specified an outcome. Both
also caught, unprompted, that changing the retention period leaves a clause elsewhere
saying nothing — and reported it rather than fixing it, which is what the export asks for.

Not done yet: freehand drawing and highlighting on the page, comparing two versions of a
document, and the app icon.
