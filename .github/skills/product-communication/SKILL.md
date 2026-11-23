---
name: product-communication
description: 'House style for the documents people read in this repository: README, CHANGELOG, CLI-FUNCTIONALITIES, CONTRIBUTING, tests/README, release notes. Use when writing, updating or reviewing documentation, a changelog entry or release text, when a code change affects what users see, or before a release. Covers voice, what each document is for, changelog rules, the review checklist (purpose, concision, readability, accuracy, numbers and images, navigation, public versus internal) and the files that are reviewed but never edited (SECURITY, CODE_OF_CONDUCT, LICENSE, THIRD_PARTY_NOTICES).'
---

# Product communication

Write for the person who has to use or maintain this product, not for an AI agent. Say what the product does, in plain words, and stop.

## Principles

1. **One document, one purpose.** Put each fact where its reader looks for it (table below) and link to it from elsewhere.
2. **Lead with what matters.** The first lines say what this is and what the reader can do with it.
3. **Simple words, short sentences, active voice.** "Use", not "utilize". "The installer writes the file", not "the file is written".
4. **Bullets for parallel items, steps and options.** Prose when ideas depend on each other. A table only when rows share a few short columns, never a table of paragraphs.
5. **Explain a technical term once**, where it first appears, and only when the reader needs it.
6. **Keep what is true and needed**: commands, prerequisites, limitations, safety notes. Never drop one of these to save words.
7. **Cut the rest**: repetition, filler, praise, and anything written to sound complete.
8. **Never invent** a feature, a release, a date, a number or a test result.

## Voice

Knowledgeable, friendly, direct. Describe what happens; do not sell it.

- Not: "This release introduces a comprehensive suite of enhancements designed to streamline the user experience."
- But: "Added pipeline definition validation. Fixed installer commit handling."

Avoid: comprehensive, seamless, robust, cutting-edge, powerful, leverage, streamline, simply, easily, please note.

Address the reader as "you". One term per concept. One product name: **Fabric Agentic Workspace**; the repository and its title are *Fabric Agentic Workspace — One-Click Setup*, written with that dash.

## What each document is for

| Document | Purpose | Rules |
|---|---|---|
| `README.md` | What the product is, what it needs, how to start | One page with a table of contents. No release history. |
| `CHANGELOG.md` | What changed between versions | The only release history. One short bullet per change. No diary, no test inventory. |
| `CLI-FUNCTIONALITIES.md` | What is available today | What it does, the real command, a minimal example. |
| `CONTRIBUTING.md` | How to contribute | Practical steps. |
| `tests/README.md` | What each suite checks and how to run it | Overview first; specialist cases in their own sections. |
| `SECURITY.md`, `CODE_OF_CONDUCT.md`, `LICENSE`, `THIRD_PARTY_NOTICES.md` | Policy and legal terms | Review only. Never edit: propose the exact text; the owner decides. |

Do not add a document or a folder without the owner's approval.

## Public and internal

Public documents say what the product supports, what it requires, how to use it and its real limits. They do not carry acceptance-run history, test diaries, or findings about one tenant, machine or account. Those belong in the internal report.

## Changelog

- Newest version first. A version without a date is not released yet; never give it one.
- Group under **Added, Changed, Fixed, Removed**. Leave out empty groups.
- One change, one bullet, one or two sentences: what changed for the user, then why if it is not obvious.
- State removals and anything that needs action on upgrade.
- Do not repeat a change under two headings or in another document.
- Earlier releases are history: correct errors, shorten wording, keep the facts.

## Review checklist

Check every document you touch, in this order:

1. **Purpose**: each section belongs in this document (table above).
2. **Concision**: nothing is said twice; no sentence is there only to sound complete.
3. **Readability**: a newcomer understands the first screen; paragraphs are short.
4. **Accuracy**: every command, option, file name, path and version matches the source. Run or grep before you write. A feature is described only when it exists and was checked.
5. **Numbers and images**: every count (agents, skills, tools, tests) matches the source, and is the same in the text and in every image. Images share one visual style; alt text says what the image shows.
6. **Navigation**: the table of contents matches the headings; every link, anchor and image path resolves.
7. **Public and internal**: no acceptance evidence in a public document.
8. **Report**: what you changed, what you propose, what you could not verify.

Sources distilled here: Microsoft Writing Style Guide, Google developer documentation style guide, Diataxis, Keep a Changelog 1.1.0.
