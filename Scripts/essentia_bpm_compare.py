#!/usr/bin/env python3
"""
Compares degara vs multifeature BPM methods and times each.
Reports confidence + estimates array from RhythmExtractor2013.
"""

import time
import json
import os
import sys
import essentia.standard as es

# Root of your music library; the track paths below are relative to it.
MUSIC_ROOT = os.environ.get("VHM_MUSIC_ROOT", os.path.expanduser("~/Music"))

FILES = [
    {
        "label": "Joyce Sims – It Wasn't Easy [MP3]",
        "path": MUSIC_ROOT + "/Joyce Sims/Joyce Sims - The Best Of - Come Into My Life (2010) 192-320/CD1 - Original Studio Mixes/09 - It Wasn't Easy.mp3",
        "ab_bpm": 178.21, "ab_key": "C", "ab_scale": "major",
    },
    {
        "label": "Sybil – Don't Make Me Over (Radio) [FLAC]",
        "path": MUSIC_ROOT + "/Sybil/Sybil - Don't Make Me Over (US CDS Promo) (1989) - NPCD50107/02. Sybil - Don't Make Me Over (Radio).flac",
        "ab_bpm": 96.72, "ab_key": "C", "ab_scale": "major",
    },
    {
        "label": "Natalie Cole – Pink Cadillac (7\") [FLAC]",
        "path": MUSIC_ROOT + "/Natalie Cole/pink cadillac (uk cdm)/ 01 - Natalie Cole - Pink Cadillac (7'' Version).flac",
        "ab_bpm": 125.41, "ab_key": "A#", "ab_scale": "major",
    },
    {
        "label": "Smoke City – Underwater Love [FLAC]",
        "path": MUSIC_ROOT + "/Smoke City/Smoke City - Flying Away (Japan) (1997) [FLAC]/01-Underwater Love.flac",
        "ab_bpm": 163.54, "ab_key": "F", "ab_scale": "minor",
    },
    {
        "label": "Culture Club – Do You Really Want to Hurt Me [FLAC]",
        "path": MUSIC_ROOT + "/Culture Club/Culture Club - Do You Really Want To Hurt Me.flac",
        "ab_bpm": 100.39, "ab_key": "G", "ab_scale": "major",
    },
]


def load_audio(path):
    loader = es.MonoLoader(filename=path, sampleRate=44100)
    return loader()


def run_rhythm(audio, method):
    extractor = es.RhythmExtractor2013(method=method)
    t0 = time.time()
    bpm, beats, confidence, estimates, bpm_intervals = extractor(audio)
    elapsed = time.time() - t0
    # Top 5 estimate candidates (sorted by frequency)
    top_estimates = sorted(set(round(float(e), 1) for e in estimates))[:8]
    return float(bpm), float(confidence), top_estimates, elapsed


def run_key(audio):
    key_ex = es.KeyExtractor(profileType="temperley")
    key, scale, strength = key_ex(audio)
    return key, scale, float(strength)


def normalize_bpm(bpm):
    """Bring BPM into 90-180 range by halving/doubling."""
    while bpm < 90:
        bpm *= 2
    while bpm > 180:
        bpm /= 2
    return round(bpm, 2)


def main():
    print()
    for info in FILES:
        label = info["label"]
        path  = info["path"]
        ab_bpm  = info["ab_bpm"]
        ab_key  = info["ab_key"]
        ab_scale = info["ab_scale"]

        print(f"{'='*70}")
        print(f"  {label}")
        print(f"  AcousticBrainz: BPM={ab_bpm:.2f}, {ab_key} {ab_scale}")
        print()

        try:
            t_load = time.time()
            audio = load_audio(path)
            load_sec = time.time() - t_load
            print(f"  Load: {load_sec:.1f}s  ({len(audio)/44100:.0f}s audio)")

            d_bpm, d_conf, d_est, d_sec = run_rhythm(audio, "degara")
            m_bpm, m_conf, m_est, m_sec = run_rhythm(audio, "multifeature")
            key, scale, strength = run_key(audio)

            d_norm = normalize_bpm(d_bpm)
            m_norm = normalize_bpm(m_bpm)
            ab_norm = normalize_bpm(ab_bpm)

            d_err = abs(d_norm - ab_norm)
            m_err = abs(m_norm - ab_norm)

            print(f"  degara:       {d_bpm:7.2f} BPM  conf={d_conf:.3f}  time={d_sec:.1f}s"
                  f"  → norm={d_norm:.2f}  Δ={d_err:.2f}")
            print(f"    estimates: {d_est}")
            print(f"  multifeature: {m_bpm:7.2f} BPM  conf={m_conf:.3f}  time={m_sec:.1f}s"
                  f"  → norm={m_norm:.2f}  Δ={m_err:.2f}")
            print(f"    estimates: {m_est}")
            print(f"  Key (Temperley): {key} {scale}  strength={strength:.4f}"
                  f"  (AB: {ab_key} {ab_scale})")
            print()

        except Exception as exc:
            print(f"  ERROR: {exc}")
            print()

    print(f"{'='*70}")


if __name__ == "__main__":
    main()
