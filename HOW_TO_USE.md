# VinylHarmonicMix user guide

How to build harmonically compatible DJ sets from your vinyl collection and the digital files that go with it: what every screen is for and what each option changes.

## What the app does

VinylHarmonicMix is a macOS app for DJs who own records and also keep digital copies of them. It brings in your record collection from Discogs, links each track on a record to its audio file, and then helps you put tracks in an order that sounds good together.

"Sounds good together" means two things. The keys of neighbouring tracks should be compatible, so the mix doesn't clash musically, and their tempos (BPM) should be close enough to blend. The app ranks possible next tracks by both, so you build a set by picking one track at a time from a list of good options.

You can play a set inside the app with crossfades between tracks, keep the music going after the set ends, and export everything to Rekordbox.

## Setting up

The main window stays empty until the app knows where your collection and your audio files are. Both are set in the Settings window.

### Discogs Account

#### Username

Your Discogs username, whose collection the app will import.

#### Personal Access Token

A private key that lets the app read your Discogs collection. Create one in your Discogs account under developer settings, then paste it here. The field hides what you type.

#### Save and Test Connection

**Save** stores the username and token. **Test Connection** checks that Discogs accepts them, so you know Sync will work before you run it.

### Local Audio Library

#### Choose folder…

Opens a folder picker. Select the folder that holds your digital audio files. It can be on your Mac or on a network drive (NAS).

#### Test access

Checks that the app can actually read the chosen folder. Use it after connecting a NAS or whenever file matching seems to fail.

Press <kbd>Esc</kbd> to close Settings.

> [!IMPORTANT]
> **If your library is on a NAS:** make sure the drive is mounted before running library actions. The app checks the drive thoroughly first and refuses to scan if it isn't properly reachable. This prevents an unmounted drive from looking like an empty library and wiping out your file links.

Supported audio formats: FLAC, MP3, M4A, MP4, AIFF (.aif and .aiff), WAV, AAC, OGG and Opus.

## Your first session

1.  **Fill in Settings.** Enter your Discogs username and token, press Save and Test Connection, then choose your library folder and press Test access.
2.  **Press Sync** in the top bar to import your records from Discogs.
3.  **Press MBID** to look up detailed track information on MusicBrainz.
4.  **Press AcousticBrainz** to fetch tempo, key and mood information for your tracks. Suggestions depend on this.
5.  **Press Match Audio** to link tracks to files in your library.
6.  **Fix missing links** by opening a release and using Set file on tracks without audio.
7.  **Optionally press Cues** to detect cue points, which are included when you export to Rekordbox.
8.  **Build a set.** Go to Collection, open a release, and press the green + on a track to start. Then keep picking from the suggestions.
9.  **Save the set** so you can play it later or export it.

## Finding your way around

The sidebar on the left switches between the app's four main areas.

#### Collection

Your records and the Set Builder together. The top of the screen is where you build a set; below it is your collection grid, split into **12" Maxi-Singles** and **Compilations**.

#### Sets

Your saved sets.

#### Stats

Figures about your collection and the information the app has gathered for it.

#### File Matches

A view of how your tracks are linked to audio files.

The top bar of library actions sits above whichever area you're in.

## The top bar

The row of rounded buttons ("bubbles") across the top runs library-wide jobs. If the window is narrow, scroll the row sideways to reach the rest. Hover over any bubble for a tooltip. They're listed here in the order they appear.

#### Sync

Imports your collection from Discogs, and updates it with any records you've added there since.

#### MBID

Looks up each release on MusicBrainz and stores identifiers for its individual recordings. Tracks need this information before you can link audio files to them one by one.

#### AcousticBrainz

Fetches audio information for your tracks: tempo (BPM), musical key, and mood. The harmonic suggestions are built from this data.

#### Match Audio

Scans your library folder and links audio files to the tracks on your records. When it finishes, your matches backup is updated automatically.

Greyed out when the library drive isn't available.

#### Cues

Detects cue points in tracks that are linked to audio files. These are written into the Rekordbox export.

Greyed out when the library drive isn't available.

#### Export

Saves a Rekordbox XML file. See [Export to Rekordbox](#rekordbox).

#### Backup

Saves all your manual file links to a JSON file. See [Backup and restore](#backup).

#### Restore

Loads a backup file and puts missing links back, without touching links you already have.

## Releases and files

In Collection, click any record card to open its release sheet, which shows the release details and tracklist. Press <kbd>Esc</kbd> or the close button to dismiss it.

#### Set file

Links an audio file from your drive to a specific track. Use it when Match Audio couldn't find the file or picked the wrong one. Links you make this way go into your matches backup.

Some tracks may not show this option. See [Troubleshooting](#trouble).

#### Green + (Set as Current Track in Set Builder)

Makes this track the current track in Set Builder and adds it to the end of the set you're building. The sheet closes automatically so you can carry on. This is how you choose the first track of a new set.

## Building a set

The set you're building is a draft held in memory. Nothing is stored until you save it, so if you quit first the draft is lost.

### Ways to add a track

All three do the same thing: the chosen track becomes the current track and is added to the end of the set. If Auto-play on pick is on, it also starts playing.

- The green **+** on a track in a release sheet.
- A tile in the **harmonic strip**.
- A card in the **Next in Set** panel.

### The hero area

The large area at the top shows the current track, with a spinning record illustration. When the set is empty, it prompts you to pick a first track.

#### Change

Undoes your last pick by removing the most recent track from the set, as long as it's the track currently shown.

#### Gear menu, Auto-play on pick

When on, every track you pick starts playing straight away so you can audition it. When off, picking only adds it to the set.

Remembered between launches.

### The harmonic strip

A row of tiles showing tracks that fit harmonically after the current one, within your BPM tolerance. Use it to browse options; picking a tile adds it to the set. Tiles work with the keyboard too: <kbd>Tab</kbd> to move, <kbd>Space</kbd> or <kbd>Return</kbd> to pick.

### BPM tolerance

#### BPM tolerance slider

Sets how far a track's tempo may be from the current track's and still be suggested. Lower values show only tracks that blend with little or no pitch change. Higher values show more choices that need more adjustment.

Default 5.0% BPM. Range 1% to 20%, in steps of 0.5%. Remembered between launches. The readout updates as you drag, and the suggestions refresh while you drag.

### Next in Set

Appears once the set has at least one track. It shows up to ten ranked cards for what could follow the last track in your set. Each card shows the tempo difference as a percentage, the key change (for example 8A to 9A), and grade pips rating the transition. The pips are explained in [How suggestions work](#concepts).

### Clear and Save Set

#### Clear

Empties the draft so you can start again. With two or more tracks, the app asks you to confirm and says how many tracks will go. It can't be undone.

#### Save Set

Stores the set so it appears under Sets, can be played, and is included in the Rekordbox export.

## Playback

The now playing bar shows the track that's playing, with its waveform.

### Crossfades

Between tracks, the outgoing track fades out while the next fades in over five seconds, so they overlap like a real mix. The next track loads in the background about 30 seconds ahead so the change is smooth.

The fade length is fixed at five seconds, and the bar doesn't show when a fade is happening.

### After a set ends

When a saved set finishes, the music keeps going with tracks picked from your whole library. Each one is harmonically compatible with the track before it. The app looks first for tracks within 6% of the tempo, then 10%, then 15% if it needs to. Tracks that have already played in that run aren't repeated.

## Saved sets

Choose Sets in the sidebar to see the sets you've saved. Each transition is shown with its tempo difference, key change and grade pips, so weak spots in a set are easy to find.

## Backup and restore your file links

Linking files by hand takes time on a large collection, so the app protects that work in four ways.

#### Automatic backup

Updated silently after every Match Audio run.

#### Backup

Saves every manual link to a JSON file. Keep a copy somewhere other than your music drive.

#### Restore

Loads a backup and adds any missing links. It never removes or replaces existing ones, so it's always safe to run.

#### Launch prompt

If the app opens with no manual links at all, it offers to restore from your backup.

Backups identify tracks by release, track position and file name, not by the full path on disk, so they still work if your NAS mounts at a different location.

## Export to Rekordbox

Press **Export** in the top bar and choose where to save the file in the "Export Rekordbox XML Library" window. In Rekordbox, import it through the XML option in its preferences.

The file contains:

- **Your tracks**, each with title, artist, album, genre, file type, size, length, year, label, date added, rating, BPM, musical key and the location of its audio file.
- **Cue points** for tracks where Cues has found them.
- **Your saved sets**, each as a Rekordbox playlist.

Track IDs in the file stay the same from one export to the next, so re-exporting doesn't create duplicates.

> [!WARNING]
> **Not yet tested in Rekordbox itself.** Check the imported playlists carefully before relying on them at a gig.

## How suggestions work

The app describes keys with Camelot codes. The 12 musical keys are numbered 1 to 12 around a wheel, with **A** for minor keys and **B** for major keys. Neighbouring numbers are closely related keys, so a code like 8A mixes well with 7A, 9A and 8B.

### The four transition types

Every suggestion falls into one of these groups. Within each group, tracks with the closest tempo come first. Tracks outside your BPM tolerance are never suggested.

#### Perfect match

Exactly the same key. Example: 8A to 8A.

#### Mood switch

Same number, other letter: minor to major or back. Example: 8A to 8B.

#### Energy boost

One number up, same letter. Lifts the energy. Example: 8A to 9A.

#### Energy drop

One number down, same letter. Eases the energy off. Example: 8A to 7A.

The wheel wraps around, so 12A and 1A are neighbours.

### Grade pips

The pips on each card combine key and tempo into a single rating.

| Pips | Grade    | When                                                                                                      |
|------|----------|-----------------------------------------------------------------------------------------------------------|
| ●●●  | Perfect  | Keys are compatible and tempos are within 3%                                                              |
| ●●○  | Good     | Keys are compatible and tempos are within 6%                                                              |
| ●○○  | Workable | Keys are compatible but tempos differ by more than 6%, or keys aren't compatible but tempos are within 6% |
| ○○○  | Hard cut | Neither: expect to cut rather than blend                                                                  |

## Quick reference

### Keyboard

The app has no custom menu bar commands or shortcuts beyond these:

- <kbd>Esc</kbd> closes Settings, the release sheet and the File Matches dialog.
- <kbd>Tab</kbd>, <kbd>Space</kbd> and <kbd>Return</kbd> move between and activate buttons, tiles and cards.

### Remembered settings

Two Set Builder choices are kept between launches: the **BPM tolerance** slider (default 5.0%, range 1% to 20%) and **Auto-play on pick** in the gear menu. Your Discogs details and library folder are kept in Settings.

## Accessibility

- **VoiceOver:** every button, including icon-only ones, has a spoken label.
- **Reduce Motion:** with it turned on in macOS accessibility settings, the spinning record stays still.
- **Keyboard:** tiles, cards and suggestion bubbles are real buttons you can reach with <kbd>Tab</kbd>.

## Troubleshooting

### The window is empty

Settings aren't filled in yet. Add your Discogs username and token, choose your library folder, then press Sync.

### Sync fails

Open Settings and press Test Connection. If it fails, check the username and generate a fresh token on Discogs.

### Match Audio and Cues are greyed out, or a scan refuses to run

The app can't confirm your library drive is reachable. Mount the NAS, open the folder in Finder to confirm the files are there, then press Test access in Settings. This block is deliberate and protects your file links.

### Some tracks on a release have no "Set file" option

This is a known issue. The option only appears for tracks the app has paired with MusicBrainz track data. That can fail for two reasons:

- **The release hasn't been looked up on MusicBrainz yet, or the lookup failed.** Press MBID again. This one you can fix.
- **Track numbering doesn't line up.** Discogs numbers vinyl tracks by side (A1, A2, B1), while MusicBrainz may use 1, 2, 3, and the app can't yet pair the two. A fix is being looked at; there's no workaround in the app for now.

Bonus tracks that only Discogs lists, and heading rows such as "Side A", also won't have the option.

### Few or no suggestions

- Widen the BPM tolerance slider.
- Press AcousticBrainz. Tracks without tempo and key information can't be matched.
- Make sure tracks are linked to audio files.
- Your last track may just have few partners in your collection. Press Change and try another.

### My draft set disappeared

Drafts aren't saved automatically. Press Save Set as you go.

### My manual file links are gone

Press Restore and choose your latest backup. Existing links stay as they are.

## Not in the app yet

Planned or under consideration, so don't look for them in the current version:

- Manual two-deck mixing controls
- Choosing the crossfade length
- A visual indicator in the now playing bar during a crossfade
- Exporting or printing a setlist as text or PDF
- A guided first-run setup
- A preview of what a library scan would remove before it runs

