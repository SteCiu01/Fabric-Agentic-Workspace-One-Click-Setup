---
name: product-communication
description: 'House style for the documents people read in this repository: README, CHANGELOG, CLI-FUNCTIONALITIES, CONTRIBUTING, tests/README, release notes. Use when writing, updating or reviewing documentation, a changelog entry or release text, when a code change affects what users see, or before a release. Covers voice, structure, what each document is for, changelog rules, accuracy checks and which files are never rewritten (LICENSE, SECURITY, CODE_OF_CONDUCT).'
---

# Product communication

Write for the person who has to use or maintain this product, not for an AI agent. Say what the product does, in plain words, and stop.

## Principles

1. **One document, one purpose.** Put each fact where its reader looks for it (table below) and link to it from elsewhere.
2. **Lead with what matters.** The first lines say what this is and what the reader can do with it.
3. **Simple words, short sentences, active voice.** "Use", not "utilize". "The installer writes the file", not "the file is written".
4. **Bullets when they help scanning**: parallel items, steps, options. Use prose when ideas depend on each other.
5. **Explain a technical term only when the reader needs it**, once, where it first appears.
6. **Keep what is true and needed**: commands, prerequisites, limitations, safety notes. Never drop one of these to save words.
7. **Cut the rest**: repetition, filler, praise, and anything written to sound complete.
8. **Never invent** a feature, a release, a date or a test result.

## Voice

Knowledgeable, friendly, direct. Confident without exaggeration. Technical when the subject is, approachable otherwise.

Describe what happens; do not sell it.

- Not: "This release introduces a comprehensive suite of enhancements designed to streamline the user experience."
- But: "Added pipeline definition validation. Fixed installer commit handling."

Avoid: comprehensive, seamless, robust, cutting-edge, powerful, leverage, streamline, optimize the experience, simply, easily, please note.

Address the reader as "you". Keep the spelling variant and the terms the document already uses; one term per concept.

## What each document is for

| Document | Purpose | Rules |
|---|---|---|
| `README.md` | What the product is, what it can do, how to start | Short overview, a clear installation path, links for detail. No release history. |
| `CHANGELOG.md` | What changed between versions | The only release history. Short bullets. No development diary. |
| `CLI-FUNCTIONALITIES.md` | What the supported CLIs do today | Real commands, their purpose, an example where it helps. |
| `CONTRIBUTING.md` | How to contribute | Practical steps. No general philosophy. |
| `tests/README.md` | What the test suite guarantees | One row per test file: what it proves. |
| `SECURITY.md`, `CODE_OF_CONDUCT.md` | Policy | Check accuracy and links. Propose any change of substance; do not make it. |
| `LICENSE`, `THIRD_PARTY_NOTICES.md` | Legal terms | Never rewrite. Check that they exist and are referenced correctly. |

Do not add a new Markdown file or a history folder when one of these can hold the content.

## Changelog

- Newest version first. A version without a date is not released yet; never give it one.
- Group under **Added, Changed, Fixed, Removed, Deprecated, Security**. Leave out empty groups.
- One change, one bullet, one or two sentences: what changed for the user, then why it matters if that is not obvious.
- State removals, deprecations and anything that needs action on upgrade.
- Do not repeat a change under two headings or in another document.
- Earlier releases are history: correct errors, shorten wording, but keep the facts.

## Accuracy

Document the product as it is now, verified, not as planned.

- A feature is described only when it exists and its behaviour has been checked (source, test or a run).
- Every command, option, file name, path and version in the text must match the source. Run or grep before you write.
- Links and anchors must resolve.
- If you cannot verify a statement, leave it out or ask.

## Before you finish

1. Read the first screen of each changed document: would a newcomer know what this is?
2. Remove one more sentence from each paragraph if nothing is lost.
3. Check commands, names, versions and links against the source once more.
4. List what you changed, and what you propose but did not change.

Sources distilled here: Microsoft Writing Style Guide (concise sentences, scannable content), Google developer documentation style guide (highlights, voice and tone), Diataxis (one purpose per document), Keep a Changelog 1.1.0.
