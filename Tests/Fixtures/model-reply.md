# Replies

## c52818a0-988f-441a-ae7e-d169cb1dabc1

**Answered by** Claude

Applied — §3.1 now reads "thirty (30) days".

One place still says ninety, and I have not touched it because you did not ask me to.
§5 Open questions begins "Does the 90-day period start at collection or at last
access?" That is now inconsistent with §3.1 and with the summary table. Say the word
and I will change it to 30, or reword the question so it does not carry a number.

## 0b10dfa0-1c19-4909-a0e9-34f1f33f8670

**Answered by** Claude

I have applied the instruction as written: §3.2 now reads "retained for five years".

Two things to flag rather than decide.

1. **The instruction and the reply disagree.** Your instruction says five years; Priya
   Raman's reply says legal settled on two years at last week's review. I followed the
   instruction, because a reply is a record of a discussion and not the request. If two
   is the number, §3.2 needs a second edit.

2. **§3.3 still says Indefinite for Aggregates.** Item 4 asked me to make the retention
   column match §3.1, which covers the Personal data row only, so I changed that row and
   left the Aggregates row alone. Whatever number wins — five or two — that row needs the
   same edit, and it does not have it yet.

## 7fd488bb-f631-475e-83de-9159b55d662f

**Answered by** Claude

Applied narrowly: the Personal data row's retention is now 30 days, matching §3.1 as
corrected. The other rows in the retention column are untouched, since §3.1 does not
speak to them.

Noting again for this item, since it is the block you boxed: the Aggregates row still
reads Indefinite while §3.2 now reads five years. That mismatch is inside the region you
drew but outside what the instruction asked for, so I have left it and reported it here.

## bfccc5f9-c4dc-49a1-bab5-bf34ba92f138

**Answered by** Claude

**I drafted these words — they are mine, not yours.** Appended to the end of §4's first
paragraph:

> If a replica is offline when the delete is issued, the tombstone remains outstanding
> for that replica and the worker reissues the delete on each subsequent run until the
> replica acknowledges it; the record is not treated as deleted until every replica has
> acknowledged.

I inferred the retry-until-acknowledged behaviour from the paragraph's existing shape —
an hourly worker, a tombstone written before the deletes, and the same tombstone replayed
on backup restore. If the real behaviour differs — a bounded number of retries, a dead
letter path, or a replica that is dropped from the set rather than retried forever — the
sentence should be replaced rather than edited, because the second clause about when a
record counts as deleted rests on the first.

Worth noting that this sentence interacts with the Deletion definition in §2 (item 8,
which you asked to leave exactly as it stands). That definition calls deletion
irreversible removal from all replicas; my sentence says when that state is reached. I
believe they are consistent, but you should be the judge of that.

## 893efbbe-78e7-41ef-aac3-b48d80dbb3f1

**Answered by** Claude

It is not defined anywhere in this document. I searched the whole of it, not just §2.

- §2 defines two terms only, Collection event and Deletion. Neither mentions cohort size.
- The number fifty appears exactly once in the document, in the §3.2 sentence you marked.
  There is no other mention of cohorts, thresholds, or k-anonymity.
- §3.3's summary table has no row or note carrying it, and §5's open questions do not
  raise it.

So the sentence relies on a threshold the specification never establishes. Two further
gaps follow from that, both of which look like document faults rather than questions of
wording:

- **Cohort is itself undefined.** Even given the number, the rule cannot be applied
  without knowing what is being counted — individuals contributing to a bucket, distinct
  identifiers, or something else.
- **The rule has no consequence stated.** A sub-fifty aggregate is "treated as personal
  data", but nothing says whether that means it inherits §3.1's retention period (now 30
  days), or the Personal data row of §3.3, or only the deletion obligations. As §3.2 and
  §3.1 now name different periods, that ambiguity has a real cost.

I have not changed anything to fix this — you asked a question, and the answer is that
the document is incomplete here. It probably wants either a definition in §2 or a
citation to whichever privacy standard the fifty came from.
