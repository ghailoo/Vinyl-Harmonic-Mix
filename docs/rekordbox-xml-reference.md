# Rekordbox XML Library Format Reference

> Phase 0 discovery document — v2-development, June 2026.
> Research basis for the Phase 1 Rekordbox XML exporter implementation.

---

## Authoritative Sources

| Source | URL | Authority |
|--------|-----|-----------|
| Pioneer/AlphaTheta Official XML Format Spec PDF | https://cdn.rekordbox.com/files/20200410160904/xml_format_list.pdf | Canonical |
| pyrekordbox XML Database Format Docs | https://pyrekordbox.readthedocs.io/en/latest/formats/xml.html | High |
| Mixxx Wiki: Rekordbox Cue Storage Format | https://github.com/mixxxdj/mixxx/wiki/Rekordbox-Cue-Storage-Format | High |
| DJ Tools: Get to Know Your Rekordbox Collection | https://a-rich.github.io/DJ-Tools-dev-docs/conceptual_guides/rekordbox_collection/ | Medium |
| AlphaTheta: Key Display Format Support Article | https://support.alphatheta.com/en-US/articles/8943219092761 | High |
| Lexicon DJ Manual: Sync to Rekordbox XML | https://www.lexicondj.com/manual/sync-rekordbox-xml | Medium |
| MIXO: Rekordbox XML Import Bug | https://www.mixo.dj/guides/rekordbox-xml-import-bug | Medium |
| pyrekordbox Discussion #113 (cue points) | https://github.com/dylanljones/pyrekordbox/discussions/113 | Medium |
| Pioneer DJ Community Forum | https://community.pioneerdj.com | Low-Medium |
| Real-world exported XML (ThomasKoot/rekordbox) | https://github.com/ThomasKoot/rekordbox/blob/main/rekordbox_library.xml | Corroboration |

---

## File Structure

### XML declaration

```xml
<?xml version="1.0" encoding="UTF-8"?>
```

No BOM. UTF-8 declared in the prolog is sufficient and correct.

### Root element

```xml
<DJ_PLAYLISTS Version="1.0.0">
```

`Version="1.0.0"` is the **format version** — it has been `1.0.0` across all known rekordbox releases. Do not change it.

### Top-level structure

```xml
<?xml version="1.0" encoding="UTF-8"?>
<DJ_PLAYLISTS Version="1.0.0">
  <PRODUCT Name="VinylHarmonicMix" Version="2.1" Company=""/>
  <COLLECTION Entries="3">
    <TRACK ...>...</TRACK>
    <TRACK ...>...</TRACK>
    <TRACK ...>...</TRACK>
  </COLLECTION>
  <PLAYLISTS>
    <NODE Type="0" Name="ROOT" Count="1">
      <NODE Type="1" Name="My Set" KeyType="0" Entries="3">
        <TRACK Key="1001"/>
        <TRACK Key="1002"/>
        <TRACK Key="1003"/>
      </NODE>
    </NODE>
  </PLAYLISTS>
</DJ_PLAYLISTS>
```

The three direct children must appear in this order: `PRODUCT`, `COLLECTION`, `PLAYLISTS`.

**`PRODUCT` element:** Name/Version/Company are informational only. Set `Name` to "VinylHarmonicMix" and Version to the app version string. rekordbox ignores these for import logic.

**`COLLECTION Entries`:** Should match the count of child `TRACK` elements. rekordbox reads tracks regardless of whether `Entries` is accurate, but keep it correct.

---

## TRACK Element

Every exportable track lives as a `<TRACK>` element inside `<COLLECTION>`. Child elements (`<TEMPO>`, `<POSITION_MARK>`) are nested inside the TRACK body.

### Full attribute table

| Attribute | Type | Req'd | Example | Notes |
|-----------|------|-------|---------|-------|
| `TrackID` | integer string | **Yes** | `"1001"` | Unique integer within this XML file. Used as `Key` in playlist `TRACK` references. Auto-assign sequentially. |
| `Name` | UTF-8 string | **Yes** | `"Blue Monday"` | Track title |
| `Artist` | UTF-8 string | Optional | `"New Order"` | |
| `Composer` | UTF-8 string | Optional | `"Bernard Sumner"` | |
| `Album` | UTF-8 string | Optional | `"Power, Corruption & Lies"` | XML-escape the `&` as `&amp;` |
| `Grouping` | UTF-8 string | Optional | `"Electronic"` | Maps to ID3 Grouping tag. Note: the attribute is `Grouping` (text), NOT `GroupingID`. |
| `Genre` | UTF-8 string | Optional | `"Electronic"` | |
| `Kind` | UTF-8 string | Optional | `"MP3 File"` | See Kind values table below |
| `Size` | integer string | Optional | `"8945123"` | File size in bytes |
| `TotalTime` | integer string | **Rec'd** | `"342"` | Duration in whole seconds. Required for cue points to work correctly. |
| `DiscNumber` | integer string | Optional | `"1"` | |
| `TrackNumber` | integer string | Optional | `"3"` | Track position on the release (integer only) |
| `Year` | integer string | Optional | `"1983"` | |
| `AverageBpm` | float string | Optional | `"128.00"` | Two decimal places always. e.g. `"127.50"`, `"134.00"` |
| `DateAdded` | date string | Optional | `"2023-04-15"` | Format: `yyyy-mm-dd` (ISO-8601, zero-padded) |
| `BitRate` | integer string | Optional | `"320"` | kbps |
| `SampleRate` | float string | Optional | `"44100"` | Hz |
| `Comments` | UTF-8 string | Optional | `"Intro 32 bars"` | Free text |
| `PlayCount` | integer string | Optional | `"5"` | |
| `Rating` | integer string | Optional | `"204"` | 0-star scale mapped to 0/51/102/153/204/255 — see Rating table |
| `Location` | URI string | **Yes** | `"file://localhost/Users/dj/Music/track.mp3"` | **The only attribute flagged Essential in the Official Spec.** See Location format below. |
| `Remixer` | UTF-8 string | Optional | `"DJ Shadow"` | |
| `Tonality` | UTF-8 string | Optional | `"Am"` | Musical key notation — see Tonality notes below |
| `Label` | UTF-8 string | Optional | `"Factory Records"` | Record label |
| `Mix` | UTF-8 string | Optional | `"Original Mix"` | Mix version |
| `Colour` | hex string | Optional | `"0xFF0000"` | Track color tag from fixed 8-color palette — see Color table |

**Source:** Official Spec (primary); pyrekordbox docs (corroboration).

### Kind values

| Format | Kind String |
|--------|-------------|
| MP3 | `"MP3 File"` |
| AIFF | `"AIFF File"` |
| WAV | `"WAV File"` |
| FLAC | `"FLAC File"` |
| M4A/AAC | `"M4A File"` |
| MP4 | `"MP4 File"` |

If `Kind` is unrecognized, rekordbox silently ignores it (does not error). Map from `LocalFileEntity.format`.

### Rating mapping

| Stars (Discogs scale) | XML value |
|-----------------------|-----------|
| 0 | `"0"` |
| 1 | `"51"` |
| 2 | `"102"` |
| 3 | `"153"` |
| 4 | `"204"` |
| 5 | `"255"` |

Formula: `stars * 51`. Write only these six values — do not write arbitrary values in the 0-255 range.

### Location format

```
file://localhost/Users/djname/Music/Artist/Track%20Title.mp3
```

- Prefix: `file://localhost` (two slashes, then `localhost`, then the path). **Not** `file:///` (three slashes).
- Forward slashes always.
- Spaces → `%20`. All URI-reserved characters percent-encoded.
- macOS absolute path starts with `/Users/...` or `/Volumes/...`

Swift conversion:
```swift
let url = URL(fileURLWithPath: filePath)
// url.absoluteString gives "file:///path" — must replace with "file://localhost/path"
let location = "file://localhost" + url.path.addingPercentEncoding(
    withAllowedCharacters: .urlPathAllowed) ?? url.path
```

### Tonality notation

Rekordbox stores keys in **standard musical notation**. Its harmonic mixing engine operates on this format — writing Camelot codes breaks harmonic key matching.

| Camelot | Musical (major) | Camelot | Musical (minor) |
|---------|-----------------|---------|-----------------|
| 1B | C | 1A | Am |
| 2B | G | 2A | Em |
| 3B | D | 3A | Bm |
| 4B | A | 4A | F#m |
| 5B | E | 5A | C#m |
| 6B | B | 6A | G#m |
| 7B | F# | 7A | D#m |
| 8B | C# | 8A | Bbm |
| 9B | Ab | 9A | Fm |
| 10B | Eb | 10A | Cm |
| 11B | Bb | 11A | Gm |
| 12B | F | 12A | Dm |

VinylHarmonicMix stores `key` + `scale` (e.g. "A" + "minor") and `camelot` (e.g. "8A"). The exporter should convert via this table rather than writing Camelot codes.

Swift conversion sketch:
```swift
func musicalKey(key: String, scale: String) -> String {
    scale == "minor" ? "\(key)m" : key   // "A","minor" → "Am" | "C","major" → "C"
}
```

### Color palette

| Name | Value |
|------|-------|
| Rose | `0xFF007F` |
| Red | `0xFF0000` |
| Orange | `0xFFA500` |
| Lemon | `0xFFFF00` |
| Green | `0x00FF00` |
| Turquoise | `0x25FDE9` |
| Blue | `0x0000FF` |
| Violet | `0x660099` |

Omit `Colour` (or write `0x000000`) to leave the track uncolored.

---

### TEMPO children (beat grid)

Each `<TEMPO>` element defines a beat grid anchor. Multiple TEMPO elements per track are allowed (the spec explicitly states "more than two TEMPO can exist per track") — for variable-BPM tracks, each segment gets its own anchor.

```xml
<TEMPO Inizio="0.355" Bpm="128.00" Metro="4/4" Battito="1"/>
```

| Attribute | Type | Notes |
|-----------|------|-------|
| `Inizio` | float (seconds) | Start position of this beat anchor in **decimal seconds** from track start. e.g. `"0.355"` = 355 ms. Italian for "beginning". |
| `Bpm` | float | BPM at this anchor. Two decimal places. e.g. `"128.00"`, `"117.07"` |
| `Metro` | string | Time signature as fraction. `"4/4"` in practice for all electronic music. |
| `Battito` | integer | Beat-within-the-bar at the `Inizio` position (1-based). Downbeat = `1`. |

For a constant-BPM track, write one TEMPO with `Inizio` set to the first detected downbeat and `Battito="1"`.

VinylHarmonicMix has `bpm` (average) but no sub-beat-grid anchors. Use:
```xml
<TEMPO Inizio="0.000" Bpm="128.00" Metro="4/4" Battito="1"/>
```
This gives rekordbox enough to show the BPM and allow manual grid correction.

---

### POSITION_MARK children (cue points)

Each `<POSITION_MARK>` is a cue point, loop, or special marker. Multiple per track, no enforced limit.

```xml
<!-- Memory cue -->
<POSITION_MARK Name="Drop" Type="0" Start="32.500" Num="-1"/>

<!-- Hot cue A (green) -->
<POSITION_MARK Name="Intro" Type="0" Start="0.042" Num="0" Red="0" Green="255" Blue="0"/>

<!-- Hot cue B (red) -->
<POSITION_MARK Name="" Type="0" Start="128.000" Num="1" Red="255" Green="0" Blue="0"/>

<!-- Loop -->
<POSITION_MARK Name="8-bar loop" Type="4" Start="64.000" End="80.000" Num="0" Red="0" Green="255" Blue="0"/>
```

| Attribute | Type | Notes |
|-----------|------|-------|
| `Name` | UTF-8 string | Label shown in rekordbox. Can be `""`. |
| `Type` | integer | See Type table below |
| `Start` | float (seconds) | Position in **decimal seconds** from track start. Confirmed by Mixxx wiki and Official Spec. |
| `End` | float (seconds) | **Loop end position only.** Omit for all non-loop types. |
| `Num` | integer | `-1` = memory cue. `0–7` = hot cues A–H. |
| `Red` | 0–255 | Red channel of cue color. Present on hot cues; optional on memory cues. |
| `Green` | 0–255 | Green channel |
| `Blue` | 0–255 | Blue channel |

**Type values:**

| Value | Meaning |
|-------|---------|
| `0` | Standard cue / hot cue — distinguished by `Num` |
| `1` | Fade-In |
| `2` | Fade-Out |
| `3` | Load point (track loads to this position) |
| `4` | Loop |

**Num values:**

| Value | Meaning |
|-------|---------|
| `-1` | Memory cue (unlimited per track) |
| `0` | Hot cue A |
| `1` | Hot cue B |
| `2` | Hot cue C |
| `3` | Hot cue D |
| `4` | Hot cue E |
| `5` | Hot cue F |
| `6` | Hot cue G |
| `7` | Hot cue H |

Maximum hardware-supported hot cues: **8** (Num 0–7). CDJ-2000NXS2, XDJ-XZ all support exactly 8. Values above 7 will not map to hardware buttons.

Memory cues (Num=`-1`) have no hardware slot limit — CDJs display memory cues on the waveform regardless of count.

---

## PLAYLISTS Structure

```xml
<PLAYLISTS>
  <NODE Type="0" Name="ROOT" Count="2">
    <NODE Type="1" Name="Session June 8" KeyType="0" Entries="3">
      <TRACK Key="1001"/>
      <TRACK Key="1002"/>
      <TRACK Key="1003"/>
    </NODE>
    <NODE Type="0" Name="Tech House" Count="1">
      <NODE Type="1" Name="Deep cuts" KeyType="0" Entries="1">
        <TRACK Key="1004"/>
      </NODE>
    </NODE>
  </NODE>
</PLAYLISTS>
```

**NODE attributes — folder (Type="0"):**

| Attribute | Value |
|-----------|-------|
| `Type` | `"0"` |
| `Name` | Display name |
| `Count` | Number of direct child NODEs |

**NODE attributes — playlist (Type="1"):**

| Attribute | Value |
|-----------|-------|
| `Type` | `"1"` |
| `Name` | Display name |
| `KeyType` | `"0"` (TrackID reference) or `"1"` (Location URI reference). Use `"0"`. |
| `Entries` | Number of TRACK children |

**TRACK reference inside playlist:**
```xml
<TRACK Key="1001"/>   <!-- matches COLLECTION TRACK TrackID="1001" -->
```

The outermost NODE must always be `Type="0" Name="ROOT"`. All user content lives inside it. Nesting depth is unlimited in practice.

---

## Encoding & Edge Cases

### XML declaration
```xml
<?xml version="1.0" encoding="UTF-8"?>
```
Required. No BOM.

### Special character escaping

Standard XML entity escaping — **no CDATA**. The Official Spec explicitly requires this.

| Character | Escaped form |
|-----------|-------------|
| `&` | `&amp;` |
| `<` | `&lt;` |
| `>` | `&gt;` |
| `'` | `&apos;` |
| `"` | `&quot;` |

Accented and international characters (é, ü, 日本語, etc.) are written directly as UTF-8 in attribute values — no escaping needed beyond the five XML specials.

### File paths

- Format: `file://localhost/path/to/file.mp3` (two slashes + localhost)
- Spaces: `%20`
- All URI-reserved characters percent-encoded
- Always forward slashes

### DateAdded

Format: `"yyyy-mm-dd"` ISO-8601 zero-padded. Real rekordbox exports have been observed with non-padded dates (`"2019-9-27"`) — always write padded (`"2019-09-27"`) for safety.

---

## Import Behavior in Rekordbox

### How the user imports

**Rekordbox 6/7 (current):**
1. Open rekordbox → **Preferences** (⌘,)
2. **Advanced** tab → **Database** sub-tab
3. Click **Browse** next to "Imported Library" → select the `.xml` file
4. Close Preferences; the XML appears as a **"rekordbox xml"** source in the left sidebar
5. Right-click any playlist in the sidebar → **"Import To Collection"**

Alternative: **Preferences → View → Layout** — ensure "rekordbox xml" is checked.

### Merge vs replace

**Additive with a known bug.** For tracks not already in the library: imports correctly every time. For tracks already in the collection: a confirmed bug in rekordbox 5.6.1+ (including all of rekordbox 6 and 7) causes existing tracks to **not** be updated via the standard right-click → "Import To Collection" flow.

**Workaround:** In the XML sidebar view, select all tracks (Cmd+A), right-click → "Import To Collection" — this forced selection triggers an overwrite of existing entries.

Tracks removed from the XML are **never** removed from rekordbox — the import is additive/update only.

### Missing Location paths

If `Location` doesn't exist on the importing machine, rekordbox adds the track to the collection and marks it **missing** (warning icon). All metadata including BPM, key, and cue points is imported. The track can be relinked later via rekordbox's Relocate function.

### Track matching

**File path only.** rekordbox matches XML tracks to existing library entries via the `Location` URI. There is no audio fingerprint or content hash matching in the XML import flow. If the path changes, rekordbox treats it as a new track.

---

## Mapping VinylHarmonicMix → XML

### Per-track attributes

| XML Attribute | Source in VinylHarmonicMix | Notes |
|---------------|---------------------------|-------|
| `TrackID` | Auto-assigned integer during export | Sequential from 1, or derived from hash. Must be stable across re-exports to avoid duplicate imports. |
| `Name` | `TrackEntity.title` | Direct |
| `Artist` | `TrackEntity.artistCredit` | Direct |
| `Composer` | — | **Gap.** No composer field stored. Omit or leave `""`. |
| `Album` | `TrackEntity.collectionItem?.basicInformation?.title` | Release title from Discogs |
| `Grouping` | — | **Gap.** Could repurpose for Camelot code as a searchable field, but non-standard. Leave `""` for v1. |
| `Genre` | `TrackEntity.collectionItem?.basicInformation?.genres.first ?? ""` | Take first genre if multiple |
| `Kind` | Derived from `LocalFileEntity.format` | Map: `"mp3"→"MP3 File"`, `"flac"→"FLAC File"`, `"wav"→"WAV File"`, `"aiff"→"AIFF File"`, `"m4a"→"M4A File"` |
| `Size` | `LocalFileEntity.fileSizeBytes` | Cast to string; `"0"` if nil |
| `TotalTime` | `LocalFileEntity.durationSeconds` or `durationMs / 1000` | Prefer `durationMs` for precision; fallback to `TrackEntity.durationMs / 1000` |
| `DiscNumber` | — | **Gap.** Not stored. Write `"0"`. |
| `TrackNumber` | `TrackEntity.position` | **Partial gap.** Position is a string like `"A1"` or `"B2"` (vinyl side notation), not an integer. Parse numeric suffix or write `"0"` for v1. |
| `Year` | `TrackEntity.collectionItem?.basicInformation?.year` | Discogs release year |
| `AverageBpm` | `TrackEntity.effectiveBpm` | Computed property: prefers `localAudioFeatures.bpm` → falls back to matched `LocalFileEntity.bpm`. Format as `"%.2f"`. Omit if nil (0.00 would be misleading). |
| `DateAdded` | `TrackEntity.collectionItem?.dateAdded` | Already stored as string from Discogs. Verify format is `"yyyy-mm-dd"`. |
| `BitRate` | — | **Gap.** Not stored in any entity. Write `"0"` for v1. Consider adding to `LocalFileEntity` in a future pass. |
| `SampleRate` | — | **Gap.** Not stored. Write `"44100"` as default for v1. |
| `Comments` | — | Could populate with camelot + BPM summary (e.g. `"8A 128 BPM"`) for searchability. Optional. |
| `PlayCount` | — | **Gap.** Not tracked. Write `"0"`. |
| `Rating` | `TrackEntity.collectionItem?.rating ?? 0` | Discogs rating 0-5 × 51. |
| `Location` | `LocalFileEntity.filePath` or `TrackEntity.primaryLocalFilePath` | Must URL-encode: `"file://localhost" + percentEncoded(path)`. Only export tracks where `primaryLocalFilePath != nil`. |
| `Remixer` | — | **Gap.** Not stored. Leave `""`. |
| `Tonality` | `TrackEntity.effectiveKey` or convert from `effectiveCamelot` | `effectiveKey` returns `"key scale"` (e.g., `"A minor"`) — convert to rekordbox notation: `"A minor"→"Am"`, `"C major"→"C"`. Fallback: convert `effectiveCamelot` via Camelot→musical table above. |
| `Label` | `TrackEntity.collectionItem?.basicInformation?.labels.first?.name ?? ""` | First label credit from Discogs |
| `Mix` | — | **Gap.** Not stored. Leave `""`. |
| `Colour` | — | Not mapped for v1. Omit. |

### TEMPO child (beat grid)

| XML Attribute | Source |
|---------------|--------|
| `Inizio` | `"0.000"` — VinylHarmonicMix has no beat grid anchors, only average BPM |
| `Bpm` | `TrackEntity.effectiveBpm` formatted as `"%.2f"` |
| `Metro` | `"4/4"` hardcoded — electronic music assumption is safe |
| `Battito` | `"1"` — first beat of bar |

Write exactly one TEMPO per track. This gives rekordbox the BPM for display and CDJ sync, while letting the user refine the grid manually on the hardware.

### POSITION_MARK children (cue points)

VinylHarmonicMix `CuePointEntity` (attached to `LocalFileEntity`):

| XML Attribute | Source |
|---------------|--------|
| `Name` | `CuePointEntity.energyDirection` if non-empty, else `""`. Could also use `feature` field. |
| `Type` | `"0"` — all cues map to standard cue type |
| `Start` | `CuePointEntity.timeSec` formatted as `"%.3f"` |
| `End` | Omit (no loops stored in VinylHarmonicMix) |
| `Num` | `"-1"` — all export as memory cues. **No hot cue assignments stored.** |
| `Red`/`Green`/`Blue` | Omit for memory cues (or assign color by `type`: `"switch_in"` → green, `"structural"` → orange) |

Access path: `LocalFileEntity.cuePoints` where `localFile.filePath == track.primaryLocalFilePath`.

### PLAYLISTS section

| XML | Source |
|-----|--------|
| Playlist name | `SetlistEntity.name` |
| Track order | `SetlistItemEntity.position` sorted ascending |
| TRACK Key | TrackID assigned during COLLECTION export (look up by `SetlistItemEntity.filePath`) |

One `NODE Type="1"` per `SetlistEntity`. All sets go directly under ROOT (flat structure) for v1.

### Data gaps summary

| Gap | Impact | Recommendation |
|-----|--------|----------------|
| BitRate | Cosmetic in rekordbox | Write `"0"` for v1 |
| SampleRate | Cosmetic | Write `"44100"` default |
| TrackNumber (vinyl notation) | Mild — TrackNumber becomes `"0"` | Parse `position` field for v2 |
| DiscNumber | No practical impact | Write `"0"` |
| Beat grid anchors | BPM shown but grid can't auto-lock without a proper anchor | Single TEMPO at `"0.000"` is workable; user can correct on CDJ |
| Hot cue assignments | All cues import as memory cues, not hot cues | All memory cues is reasonable for v1 |
| Composer / Remixer / Mix | Metadata completeness | Leave empty strings |

---

## Open Questions

1. **Tonality: Camelot codes in Tonality field** — Community reports that writing `"8A"` is accepted and displayed in rekordbox when Camelot display is enabled, but it is confirmed to break rekordbox's internal harmonic mixing engine. **Decision: convert to musical notation.**

2. **Energy/novelty data** — VinylHarmonicMix has `CuePointEntity.novelty`, `energyDelta`, `energyDirection`. The Rekordbox XML has no energy field. **Decision for v1: put nothing in energy; surface it via cue point `Name` label if desired.**

3. **Hot cue color assignment strategy** — If we want some cues to export as hot cues (Num 0–7) rather than all as memory cues (Num=-1), we need an assignment policy. VinylHarmonicMix doesn't store this. Options: (a) first N cues → hot cues, rest → memory; (b) `isManual=true` → hot cue, auto → memory; (c) all memory for v1. **Leaning toward option (b) or all-memory for v1.** Leave as open question for implementation phase.

4. **Stable TrackID generation** — TrackIDs must be consistent across re-exports so rekordbox can update existing entries rather than create duplicates. Sequential indexing during a single export run is not stable. Options: (a) hash of `filePath`; (b) hash of `trackMBID`; (c) hash of `recordingMBID`. `filePath` is most direct since Location is also path-based. **Recommendation: `abs(filePath.hashValue) % Int32.max` as a stable integer.**

5. **Location encoding: literal spaces vs. `%20`** — The Official Spec says URI encoding. Some rekordbox versions have been observed exporting literal spaces. **Decision: always use `%20`. Safe, spec-correct, works on all versions.**

6. **Kind value for CAF files** — VinylHarmonicMix indexes `.caf` files but `"CAF File"` is not confirmed as a valid Kind string. If encountered, write the Kind field as `""` (empty) rather than an unconfirmed value.

7. **Maximum POSITION_MARKs per track** — The spec is silent on a hard cap. Community usage suggests rekordbox handles dozens of memory cues. For v1 this is not an issue since most tracks will have 2–8 cue points from the detection algorithm.

---

## Recommendations for v1

### Minimal viable XML — what to implement first

A v1 exporter should target this feature set:

**Must have:**
- `COLLECTION` with one `<TRACK>` per matched track (`primaryLocalFilePath != nil`)
- Attributes: `TrackID`, `Name`, `Artist`, `Album`, `Genre`, `Kind`, `Size`, `TotalTime`, `AverageBpm`, `DateAdded`, `Rating`, `Location`, `Tonality`, `Label`, `Year`
- One `<TEMPO>` per track (single anchor at `Inizio="0.000"`) — gives BPM to CDJ
- All `CuePointEntity` entries as `<POSITION_MARK Type="0" Num="-1">` (memory cues)
- `PLAYLISTS` section with one NODE per `SetlistEntity`, referencing tracks by TrackID

**Omit for v1 (default/empty):**
- `BitRate`, `SampleRate` → write `"0"` and `"44100"` respectively
- `Composer`, `Remixer`, `Mix`, `Grouping`, `Comments`, `Colour` → empty strings
- `DiscNumber`, `TrackNumber` → `"0"`
- `PlayCount` → `"0"`
- Hot cue color assignment → all memory cues (Num=`"-1"`), no RGB attributes

**Tonality conversion:** Use `effectiveKey` (`key` + `scale` fields) → musical notation. Camelot-to-musical fallback table available if `key`/`scale` are empty.

### Critical correctness requirements

1. `Location` must use `file://localhost` prefix (not `file:///`), with percent-encoded spaces.
2. `TotalTime` must be an integer (not float) in whole seconds.
3. `AverageBpm` must be formatted with exactly two decimal places.
4. `Rating` must be one of: `0, 51, 102, 153, 204, 255`.
5. `POSITION_MARK Start` and `TEMPO Inizio` are in **decimal seconds** (not milliseconds — VinylHarmonicMix stores `timeSec` which is already in seconds; `durationMs` needs `/1000`).
6. XML special characters in attribute values must be entity-escaped (`&amp;`, etc.).
7. `COLLECTION Entries` attribute must match the actual TRACK count.
8. All `TRACK Key` values in PLAYLISTS must match a `TrackID` in COLLECTION.

### Scope boundary

The exporter generates a `.xml` file that the user imports manually via Preferences → Advanced → Database → Imported Library. There is no direct write to rekordbox's internal SQLite database. The XML path is the documented, supported Pioneer interop path — it does not require any file modification on the user's audio files.
