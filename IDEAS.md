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

## FUTURE: Switch-point / cue detection (Zehren, Alunno, Bientinesi 2022, Computer Music Journal)
Paper: "Automatic Detection of Cue Points for the Emulation of DJ Mixing". ~90% usable switch points.
DATASET MATCH: their 150 tracks are 1987-2016 EDM, ~60% vinyl-digitized, 99-148 BPM — basically OUR collection. Method validated on exactly this music.

The buildable approach (EXPERT — the simpler of their two, rule-based, no ML training needed):
4 rules:
  R1 Beat gridding: switch points sit on a STRONG beat (beats 1 & 3 of 4/4).
  R2 Period alignment: switch points sit on the downbeat starting a 4-bar period.
  R3 Novelty: switch point = high novelty in rhythmic density / loudness / instrument / harmony.
  R4 Salience: only look in the INTRO (before the first sustained high-energy "salient" point).

Pipeline (5 stages):
  1. Feature extraction, aggregated to STRONG-BEAT windows (half-bar granularity):
     - bass-drum onset density (drum transcription)
     - raw signal RMS energy
     - (STAT variant adds: hi-hat density, CQT, PCP/chroma — more features, more candidates, same precision)
  2. Novelty: build self-similarity matrix per feature, convolve with Foote checkerboard kernel (8-bar kernel = 4-bar segments) -> novelty curve.
  3. Offset detection: find phase offset so candidates land on 4-bar period downbeats; maximize summed weighted novelty across strong beats 4 bars apart (weight = RMS average).
  4. DJ search space: from track start until first "salience" point (bass drum >= 2 onsets/bar AND raw energy >= median-delta, sustained). Only search here.
  5. Classification (EXPERT): peak-pick novelty within search space; return global max of bass-drum-novelty and raw-energy-novelty -> ~2 candidate switch points/track.

Essentia fit: we already have beat tracking (RhythmExtractor2013 gives beat positions for the grid) + onset/energy. Need: strong-beat/downbeat estimation (paper uses Böck et al. 2016 RNN beat+downbeat tracker — madmom), bass-drum transcription (paper uses Vogl et al. drum transcription), Foote checkerboard novelty (small numpy). Could do a simpler v1: RMS-energy novelty + beat grid only (drop drum transcription) — lower precision but far fewer dependencies.
Storage: switch points (sec, snapped to beat) on LocalFileEntity; show as markers on the Mix waveform; click to seek/set mix-in.
Build AFTER core mixing tool is in real use. v1 could be energy-novelty-only to avoid madmom/drum-transcription deps.

## Stage 2.5 — Compatibility group filter (parked)
Add a filter control (All / Perfect match / Energy boost / Energy drop / Mood switch) above the
compatible-tracks list in the set builder (and Mix tab — they share HarmonicCompatibility).
"All" = current continuous grouped scroll-through (default, keep as-is). Selecting a group narrows
to just that group. Best of both: browse-everything OR focus-one group.

## Stage 2.6 (REVISED) — Transition bubble between Deck A and Deck B
A dedicated info bubble BETWEEN the two decks in the builder, evaluating ONLY the current A→B
transition the user is auditioning (before "Add to Set"):
- BPM difference (e.g. "+2 BPM", and/or % difference)
- Camelot relationship (e.g. "8A → 8B")
- Move type (perfect match / energy boost / energy drop / mood switch / hard cut)
- BLEND GRADE — quality score for the specific transition:
  * Perfect (green): same/adjacent Camelot AND BPM within ~3%
  * Good (blue): harmonic relationship AND BPM within ~6%
  * Workable (orange): harmonic but larger BPM gap, OR close BPM but off-key
  * Hard cut (grey): neither — a deliberate break (not "bad", ties to 2.7)
Reuses transitionInfo() from Stage 3; adds a grading function. Sits visually between Deck A & Deck B.

## FUTURE (major) — Live two-deck crossfader mixer in Mix mode
Add a crossfader UNDER the transition bubble to actually HEAR tracks A and B mixed live (not just
audition one at a time). Requirements / why it's a big build:
- DUAL simultaneous playback — both decks play at once. Current AudioPlaybackController is
  single-player/one-at-a-time; needs rearchitecting (likely AVAudioEngine with two player nodes).
- Crossfader — equal-power gain blend between the two decks' volumes.
- BPM SYNC / beatmatching — time-stretch one track to match the other's tempo without pitch change
  (AVAudioUnitTimePitch on AVAudioEngine). Real DSP, substantial.
- Beat/phase alignment — downbeats must line up, which DEPENDS ON cue points / beat grids.
DEPENDENCY: requires cue-point detection (roadmap #3) done first — need beat positions to beatmatch/align.
MILESTONE PLACEMENT: AFTER #3 (cue points). This is its own major milestone (call it #5 / "Live Mixer"),
built on top of cue points + an AVAudioEngine playback rebuild. NOT a polish item — a flagship feature.
