# Revis

A macOS reviewer for documents that came out of a language model — a specification, a
draft, a report — and a way to mark them up so that the same model can act on what you
said. HTML or Markdown.

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

## Markdown

A `.md` opens the same way a `.html` does. It is rendered by
[Apex](https://github.com/ApexMarkdown/apex) — CommonMark, GFM, MultiMarkdown, Kramdown,
Quarto, or everything at once — and the result goes through exactly the same sanitizer and
the same CSP as any other document, because a Markdown file can contain raw HTML and being
produced by a renderer is not a reason to trust it.

Which dialect a file is in is a fact about the file, so it is a property of the *document*,
stored in its review and changed in that window's own **Markdown** inspector tab — which
appears only for a Markdown document. Settings holds the guess made before anyone has
looked at it, and nothing else. Change the dialect and the document is read again;
anything that no longer matches is listed rather than left to be noticed, and nothing is
deleted.

### The part that is actually hard

You review the rendering. The assistant edits the source. Those are two documents, and an
annotation quoting *"retained for ninety days"* is not an address in a file that says
`retained for **ninety** days`.

Apex cannot help with this — it has no source positions in its HTML, none in its C API and
none in its JSON AST, and could not have useful ones anyway, since a dozen of its
extensions rewrite the source text before cmark ever parses it. So Revis carries the quote
back itself, and the way it does so falls straight out of what the app already is: **every
annotation was always addressed by quoting it**, so the question is not "where is this node"
but "where are these words", which is a search.

`MarkdownShadow` reads the file into the text a reader sees — emphasis markers dropped,
link targets dropped, `---` folded to the em dash it becomes, footnote definitions moved to
where the renderer puts them — while every character keeps a note of the source it came
from. `MarkdownLocator` then finds the annotation's words in that shadow, using the context
and the heading trail the anchor already stores to pick between repeated passages. The
export quotes **the source file's own spelling**, markup and all, so a reader can search
for it literally, with the page's reading underneath.

And where a quote is *not* in the file — a generated table of contents, a footnote's `↩`,
the numbering — the item says exactly that instead of approximating it to the nearest
thing. A wrong address that looks right is the one failure this app is not allowed to have.

## Safety

The document is untrusted input. It is made inert in four independent layers, and none of
them is trusted to be the only one:

| Layer | What it does |
| --- | --- |
| **Sanitizer** | A hand-written tokenizer — not a regular expression — strips every script (contents included), every `on…` attribute, every frame, object and form control, and every URL whose scheme can execute. Runs before a byte reaches WebKit. |
| **Content Security Policy** | The page is served under `default-src 'none'` with `script-src 'none'`, no `connect-src`, `form-action 'none'`, `base-uri 'none'`. A script that survived the sanitizer still cannot run. |
| **Isolated content world** | The review runtime is injected as a user script into its own `WKContentWorld`, which is exempt from the page's CSP — which is precisely what lets that CSP be absolute. Page script, if any existed, could not see or forge the bridge. |
| **Process** | Navigation delegate cancels everything after the initial load; non-persistent data store; release builds ship **without** the network entitlement. |

A Markdown document is refused four of Apex's abilities outright, and they are not
settings: file includes, bibliographies and concordances all read files at paths the
*document* chooses — the containment check that guards images does not exist inside Apex —
and the plugin system downloads and loads external code, which is the one thing this app is
built to make impossible.

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
should refuse. `Samples/retention-spec.md` is the Markdown equivalent: metadata block,
definition lists, footnotes, a table, task lists, and two sections that say the same
sentence on purpose, so you can watch the export tell them apart. `Samples/large-review.revis` is the other end of the range: a review of a
three-hundred-page specification — 2,013 blocks, 135,000 words — carrying 300 annotations
of every kind, with verdicts, resolutions, drawn regions and reply threads spread all the
way through. Open it to see what the app does at a size worth worrying about.

`Samples/large-spec.md` is the Markdown one at the same size — 135,000 words, 250
headings, 212 footnotes, hard-wrapped at 88 columns so that nearly every quote worth
marking crosses a line break, with an appendix that says one passage twice word for word.

All three are generated by `LargeDocumentTests` from a seed and committed, which is not a
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

### The app icon

`scripts/icon.svg` is the icon. The PNGs under `Revis/Assets.xcassets/AppIcon.appiconset`
are rendered from it, never edited:

```bash
./scripts/make-icon.sh            # re-render all ten from the SVG
./scripts/make-icon.sh --check    # render to a temp dir and diff, changing nothing
```

If a build comes up wearing the generic blank-application icon, the bundle is almost
certainly fine and macOS is not. This app icon set was empty for its first few dozen
builds, and LaunchServices caches *per bundle path* — so any copy launched during that
time has "no icon" recorded against it, and rebuilding does not dislodge it, because
nothing about the bundle is what it is consulting:

```bash
LS=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support
"$LS/lsregister" -f /path/to/Revis.app && killall Dock
```

Check the bundle before believing the cache, because the two failures look identical from
the outside and only one of them is yours: `iconutil -c iconset Contents/Resources/AppIcon.icns`
unpacks what the Dock and the About panel actually read, and `assetutil --info
Contents/Resources/Assets.car` lists what the catalog holds. If the artwork is in both,
stop editing the icon.

## Layout

```
Revis/
  App/          Scene, document, menu commands, window plumbing
  Models/       Annotation, intents, palette, per-window review model, settings
  Document/     Sanitizer, image resolution, page shell, export
  Views/        Review window, annotations pane, inspector, settings
  Document/     …also the Markdown renderer, the source shadow and the locator
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

## Licence

Source-available, not open source. Revis is under the
[PolyForm Noncommercial 1.0.0](https://polyformproject.org/licenses/noncommercial/1.0.0)
licence: read it, build it, change it, use it for anything noncommercial. Commercial use
needs a separate licence — write to robert@salesas.com.

That covers Revis's own source only. The Markdown engine and the two libraries under it are
open source under their own terms, reproduced in full in
`Revis/Resources/ACKNOWLEDGEMENTS.txt` and shown in the app under *Settings ▸
Acknowledgements*. Nothing in Revis's licence withdraws any right those grant you in that
software.

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
