# VinylHarmonicMix — Session Handoff

## Repo / Environment
- Path: your local clone of the repo (commands below run from its root)
- Branch: `v2-development` (remote: `github.com/ghailoo/Vinyl-Harmonic-Mix`)
- Build: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -scheme VinylHarmonicMix -configuration Debug -destination 'platform=macOS' build`
- Mac Studio + Claude Code in Terminal + Xcode
- Last updated: 2026-09-28

## First thing in a new session
```bash
git status && git log --oneline -10
```
As of 2026-09-28: `origin/v2-development` is at `3c57690` (tag `v2.1-smooth`), and this handoff commit sits on top of it. The only intentionally uncommitted change is `project.pbxproj`, which holds Xcode's "recommended settings" upgrade (`LastUpgradeCheck 2700`, `DEAD_CODE_STRIPPING`, `STRING_CATALOG_GENERATE_SYMBOLS`). Never stage it together with feature work. Commit it on its own or discard it.

## Rollback tags (newest first)
| Tag | Commit | Marks |
|---|---|---|
| `v2.1-smooth` | `3c57690` | Known-good: perf fixes, multi-folder, Sets undo + release-sheet polish. **Current safe point.** |
| `v2.1-pre-perf` | `c74f388` | Before the Sep 28 query-performance work (multi-folder done, PerfLog persisted) |
| `v2.1-pre-multifolder` | `a51d3ab` | Before multiple library folders (Sep 27 UI audit A–E done) |
| `v2.1-pre-discogs-tracks` | `caef80d` | Before Discogs became the track source / AcousticBrainz was retired |
| `v2.1-pre-stats` | `327db08` | File Matches redesign done, before the Stats redesign |
| `v1.0-beta` | `9295d9e` | First DMG sent to the DJ tester (June 4) |

Older `milestone-*` and `mix-*` tags are May/June history and aren't relevant for rollback anymore.

## How the app works now

### Track lists: Discogs is the source of truth, MusicBrainz is optional
- Any release with **no `TrackEntity`s** gets tracks synthesized from its cached Discogs tracklist by `RecordingsScanCoordinator.synthesizeTracksForOrphanRelease`. This happens whether or not the release has an MBID.
  - Surrogate IDs are `discogs:{releaseId}:{position}`.
  - Synthesized tracks carry a duration and the per-track artist credit (for compilations), and heading rows are skipped.
  - The function is guarded by `tracks.isEmpty`, so it's idempotent.
- **Call sites for synthesis:**
  - The launch backfill, `backfillOrphanReleaseTracks`.
  - The recordings scan, for releases without an MBID.
  - `startForSingle` when the release has no MBID.
  - Right after release details are cached, in both `CollectionViewModel.synthesizeTracksIfNeeded` and `DetailCacheCoordinator`.
  - The **"Create tracks from tracklist"** fallback button in the release sheet.
- **MusicBrainz is optional enrichment.** Releases with an MBID can still fetch MB recordings through `processItems`. Find IDs still runs a multi-strategy MBID match.
- `RecordingsScanCoordinatorTests` has 10 synthesis tests.
- ⛔ **Hard constraint:** there are about 187 existing manual file matches keyed on `TrackEntity.trackMBID`. Never modify them or re-key them.
- ⚠️ **Open hazard (not fixed):** `RecordingsScanCoordinator.processItems` deletes **all** of a release's existing tracks before inserting MusicBrainz ones. File links live on `TrackEntity` (`primaryLocalFilePath`, `fileMatchState`), so any links on those tracks are lost too. A release that already has Discogs-synthesized tracks with file links can reach this path in three ways:
  - **Manual release MBID entry in the release sheet:** `setMBIDManuallyAndEnrich` → `startForSingle`.
  - **The Stats-page recordings scan:** releases with an MBID whose `recordingsScanState` is still unscanned or failed.
  - **Sync on newly imported releases:** since `7ca0804`, the details cache synthesizes tracks early, so they can exist before Sync's recordings step reaches `startForSingle`.

  The fix is a guard so `processItems` only replaces tracks that aren't `discogs:`-keyed or have no links. Needs a decision.

### BPM/key: local Essentia analysis only
- AcousticBrainz and the "Web BPM/Key" button are retired from all automated flows. Sync no longer has an audio-features step. **`LocalAnalysisCoordinator` (Essentia) is the only automatic BPM/key source.** The Stats page shows local analysis as the primary section and labels AcousticBrainz data as historical.
- **Still reachable manually:** three release-sheet actions still call `AudioFeaturesScanCoordinator.startForSingle`, which queries AcousticBrainz:
  - "Fetch recordings & audio features"
  - Setting a per-track recording MBID
  - Manual release-MBID fetch

  `AcousticBrainzClient.swift` still exists. Remove these calls if you want AcousticBrainz fully gone.

### Toolbar (`UnifiedTopBar`)
Order: **Update All · Find IDs · Link Files · Detect BPM/Key · Find Cues | Rekordbox · Back Up · Restore**.
- Update All = Sync (Discogs import plus the per-release steps).
- Find IDs = MusicBrainz ID scan.
- Link Files = Match Audio.
- Detect BPM/Key = local Essentia analysis.
- Back Up / Restore = the manual matches JSON backup.
- The Web BPM/Key button was removed.
- Bubbles use `ViewThatFits` and have liveness/stall detection.

### File Matches
- Layout: a master-detail `Table` in an `HSplitView` with a persisted divider, plus keyboard review (`8219825`, `9799d0a`).
- Duplicate best-guess files are marked and explained.
- The mix check is folded into the Discogs-track column. There are filter chips, batch actions, and an empty detail state that points to the keyboard shortcuts.
- **Real scores on rehydrate** (`545e0ff`): review candidates are re-scored rather than shown with placeholder scores. Since `892019f`, rehydration fetches only the candidate file paths with `propertiesToFetch` and scores them off the main thread. It no longer loads all ~44k `LocalFileEntity` rows.

### Multiple library folders (Sep 27, `3d8acdd..0c99ff7`)
- Settings holds an ordered folder list. Each folder has a kind: albums / compilations / singles / other.
  - The legacy single-bookmark setup is migrated.
  - Overlapping folders are rejected.
  - Removing a folder keeps its matches.
  - Each folder has its own access test.
- **Availability:** `DriveMonitor` tracks it per folder with remount detection. `DriveUnavailableBanner` names the missing folders.
- **Orphan sweep:** indexing and the sweep run per folder, via `LocalFileEntity.libraryFolderID`. **The sweep only touches folders that are currently reachable, so rows and matches in an unreachable folder survive untouched.** This is the successor to the Phase 0 NAS safety guard (`DriveMonitor.verifyAccessible()`).
- The compilations folder kind gives a ranking boost in match scoring.
- Analysis skips unreachable folders and reports it.
- Tests: `LibraryFoldersTests`.

### Reset All Data
- Located in Settings and implemented in `Services/ResetService.swift`.
- **Before deleting anything**, it writes `~/Library/Application Support/VinylHarmonicMix/Backups/reset-<ISO8601 timestamp>/`, containing a copy of the SwiftData store plus `matches-backup.json`.
- It then deletes every entity and clears UserDefaults. The Discogs/AcoustID credentials and library-folder selection are kept.
- If the reset fails after the backup, it reports that the data is intact. The batch-delete cascade/nullify bug is fixed (`609ae9c`).

### Sets and the release sheet (Sep 28)
- **Sets page:** a plain `HSplitView` (set list | contents), not a nested `NavigationSplitView`. The list width is persisted and "New Set" sits in a header row.
- **Undo on the Sets page:**
  - **Deleting a set** has no confirmation dialog. It's undoable with ⌘Z, and a 5-second "deleted — Undo" message also offers Undo.
  - **Removing a track** is undoable with ⌘Z and comes back at its original position.
  - The helpers are in `Models/SetlistEntity.swift` (`SetlistUndo`, `DeletedSet`).
  - Scope: the window's `UndoManager`. It survives hide/deactivate and sidebar switches, but not closing the window or quitting.
  - Renames, reordering and adding tracks are not undoable.
- **Release detail sheet:**
  - A labelled Done button with Escape replaces the floating close icon.
  - Manual release and recording MBID entry are behind collapsed `DisclosureGroup`s.
  - The star rating is interactive and stored in `CollectionItemEntity.rating`. It's local only: the Rekordbox export uses it, it isn't sent back to Discogs, and Sync only seeds it on import.
  - Carousel arrows sit on circular material, with clickable page dots.
- **Runtime:** none of the Sep 28 work has been verified at runtime by the user yet.

### Also shipped since v1.0-beta
- **June:**
  - NAS safety guard.
  - Compilations grid sectioning.
  - Background player init, 30s pre-load and 5s linear crossfade.
  - Smart whole-library auto-advance (3-pass BPM relaxation, anti-repeat).
  - Manual matches backup: export/import/auto-update. It's keyed on `(instanceId, trackPosition, fileName)`, and restore only adds.
  - BPM-aware harmonic suggestions panel, the Auto-play-on-pick toggle, and auto-dismissing the release sheet on '+' (all committed).
- **Sep 16–17:**
  - UI/UX audit phases 1–5.
  - README and `docs/HOW_TO_USE.md`.
  - Stats page redesign with one shared progress bar.
  - MBID pipeline: URL lookup → search fallback → local verification, plus needs-review UI.
- **Sep 21:** `LocalAnalysisCoordinator` write-back saves are batched.
- **Sep 27 UI audit A–E:**
  - One semantic type scale.
  - Light/dark color tokens.
  - Reduce Motion honoured everywhere.
  - 28×28 minimum hit targets.

## Performance status
- **Fixed on Sep 28:**
  - **Stats:** five unbounded `@Query`s replaced by the off-main `CollectionStats` snapshot.
  - **Set Builder:** four replaced by `SetBuilderLookups`.
  - **File Matches rehydration:** candidate-only fetch, done off the main thread.
  - All three are stored on `CollectionViewModel` and refreshed after `ModelContext.didSave` with a 500ms debounce.
- **Not measured yet.** No before/after ms numbers exist.
  - Debug builds of `v2.1-pre-perf` and `v2-development` may still be in the Claude scratchpad (`dd-pre`/`dd-post`), but that is temporary.
  - To measure: run each build, click Collection → Stats → File Matches ×2, quit, then:
    `log show --last 30m --style compact --predicate 'subsystem == "com.vinylharmonicmix.perf"'`
- **Known remaining costs (unmeasured, candidates if anything still feels slow):**
  - `FileMatchesView`'s three filtered `@Query`s were deliberately left alone.
  - `CollectionDetailView.loadFeatureEntities` fetches **every** `RecordingFeaturesEntity` each time a sheet opens, then filters in memory.
  - `backfillOrphanReleaseTracks` fetches all releases on every launch.
  - Stats/Set Builder snapshots recompute in full after each debounced save.
- **`PerfLog`** (`Services/PerfLog.swift`) is still temporary instrumentation. Strip it once numbers confirm the fixes.

## Open investigation: "Set file" missing on some tracks
**Status: only partly closed by the Discogs track-source change.**
- **Cause:** the "Set file" row only renders when a `TrackEntity` matches the Discogs tracklist position. `normalizePosition` only strips spaces and uppercases.
- **Diagnosed root cause:** Discogs positions (`A1`, `B2`) don't match MusicBrainz positions (`1`, `2`) on vinyl releases.
- **Closed for:** releases whose tracks were synthesized from Discogs. Their positions come from Discogs, so they always match. `7ca0804` also fixed "no Set file buttons until relaunch" on newly cached releases.
  - Runtime check still pending: open a release that had no tracks and confirm "Set file" appears without a relaunch.
- **Still open for:** releases whose tracks came from MusicBrainz, which still have MB positions. Synthesis never touches a release that already has tracks.
  - The recording-MBID caption has an index-based fallback, but `trackEntityByPos`, which drives "Set file", does not.
  - Any future MB fetch replaces Discogs tracks with MB-positioned ones (see the hazard above).
- **Next step:** find one affected MB-track release and compare its `TrackEntity.position` values with the Discogs positions. Then either use the index fallback for `trackEntityByPos` or reconcile positions when MB tracks are stored. Don't re-key `trackMBID`.

## Pending queue
- 🔴 **Decide on the `processItems` track-replacement hazard** (above) before anyone runs a recordings scan or manual MBID entry on releases with linked files.
- 🟡 **Runtime-verify the Sep 28 work:** Sets undo, the release sheet, the perf snapshots. Then capture before/after perf numbers.
- 🟡 **Decide whether to fully remove AcousticBrainz** from the release sheet's manual actions.
- 🟡 **Remove temporary `PerfLog` instrumentation** after measuring.
- 🟡 **Optional audit item 13:** `UnifiedTopBar.bubbleColor(for:)` uses arbitrary hues. The suggestion is monochrome bubbles, with color only for state. Needs a yes/no.
- 🟡 **Cut the v2-beta DMG** and send it to the tester. There has been no feedback on v1.0-beta.
- 🟡 **Test Rekordbox XML import in real Rekordbox.** This has never been verified.
- 🟡 **Set export to text/PDF** (~1–2 hrs).
- 🟡 **Phase 0 dry-run mode**, **onboarding/first-run**, and **empty states** in the remaining views.
- 🟢 **Crossfade duration setting** (3/5/8s), **NowPlayingBar crossfade indicator**, **stale-load print cleanup**.

## Key architecture notes
- **Deck system (`deckA`/`deckB`) is for manual mixing only.** Crossfade automation uses the standalone `crossfadeOutgoingPlayer` + `player` pair.
- **A single 25Hz timer** in `startTimer()` drives currentTime, preload and crossfade. Don't add more timers.
- **Race protection:** capture `intendedPath` before `Task.detached`. Re-check `currentFilePath == intendedPath` (or `predictedNextFilePath()`) inside `MainActor.run` before applying anything.
- **Off-main snapshot pattern (Sep 28):**
  - Capture inputs on the main actor.
  - Compute in `Task.detached` using a fresh `ModelContext(container)`.
  - Apply the results on the main actor.
- **Project concurrency settings:**
  - `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so types used off-main must be marked `nonisolated`. This already applies to the Discogs DTOs, `MixTrackPool`, `MixCoverArt` and `CollectionStats`.
  - `MemberImportVisibility` is on, so Combine operators need an explicit `import Combine`.
- **HSplitView divider persistence:** a background `GeometryReader` writes the pane width to `@AppStorage`, because HSplitView has no binding. Used in File Matches and Sets.
- **`MixTrack`:** equality is id-based, and the id derives from `filePath`.
- **`HarmonicCompatibility.compatibleGroups(for:in:bpmTolerance:)`** is the core ranking engine, sorted by BPM closeness within each `HarmonicGroup`. Used by:
  - Auto-advance
  - The suggestions panel
  - The harmonic strip
  - The BPM slider
- **`TransitionBubbleView(anchor:candidate:)`** is a reusable transition widget.
- **`InteractiveTileButtonStyle`** (hover/press for surfaces that draw their own background) and **`LibraryBubbleButtonStyle`** (top-bar capsules) are both in `UnifiedTopBar.swift`.
- **`workingSetTracks`** is in-memory `@State` in SetBuilderView until "Save Set". Clearing it asks for confirmation when it has 2+ tracks.
- **Xcode project uses `PBXFileSystemSynchronizedRootGroup`:** adding or deleting a `.swift` file on disk is enough, no `.pbxproj` edits needed.
- ⚠️ **Wrong-terminal check:** confirm `pwd` and `git remote -v` point at VinylHarmonicMix before trusting branch/commit output.

## Working style notes (carry forward)
- Discovery-first prompts before implementation consistently pay off, because they surface existing infrastructure before it gets duplicated.
- **The user tests at runtime themselves.** Claude Code should not launch the app or automate UI via screenshots/AppleScript. On Sep 28 an attempt started a second app instance against the same store while Xcode's instance was running. Don't.
- Commit messages are long-form and technical, written for future context.
- Lock every spec with explicit multiple-choice questions before an implementation prompt.
- **Multi-phase work:** build green after every phase and commit per phase. When one file has hunks from two phases, `git add -p` splits them. Never stage the pbxproj settings change or this handoff with feature work unless asked.
- SourceKit single-file diagnostics ("Cannot find type 'X' in scope") are noise. Trust `xcodebuild`.
