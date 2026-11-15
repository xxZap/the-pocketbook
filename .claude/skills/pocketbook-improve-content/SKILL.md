---
name: pocketbook-improve-content
description: Rewrite the text of an exported pocketbook notebook (a .pocketbook file) so it reads better, in the voice of a D&D character with inattentive ADHD taking notes mid-adventure, and produce a new .pocketbook file to re-import on the iPad. Use when the user runs /pocketbook-improve-content or asks to improve, clean up or rewrite the content of their pocketbook notebook or an exported page.
argument-hint: <path to the exported .pocketbook file>
---

# Improve the content of a pocketbook export

The argument is the path to a `.pocketbook` file exported from the app (one page or the whole notebook).
If it is missing, ask for it. Talk to the user in Italian.

## The file

JSON written by `PageSharing.write` (`the pocketbook/PageSharing.swift`):
`{"version": 2, "pages": [{"title", "text", "tags", "questionState", "drawing", "images", "kind", "createdAt", "updatedAt", "playedAt"}]}`.
`drawing` and `images` are base64 blobs: never load them into the conversation, never touch them.
Only `text` is rewritten. Use the helper script, which copies everything else untouched.

## Steps

1. **Extract** to the scratchpad (never next to the user's file):
   ```bash
   python3 -I "<skill dir>/pocketbook.py" extract "<file.pocketbook>" "<scratchpad>/pages.json"
   ```
   Then read `pages.json`. Pages with empty text are skipped.

2. **Rewrite** every page's `text` following the style below, and write the result to
   `<scratchpad>/rewritten.json`: the same list, same `index` and `title`, new `text`.
   For a large notebook, work through the pages in batches, but keep a single output file.

3. **Apply**, writing a new file next to the original, never over it:
   ```bash
   python3 -I "<skill dir>/pocketbook.py" apply "<file.pocketbook>" "<scratchpad>/rewritten.json" "<same folder>/<name> (riscritto).pocketbook"
   ```
   The script refuses if a title changed or a `@link` to a page in the file disappeared. Fix the text and run it again.

4. **Report** in Italian, briefly: how many pages were rewritten, the path of the new file, and 2–3 short
   before/after examples. List any title you would improve **separately, as a suggestion only**.
   Changing a title makes the import create a new page instead of updating the old one.

## Rules that keep the re-import working

- **Titles stay identical.** On import, the app matches pages by title (case- and accent-insensitive).
  Sessions are matched by title and by the day they were played.
- **`@Title` references stay exactly as written**, including spelling and capitalisation. Links resolve by title.
  Don't add new `@` links and don't turn plain mentions into links (the app offers that itself on import).
- Leave tags, questions, dates, drawings and images alone.
- **Tell the user how to re-import:** by default the app *appends* incoming text to a page that already
  exists (`PageSharing.mergedText`), which would leave old and rewritten text one after the other.
  In the import sheet, under "Pagine già nel taccuino", they must pick **Sostituisci** on the "Testo"
  control: the rewritten text then replaces the old one, keeping tags, drawings and images
  (`PageSharing.updatedText`). Pages switched off there are imported as separate copies.

## Style: a medium rewrite

The pages are a notebook: notes the character writes while living the adventure. They are not prose and
not a report written calmly at the end of the day.

- **Medium rewrite:** fix typos and unclear sentences, reorder confusing parts, cut repetitions that only
  add noise. Keep every fact, name, number and clue: rewrite, never summarise, never invent.
- **Note-taking form:** short sentences, often with no verb; bullet lists and arrows (→) where they help.
  No explanations aimed at a reader. No spoken fillers like "dicevo…" or "insomma".
- **Inattentive ADHD voice, in the writing itself, not in the narration.** Keep a light touch of it, and keep
  what the original already has:
  - the same thing noted twice because it was forgotten
  - an aside in brackets about an off-topic detail
  - `IMPORTANTE!!`, `(chiedere a X?)`, `??`
  - a thought left half-finished and picked up further down
  Use these occasionally, not on every page. The notes must still be readable.
- Same language as the original (Italian). Keep the character's slang, nicknames and in-game terms.
