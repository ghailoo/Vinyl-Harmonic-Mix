<div align="center">

# VinylHarmonicMix

**Your vinyl collection. Mixed intelligently.**

A native macOS app for building harmonically compatible DJ sets from your Discogs collection — matched to your local digital files, ranked by key and tempo, and played back with real crossfades.

</div>

---

## Overview

VinylHarmonicMix turns a Discogs collection into a working DJ tool. It syncs your releases, enriches them with MusicBrainz and AcousticBrainz metadata, matches tracks to the digital files on your drive, and helps you build sets using harmonic mixing theory — all without leaving your library.

No manual tagging. No spreadsheets. Just your records, organized the way a DJ actually thinks about them.

## Highlights

**Your collection, synced**
Pull your library straight from Discogs, then enrich it automatically with MusicBrainz recording data and AcousticBrainz audio features — key, BPM, and mood, all matched to the exact pressing you own.

**Match vinyl to files**
Point VinylHarmonicMix at your local audio library and it links each release to the right file, ready to play. A safety guard verifies every drive before anything is touched — nothing is ever matched, moved, or deleted without a clean, verified mount.

**Mix by ear, not by guesswork**
Every track is placed on the Camelot wheel. Build a set and watch harmonically compatible tracks — perfect matches, energy boosts, energy drops, mood switches — surface automatically, ranked by BPM closeness.

**Real crossfades**
Sets play back with a smooth, five-second linear crossfade between tracks, pre-loaded well before the outgoing track ends. When a set runs out, VinylHarmonicMix keeps going — pulling harmonically compatible tracks from your whole library.

**Built to survive a mistake**
Matches are backed up to a portable, human-readable JSON file, keyed to survive drive re-mounts and folder reorganizations. Clearing a working set of more than a couple of tracks asks first.

**Export where you mix**
Send finished sets to Rekordbox as a standard XML library, ready to drop into your existing workflow.

## Requirements

- macOS 15 or later
- A Discogs account and collection
- Xcode 26 or later, to build from source

## Getting Started

```bash
git clone https://github.com/ghailoo/Vinyl-Harmonic-Mix.git
cd Vinyl-Harmonic-Mix
open VinylHarmonicMix.xcodeproj
```

Build and run with `⌘R`. On first launch, add your Discogs API credentials and point the app at your local audio library in Settings.

## Under the Hood

- **SwiftUI + SwiftData** — fully native, no cross-platform framework
- **Discogs, MusicBrainz, AcousticBrainz, AcoustID** — the metadata pipeline behind every release
- **Essentia** — local audio analysis (BPM, key) when online sources fall short
- **Camelot wheel harmonic mixing** — the same compatibility logic professional DJs use to plan transitions

## Status

VinylHarmonicMix is a personal project, under active development. Expect rough edges.

---

<div align="center">

Built for people who still buy the record.

</div>
