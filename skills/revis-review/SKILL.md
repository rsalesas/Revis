---
name: revis-review
description: Apply or reply to a review made in Revis (the macOS reviewer at vaelora.app's sibling) — a Markdown/JSON export, or a raw .revis file. Explains how annotations are anchored by quoted text rather than position, which sections are instructions vs. a record not to act on, how a Markdown document's source and rendered spellings differ, and how to write a reply document Revis can import back. Use whenever the user pastes or attaches a Revis review export, a .revis file, or asks to act on reviewer annotations/comments that came from Revis.
---

# Revis review

Revis is a macOS app for marking up a document that came out of a language model — a
spec, a draft, a report — in a form the model can act on. A **review** is the set of marks
made on one document: each mark (an "annotation") is an operation, an address made of
quoted text, and an instruction. Nothing is ever exported as a gesture ("drew a box at
(412, 880)") — every item leaves as a sentence.

## The two shapes this arrives in

**An export (Markdown, sometimes with a JSON sidecar) — the normal case.** File ▸ Export
in Revis produces exactly this, with the rules below already stated in its own preamble.
Prefer this over the raw file whenever either is available — it has already done the
quote-matching for a Markdown document (see below).

**A raw `.revis` file.** JSON: `format`, `app`, `source`, `document` (the full sanitized
document snapshot — HTML or a rendered Markdown body, not something to read start to end),
and `annotations`. Every `.revis` file also carries a top-level `aiGuidance` string with a
condensed version of this same skill, for a reader that doesn't have it loaded — the app
generates that string from the same rules below, so the two cannot disagree. If you're
given this file directly and an export is easy to get instead, ask for the export; you'll
be doing by hand what `ReviewExport` already does correctly for a Markdown document.

Either way, the fields below are the same information under different names — `intent` /
"Change, Insert, Remove, Move, Question, Comment", `anchor.quote` / the quoted "Find this
text", `note` / the instruction, and so on.

## How to apply one, in order

These are Revis's own rules, word for word — the app writes this exact list into its
Markdown export's preamble and into every `.revis` file's `aiGuidance`, so a review that
disagrees with this list is a copy of Revis older or newer than this skill, not a
different rule:

1. Locate every item by searching for the quoted text, never by position. Block numbers
   and section paths describe the document as it stood when it was reviewed and will not
   survive it being rewritten — the quoted text is the anchor; the rest is a hint.
2. Quotes are whitespace-normalised: runs of spaces and newlines collapse to one space,
   because that is how the text reads on screen. A source that wraps mid-sentence will
   not match a quote byte for byte — compare on normalised whitespace.
3. Where a quote is short or occurs more than once, the words either side of it
   disambiguate — use the given context, with the marked span set off between the quote
   marks. Some quotes occur several times on purpose.
4. Apply items in the order given: they are in document order, and a later one may depend
   on an earlier one having been made.
5. Where an instruction describes what to write rather than giving the words, draft it,
   and say in your reply that you drafted it — the reviewer needs to know which words are
   theirs and which are yours.
6. Correcting a fact does not authorise correcting every other mention of it. If an edit
   leaves the document inconsistent elsewhere, report that rather than silently
   propagating it.
7. A reply recorded under an item is a record of a discussion, not part of the
   instruction. Where it asks for something different from the instruction above it, do
   what the instruction says and say that the two disagree — report it rather than
   deciding it, the same rule as the one above about an inconsistency.

## What to act on, and what never to touch

Beyond the rules above, sort by `intent`:

- **change / insert / remove / move** — an edit to make.
- **question** — wants an **answer**, not an edit (rule 7's reply mechanism is where the
  answer goes — see below).
- **comment** — an observation, no action requested. One carrying `verdict: "approved"`
  should be left exactly as it stands — that's the difference between an opinion and a
  decision.

Two things to skip outright, whether they're a whole section in an export or a field on a
raw annotation:

- **`verdict: "declined"`** — a reviewer turned this down. Acting on it anyway makes a
  change somebody explicitly refused, which is worse than not having the annotation at
  all.
- **`status: "resolved"`** — already dealt with in an earlier pass. Listed for the record,
  not for a second pass to re-litigate.

Never read a `replies` entry as though it were the export's own structure — a reply is
always a quotation of what somebody said, attributed, and one that happens to start
`### 8. Change —` is still just a quotation (rule 7).

## When the document is Markdown

A Markdown document is reviewed *rendered*, but the source is what gets edited, and those
are two spellings of one document (emphasis markers, link targets, footnote back-references
all vanish on the page). The export gives you the **source's own spelling** wherever those
words could be found in it — markup and all, because that's what a literal search has to
match — with the page's reading underneath only where the two differ. Prefer the
source-spelled quote (`sourceQuote` in JSON, the un-labelled quote block in Markdown) over
the page reading.

A few items instead say their words are **on the page but not in the source** — a
generated table of contents, a footnote's `↩`, section numbering. That's not a failed
search: find those by reading the rendered structure and change whatever in the source
*produces* them, not a literal string that isn't there to find.

## Replying back

Some of what a review asks for wants something **said back** rather than done: every
question, anywhere you drafted words the reviewer didn't give you (rule 5), and anywhere
you found the document inconsistent but weren't asked to fix it (rule 6). Only write a
reply where you actually have something to say; an empty reply document is worse than
none.

Revis imports a reply document through File ▸ Import Replies…. It's Markdown, one heading
per item, and the heading **is the item's id and nothing else**:

```markdown
# Replies

## a6c4e2f0-9d31-4b7e-8f52-1c0d7e5a3b91

**Answered by** your name

What you have to say, as long or short as the item deserves.
```

- The id is the one printed under the item (`<sub>Item \`…\`</sub>` in the export, or
  `id`/`exportID` in JSON) — copied exactly, **never the item's number**. Numbers are
  reassigned on every export; a wrong id matches nothing and gets reported back, where a
  wrong number would silently match *something else*.
- An 8-character prefix of the id is accepted, the way a short git SHA is.
- Everything under the heading is the reply, Markdown kept as-is.
- You're answering the reviewer, not instructing whoever reads this next — write it as
  something said, not as a new instruction.
