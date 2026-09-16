# VinylHarmonicMix — Session Handoff

## Repo / Environment
- Path: `/Users/ghailen/Desktop/MacOS Project/VinylHarmonicMix`
- Branch: `v2-development`
- Build: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -scheme VinylHarmonicMix -configuration Debug -destination 'platform=macOS' build`
- Mac Studio + Claude Code in Terminal + Xcode

## ⚠️ FIRST THING TO DO IN NEW SESSION
**Verify state before anything else:**
```bash
cd "/Users/ghailen/Desktop/MacOS Project/VinylHarmonicMix" && git status && git log --oneline -8
```
Working tree is clean. Local `v2-development` is **5 commits ahead of `origin/v2-development`, not yet pushed** (the UI/UX audit fixes below). Push when ready:
```bash
git push origin v2-development
```

## Commits shipped this session — UI/UX audit fix (5 phases, most recent first)
```
84069c2  Phase 5: throttle BPM slider updates, fade floating-chrome dividers, tighten hero title tracking
d08b1a1  Phase 4: confirm before clearing a working set with 2+ tracks
9e62b6c  Phase 3: add press/hover feedback to tap surfaces and switch to spring animations
a0b1ec8  Phase 2: add VoiceOver labels app-wide and honor Reduce Motion
c998182  Phase 1: fix layout defects in top bar, detail column, and set builder chrome
```
These closed out a 12-item UI/UX audit (layout, accessibility, interaction feedback, data-safety, polish). Each phase was built green before committing; app was never launched/driven by Claude Code during this work — all runtime verification was done by the user.

### What each phase changed
1. **Layout** — `UnifiedTopBar` bubble row scrolls horizontally instead of wrapping text; `ContentView` detail column has a `minWidth(760)`; `SetBuilderView` hero/harmonic-strip chrome is now `GeometryReader`-driven min/max height instead of fixed 320pt/280pt; hero empty state matches the grid's empty-state style.
2. **Accessibility** — `.accessibilityLabel()` added to all ~40 `.help()` sites plus 6 previously-unlabeled icon-only buttons; `SpinningRecordView` now honors `@Environment(\.accessibilityReduceMotion)` (freezes instead of spinning).
3. **Interaction feedback** — new shared `InteractiveTileButtonStyle` (in `UnifiedTopBar.swift`, adapted from `LibraryBubbleButtonStyle`) applied to grid cards, harmonic-strip tiles (converted from `.onTapGesture` to a real keyboard-focusable `Button`), and suggestion bubbles; all 13 fixed-duration `.easeInOut`/`.easeOut` curves across `Views/` replaced with `.snappy`/`.smooth` springs. `TrackWaveformView`'s deliberate `withAnimation(.none)` left untouched.
4. **Data safety** — `SetBuilderView`'s "Clear" button now shows a `.confirmationDialog` naming the track count, gated on 2+ tracks in the draft.
5. **Polish** — BPM tolerance slider throttles live re-filtering to ~100ms during drag (exact commit on release, "%" text stays fully live); hard divider lines under floating `.regularMaterial` chrome (`floatingToolbar`, `UnifiedTopBar`) replaced with an 8pt gradient fade; hero title gets `.tracking(-0.4)`.

### Not implemented — needs a decision
**Optional item 13 from the audit**: `UnifiedTopBar.bubbleColor(for:)` assigns 8 arbitrary hues (Sync=blue, MBID=purple, etc.) with no semantic meaning. Audit suggested making the bubble row monochrome and reserving color for state only (running/disabled/destructive). Flagged to the user at the end of the session, not yet decided — do this first if picking the thread back up, since it's a quick, isolated change to `bubbleColor(for:)` and the two capsule-fill/stroke lines in `LibraryBubbleButtonStyle`.

## What's fully shipped and working (verified at runtime, prior sessions)
1. **NAS safety guard (Phase 0)** — `DriveMonitor.verifyAccessible()` deep-checks the mount before any destructive scan; prevents repeat of an earlier mass-delete incident.
2. **Compilations grid sectioning** — SetBuilder collection grid split into "12\" Maxi-Singles" + "Compilations" sections.
3. **Track-transition rework (3 phases)** — background AVAudioPlayer init (no more beachballs), 30s pre-load, 5s linear crossfade with real audible overlap. Standalone crossfade pair, NOT the manual deckA/deckB system.
4. **Smart whole-library auto-advance** — when a saved set ends, playback continues with harmonically compatible tracks from the whole library (3-pass BPM relaxation ladder: ±6%/±10%/±15%, always harmonic). Anti-repeat via `smartPlayedFilePaths`.
5. **Manual Matches Backup (3 phases)** — Export/Import/Auto-update. JSON backup keyed on `(instanceId, trackPosition, fileName)` — NOT absolute path — for portability across NAS re-mounts. Additive-only restore policy. "Backup"/"Restore" toolbar bubbles in `UnifiedTopBar`. Launch-detection prompt fires only if confident count == 0. Auto-updates silently after every Match Audio completion.
6. **BPM-aware harmonic suggestions panel** — "Next in Set" panel in SetBuilder, appears when draft is non-empty, up to 10 ranked `TransitionBubbleView` cards anchored to `workingSetTracks.last`.
7. **Change button fix** — hero's "undo" button correctly pops the last entry from `workingSetTracks`, guarded on `workingSetTracks.last == currentTrack`.
8. **Auto-play-on-pick toggle** — sticky `@AppStorage("setBuilderAutoPlayOnPick")` in the SetBuilder hero gear menu.
9. **Auto-dismiss release sheet on '+'** — closes the release sheet automatically after adding a track via `dismiss()`.
10. **UI/UX audit fixes (this session)** — see above.

## 🔍 Open investigation — NOT yet fixed
**User question:** why do some tracks in a release's CollectionDetailView sheet lack the "Set file" option to manually link a local digital file?

**Diagnosis complete** (discovery only, no fix applied):
- File: `VinylHarmonicMix/Views/CollectionDetailView.swift`
- `perTrackFileLinkRow` only renders — and therefore "Set file" only appears — when a `TrackEntity` exists for that tracklist position (`trackEntityByPos`).
- `trackEntityByPos` matches by `normalizePosition(track.position) == normalizePosition(te.position)` (strips spaces + uppercases only).
- **Most likely root cause:** position-string mismatch between Discogs tracklist positions (e.g. `"A1"`, `"B2"`) and MusicBrainz-derived `TrackEntity.position` values (e.g. `"1"`, `"2"`) on vinyl releases. `normalizePosition` doesn't reconcile letter-prefixed vs numeric positions, so tracks whose formats don't match silently get no `TrackEntity` → no "Set file" option.
- Other possible causes noted but less likely: missing MusicBrainz data entirely (MBID scan pending/failed), partial tracklist coverage (Discogs has bonus tracks MB doesn't), non-music heading rows in the tracklist.
- **Recommended next step:** pick a specific release where some tracks show "Set file" and others don't, inspect the actual `TrackEntity.position` values in SwiftData vs the Discogs tracklist positions to confirm the A1/B1-vs-1/2/3 hypothesis, then extend `normalizePosition` to reconcile the two formats (or add an index-based fallback).
- **This needs a decision from the user on whether/how to fix before implementation** — not specced yet.

## Pending queue (not started, carried from various points)
- 🟡 **Decide on optional audit item 13** — monochrome `UnifiedTopBar` bubbles (see above) — quick, isolated, just needs a yes/no.
- 🟡 **Push the 5 UI/UX audit commits** to `origin/v2-development` — verified locally, just not pushed yet.
- 🟡 **Set-file position mismatch fix** (see investigation above)
- 🟡 **Cut v2-beta DMG and send to tester** — beta tester (user's own email) had given zero feedback on the earlier v1.0-beta DMG as of last check.
- 🟡 **Test Rekordbox XML import in actual Rekordbox** — headline feature shipped a while ago, still never verified in real Rekordbox.
- 🟡 **Set export to text/PDF** — share/print setlists outside the app (~1-2 hrs).
- 🟢 **Crossfade duration setting** — currently hardcoded 5s, could be user-adjustable 3s/5s/8s (~20-30 min).
- 🟢 **NowPlayingBar crossfade visual indicator** — no visual signal during the 5s fade currently (~20-30 min).
- 🟢 **Stale-load print cleanup** — `[PLAY] Stale load...` / `[PRELOAD] Stale...` console noise, dev-only value (~5 min).
- 🟡 **Phase 0 dry-run mode** — preview which rows WOULD be deleted before the safety guard actually blocks, companion to the NAS safety guard.
- 🟡 **Onboarding/first-run experience** — currently blank until Discogs API key + library folder are configured.
- 🟡 **Empty states across views** — CollectionStats, MBIDScanResultsView, etc. when zero data (SetBuilder hero + grid empty states were fixed this session; others weren't in scope).

## Key architecture notes for continuity
- **Deck system (`deckA`/`deckB`) is for MANUAL mixing only** — crossfade automation deliberately uses a separate standalone pair (`crossfadeOutgoingPlayer` + the regular `player`), not the deck system.
- **Timer runs at 25Hz** in `startTimer()` — drives currentTime, preload triggering, crossfade triggering/ticking. Single timer, no separate ones added.
- **Race-protection pattern used throughout**: capture `intendedPath` before an async `Task.detached`, re-check `currentFilePath == intendedPath` (or `predictedNextFilePath() == intendedPath`) inside `MainActor.run` before applying state.
- **`MixTrack` is `Equatable`/`Identifiable`, comparison is id-based** (`static func == { lhs.id == rhs.id }`), id derives from filePath.
- **`HarmonicCompatibility.compatibleGroups(for:in:bpmTolerance:)`** is the core ranking engine — already sorted by BPM closeness within each `HarmonicGroup` (`.perfectMatch`, `.moodSwitch`, `.energyBoost`, `.energyDrop`). Used by smart auto-advance, the suggestions panel, the exploratory harmonic strip, and (as of this session) the throttled BPM-slider live re-filter.
- **`TransitionBubbleView(anchor:candidate:)`** — reusable rich display widget (BPM%, key transition, grade pips), used in the suggestions panel and SetLibraryView.
- **`workingSetTracks: [MixTrack]`** is plain in-memory `@State` in SetBuilderView — no persistence until "Save Set" is tapped. Fully reactive. Now guarded by a confirmation dialog before being cleared with 2+ tracks.
- **`InteractiveTileButtonStyle`** (new, `UnifiedTopBar.swift`) — shape-agnostic hover-brighten + press-scale `ButtonStyle` for surfaces that draw their own background (grid cards, strip tiles, suggestion bubbles). Sibling to `LibraryBubbleButtonStyle`, which stays capsule-specific for the top-bar bubbles.
- **Xcode project uses `PBXFileSystemSynchronizedRootGroup`** (Xcode 15 feature) — deleting a `.swift` file from disk is sufficient, no `.pbxproj` editing needed.
- ⚠️ **Watch for wrong-terminal mistakes**: confirm `pwd` and `git remote -v` match VinylHarmonicMix before trusting Claude Code's branch/commit output blindly — a different-repo task got pasted into this conversation once before.

## Working style notes (carry forward)
- Discovery-first prompts before implementation consistently pay off — surfaces existing infrastructure before duplicating it.
- User tests changes at runtime themselves; Claude Code should NOT attempt to automate UI testing via screenshots/AppleScript (unreliable, past attempts opened wrong panels/file pickers and wasted time).
- Commit messages are long-form and technical — written for future-Claude/future-user context, not just changelog brevity.
- Lock every spec via explicit multiple-choice questions before sending an implementation prompt — this has caught several ambiguities (e.g., crossfade fade duration, restore threshold, panel placement) before they became wasted implementation effort.
- For multi-phase task lists: build green after every phase before moving on, and commit per phase rather than bundling — makes it possible to `git reset --soft` or revert a single phase without touching the others. When a single file has hunks belonging to two different phases, `git add -p` (feeding y/n per hunk) splits it cleanly instead of hand-editing the diff.
- SourceKit single-file diagnostics (e.g. "Cannot find type 'X' in scope" for types that are clearly defined elsewhere in the module) are noise from checking a file in isolation without full project context — trust the authoritative `xcodebuild` result over these, don't chase them.
