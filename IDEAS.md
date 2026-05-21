# Future ideas / parking lot

Things to revisit later, in no particular order.

## [Date: 2026-05-20] — Alternative direction for grid card harmonic display
Idea preserved from chat. Will think through more before implementing. Default plan still proceeds: A → C → B.

## Deferred / Next

## Incremental indexing (next, after duration/version matching is verified)

Currently the library indexing is a FULL re-scan every run — it walks all 41,385 files and re-reads durations each time. When the user adds new music and re-runs matching, it reprocesses the entire library instead of just the new files.

Make indexing incremental:
- Build a set of already-indexed file paths from existing LocalFileEntity rows
- Walk the library: NEW path → index it (read duration etc.); already-indexed path → skip
- Detect deletions: indexed path no longer on disk → remove that LocalFileEntity row
- (Optional) detect in-place edits via mod-date/size
- Path-based: a renamed/moved file = delete old + add new (re-indexes it, correct behavior)

Keep a separate "Rebuild index from scratch" button in Settings as an escape hatch (full wipe + re-index for corruption/clean-slate cases). Default scan = incremental; manual rebuild = full.

Goal: adding 50 new files takes seconds (index 50), not minutes (re-read 41,385).

Note: the first run with durations still needs a full pass (no file has durations yet) — incremental kicks in afterward.
