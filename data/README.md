# Kinyarwanda moderation data

Every file in this directory is data, not code. They are the word lists the
library loads, and they are meant to be read, reviewed, edited and versioned by
people who do not have to be Elixir developers.

| File | What it is |
| --- | --- |
| [`rw_lexicon.json`](rw_lexicon.json) | The lexicon the library loads by default. Structured: categories that each carry a severity, a suggested action, single terms and multi-word phrases. |
| [`rw_hate_speech.json`](rw_hate_speech.json) | A flat array of terms, kept as a minimal example of the flat list format. It is **not** loaded by default; it exists to show the simpler shape. |
| [`lexicon.schema.json`](lexicon.schema.json) | JSON Schema for both accepted shapes. Your editor can use it for completion and validation, but the library's own loader is the authority on what loads. |

> [!IMPORTANT]
> The bundled `rw_lexicon.json` ships with **placeholder** entries only. It is a
> working example of the format, not a hate-speech list. Read the `"notice"`
> field inside it before you rely on this library for anything real.

## Read this before you use or quote these words

<!-- Keep this block in sync with the "A disclaimer about the word lists" section in the project README. -->

> [!CAUTION]
> **Read this before you use the bundled data.**
>
> This directory contains Kinyarwanda words and phrases that are, in themselves,
> abusive. They are here as **detection patterns and nothing else**.
>
> **The list is not our opinion.** Including a term means "this string has been
> observed in abusive Kinyarwanda text", not that we endorse writing it, agree
> with what it expresses, or believe anything it implies. A lexicon entry is a
> mapping from spelling to a moderation decision. That is the whole of it.
>
> **The list is not a verdict about any person, group or community.** Many of
> these strings are ordinary Kinyarwanda words, names, place names and everyday
> parts of speech. Several carry meaning that changes entirely with context, and
> the same word can be affectionate, neutral or cruel depending on who is
> speaking and why. This library does not and cannot tell those apart. It reports
> that a string matched, and hands the decision to a human. Treat its output as a
> signal to look closer, never as a finding.
>
> **The list is not a substitute for judgement.** It is incomplete, it will
> contain items you disagree with, and it will miss things it should catch. It is
> a starting point that you are expected to review, edit and own before you rely
> on it. An automated filter should never be the only thing standing between a
> person and their account, their post or their reputation.
>
> **Do not copy this list into anything that presents it as a definition of what
> Kinyarwanda is, or of who Rwandans are.** Quoting these terms in documentation,
> training data, papers or datasets, or treating the filter's decisions as
> labels, misses what they are for and will misrepresent both the language and
> the people who speak it.
>
> If you maintain this list: add a term when it is genuinely used to harm people,
> not merely because it is crude. If you think an entry should not be here, that
> is a useful bug report, not an offence.

## Which shape should I use?

Use the **structured** shape (`rw_lexicon.json`) whenever you need to tell
categories apart, because it is the only one that carries per-category severity
and a suggested action. Use the **flat** shape (`rw_hate_speech.json`) when all
you have is a bag of words and you want to get started quickly: the library
loads a flat array as a single `flat_terms` category with severity `medium`,
action `flag` and version `0.0.0`.

Both shapes are described in [`lexicon.schema.json`](lexicon.schema.json). The
normalization options that decide how forgiving matching is (`fold_l_r`,
`squash_doubles`, `augment_drop`, `glued_phrases` and the rest) are documented
in the [project README](../README.md#the-lexicon-is-data-not-code).

## Adding or removing a word

Edit the JSON, bump `version` in the structured file, and open a pull request.
No Elixir required. Two things are worth checking before you send it:

- Does the word still match when someone spells it loosely? Kinyarwanda is
  written inconsistently online, so a term is often better added together with
  the spelling variants it is used with.
- Does it hit ordinary text? A short or common word can fire on innocent
  sentences; the schema lets you give such a term a lower severity or a gentler
  action instead of dropping it.

You can point the library at a list of your own instead of these files, and
reload it without a restart. See
[Bring your own lexicon](../README.md#bring-your-own-lexicon).
