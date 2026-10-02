#!/usr/bin/env python3
"""
Four-to-floor gate validation script.
Scratch test — does NOT touch essentia_cue.py.

Gate algorithm:
  1. HPSS soft-mask → full-band percussive audio (no LP filter — spike showed
     full-band gives 92% beat-regularity on Pjanoo vs 84% for LP400).
  2. SuperFlux onset detection on percussive audio.
  3. Compute inter-onset gaps.  Regularity = fraction within ±20% of beat_dur.
  4. Gate: regularity >= THRESHOLD and n_onsets >= MIN_ONSETS → four-to-floor YES.

Usage: python3 ftf_gate_validate.py
"""

import os
import sys
import time
import numpy as np
import essentia.standard as es

# Root of your music library; the track paths below are relative to it.
MUSIC_ROOT = os.environ.get("VHM_MUSIC_ROOT", os.path.expanduser("~/Music"))

# ── constants ─────────────────────────────────────────────────────────────
_SR      = 44100
_FRAME   = 2048
_HOP     = 512
_HPSS_T  = 21       # time-axis median kernel (frames) — harmonic smoothing
_HPSS_F  = 21       # freq-axis median kernel (bins) — percussive spreading

# Gate thresholds (proposed — data will confirm or refute)
THRESHOLD   = 0.70   # regularity score for YES
MIN_ONSETS  = 20     # minimum kick onsets for a valid reading
BEAT_WINDOW = 0.20   # ±20% of beat_dur counts as "regular"

# ── HPSS + onset ──────────────────────────────────────────────────────────

def _hpss_soft_percussive(audio: np.ndarray) -> np.ndarray:
    """Return percussive component via Wiener soft-mask HPSS (no LP)."""
    n    = len(audio)
    hann = np.hanning(_FRAME).astype(np.float32)
    nf   = (n - _FRAME) // _HOP + 1
    if nf < 2:
        return audio

    # Vectorised STFT
    view     = np.lib.stride_tricks.sliding_window_view(
                   np.pad(audio, (0, _FRAME), mode='constant'), _FRAME)
    windowed = (view[np.arange(nf) * _HOP] * hann).astype(np.float32)
    stft     = np.fft.rfft(windowed, axis=1)           # (nf, n_freq)
    S        = np.abs(stft).T.astype(np.float32)        # (n_freq, nf)

    # Harmonic: median along time axis
    pt = _HPSS_T // 2
    H  = np.median(
             np.lib.stride_tricks.sliding_window_view(
                 np.pad(S, ((0, 0), (pt, pt)), mode='edge'),
                 _HPSS_T, axis=1),
             axis=-1)

    # Percussive: median along freq axis
    pf = _HPSS_F // 2
    P  = np.median(
             np.lib.stride_tricks.sliding_window_view(
                 np.pad(S, ((pf, pf), (0, 0)), mode='edge'),
                 _HPSS_F, axis=0),
             axis=-1)

    # Wiener soft mask
    soft = P * P / (H * H + P * P + 1e-8)              # (n_freq, nf)

    # ISTFT via irfft + WOLA synthesis
    tf  = np.fft.irfft(stft * soft.T, n=_FRAME, axis=1).astype(np.float32)
    out = np.zeros((nf - 1) * _HOP + _FRAME, np.float64)
    nrm = np.zeros_like(out)
    h64 = hann.astype(np.float64)
    h2  = (hann * hann).astype(np.float64)
    for i in range(nf):
        s = i * _HOP
        out[s:s + _FRAME] += tf[i] * h64
        nrm[s:s + _FRAME] += h2
    out = np.where(nrm > 1e-10, out / nrm, 0.0).astype(np.float32)[:n]
    pk  = np.abs(out).max()
    return out / pk * 0.9 if pk > 1e-6 else out


def _kick_onsets(audio: np.ndarray) -> np.ndarray:
    """Full-band SuperFlux on the percussive component."""
    perc = _hpss_soft_percussive(audio)
    return np.asarray(
        es.SuperFluxExtractor(frameSize=_FRAME, hopSize=_HOP,
                              sampleRate=_SR)(perc),
        dtype=np.float32)


# ── Gate metric ───────────────────────────────────────────────────────────

def gate_score(onsets: np.ndarray, bpm: float, duration: float
               ) -> dict:
    """
    Returns a dict with:
      regularity   – fraction of gaps within ±20% of beat_dur
      onsets_per_min
      median_gap
      expected_gap  = 60 / bpm
      n_onsets
      is_four_to_floor  – boolean under THRESHOLD / MIN_ONSETS criteria
    """
    beat_dur    = 60.0 / bpm if bpm > 0 else 0.48
    n           = len(onsets)
    opm         = n / (duration / 60.0) if duration > 0 else 0.0

    if n >= 2:
        gaps     = np.diff(np.sort(onsets))
        med_gap  = float(np.median(gaps))
        # count gaps within ±BEAT_WINDOW of beat_dur
        regular  = int(np.sum(np.abs(gaps - beat_dur) <= beat_dur * BEAT_WINDOW))
        reg_frac = regular / len(gaps)
    else:
        med_gap  = 0.0
        reg_frac = 0.0

    is_ftf = (reg_frac >= THRESHOLD) and (n >= MIN_ONSETS)

    return dict(
        regularity     = reg_frac,
        onsets_per_min = opm,
        median_gap     = med_gap,
        expected_gap   = beat_dur,
        n_onsets       = n,
        is_four_to_floor = is_ftf,
    )


# ── Per-track runner ──────────────────────────────────────────────────────

def run_track(path: str, bpm: float, label: str, expected: str) -> dict:
    t0    = time.time()
    audio = es.MonoLoader(filename=path, sampleRate=_SR)()
    dur   = len(audio) / _SR
    t1    = time.time()

    onsets = _kick_onsets(audio)
    t2    = time.time()

    scores = gate_score(onsets, bpm, dur)
    elapsed = t2 - t0

    result = dict(
        label     = label,
        expected  = expected,
        bpm       = bpm,
        dur_sec   = dur,
        elapsed   = elapsed,
        **scores,
    )
    return result


# ── Track list ────────────────────────────────────────────────────────────

TRACKS = [
    # ── KNOWN FOUR-TO-FLOOR ─────────────────────────────────────────────
    (
        MUSIC_ROOT + "/Eric Prydz/2008 Eric Prydz - Pjanoo [DIGI0229] WEB"
        "/01 Eric Prydz - Pjanoo (Radio Edit).mp3",
        125.99, "Pjanoo – Eric Prydz", "YES",
    ),
    (
        MUSIC_ROOT + "/Eric Prydz/Pryda/2007 - Rymd & Armed/02 - Armed.flac",
        126.88, "Armed – Pryda", "YES",
    ),
    (
        MUSIC_ROOT + "/Eric Prydz/Pryda/2010 - Illusions & Glimma/01 - Illusions.flac",
        125.99, "Illusions – Pryda", "YES",
    ),
    (
        MUSIC_ROOT + "/Inner City/Inner City - Good Life (US CDS Promo) (1988) - PRCD2622"
        "/02. Inner City - Good Life (Magic Juan Mix).flac",
        125.2, "Good Life (Magic Juan) – Inner City", "YES",
    ),
    (
        MUSIC_ROOT + "/Black Box/Black Box - Everybody Everybody (Freak Remix) (1991).flac",
        117.69, "Everybody Everybody (Freak Rmx) – Black Box", "YES",
    ),
    (
        MUSIC_ROOT + "/Sharada House Gang/Sharada House Gang - Gypsy Boy, Gypsy Girl (1997) 320"
        "/03 - Gypsy Boy Gypsy Girl (Van's Hard Mix).mp3",
        123.78, "Gypsy Boy Gypsy Girl (Van's Hard Mix) – Sharada", "YES",
    ),
    (
        MUSIC_ROOT + "/Crystal Waters/1991 - Makin' Happy (Europe CDS) (1991) - 868 849-2"
        "/02. Crystal Waters - Makin' Happy (Hurley's Happy House Mix).flac",
        120.0, "Makin' Happy (Hurley House Mix) – Crystal Waters", "YES",
    ),
    # ── KNOWN NOT FOUR-TO-FLOOR ─────────────────────────────────────────
    (
        MUSIC_ROOT + "/Felix"
        "/1992 - Don't You Want Me (Original Mixes And Remixes) (Europe CDS) (1992) - 74321 11050 2"
        "/01. Felix - Don't You Want Me (Hooj Mix Edit).flac",
        128.01, "Don't You Want Me (Hooj Edit) – Felix", "NO",
    ),
    (
        MUSIC_ROOT + "/Michael Jackson/Michael Jackson - Smooth Criminal. Remixes Vol.1"
        "/Michael Jackson - Smooth Criminal (2006 Electro Remix).mp3",
        128.02, "Smooth Criminal (Electro Remix) – MJ", "NO",
    ),
    (
        MUSIC_ROOT + "/Sade/1988 - Nothing Can Come Between Us"
        "/01. Nothing Can Come Between Us.mp3",
        103.59, "Nothing Can Come Between Us – Sade", "NO",
    ),
    (
        MUSIC_ROOT + "/Soul II Soul/Soul II Soul - Back to Life (feat. Caron Wheeler).flac",
        101.0, "Back to Life – Soul II Soul", "NO",
    ),
    (
        MUSIC_ROOT + "/Simply Red/Simply Red - Something Got Me Started (UK CDM) (1991) - YZ614CD"
        "/04. Simply Red - Something Got Me Started (Perfecto Mix).flac",
        113.35, "Something Got Me Started (Perfecto) – Simply Red", "NO",
    ),
    (
        MUSIC_ROOT + "/Neneh Cherry/Neneh Cherry - Buffalo Stance (US CDS Promo) (1988) - PRCD2726"
        "/Neneh Cherry - Kisses On The Wind (Lovers Hip-Hop Extended Mix).wav",
        97.33, "Kisses on the Wind (Hip-Hop Ext.) – Neneh Cherry", "NO",
    ),
    # ── AMBIGUOUS ───────────────────────────────────────────────────────
    (
        MUSIC_ROOT + "/Soul II Soul/Soul II Soul - Holdin' On [Bambelela].flac",
        117.82, "Holdin' On – Soul II Soul  [ambiguous: faster tempo]", "?",
    ),
    (
        MUSIC_ROOT + "/Black Box/Black Box - Ride On Time (Piano Mix) (1990).flac",
        116.75, "Ride On Time (Piano Mix) – Black Box  [ambiguous: piano remix]", "?",
    ),
    (
        MUSIC_ROOT + "/St Germain/2021 - Extra Cabin Baggage"
        "/07 - So Flute (Ludovic Navarre Amapiano Deep Sunny mix) (radio edit).flac",
        118.48, "So Flute (Amapiano mix) – St Germain  [ambiguous: amapiano]", "?",
    ),
    (
        MUSIC_ROOT + "/Snap!/1992 - SNAP! - Rhythm Is A Dancer (CD3) (Japan)"
        "/Snap! - 1992 - Rhythm Is A Dancer (CD3) (Japan).flac",
        124.17, "Rhythm Is A Dancer (Japan 12\") – Snap!  [ambiguous: euro-dance]", "?",
    ),
]


# ── Main ─────────────────────────────────────────────────────────────────

def fmt_dur(s): m=int(s//60); return f"{m}:{int(s%60):02d}"
def bar(v, width=20): return ('█' * int(v * width)).ljust(width)

if __name__ == "__main__":
    print(f"Four-to-floor gate validation")
    print(f"Threshold: regularity ≥ {THRESHOLD:.0%}  AND  onsets ≥ {MIN_ONSETS}\n")

    results = []
    for args in TRACKS:
        path, bpm, label, expected = args
        print(f"  … {label} ({bpm} BPM)", flush=True)
        try:
            r = run_track(path, bpm, label, expected)
        except Exception as e:
            print(f"      ERROR: {e}", file=sys.stderr)
            continue
        results.append(r)
        pred = "YES" if r["is_four_to_floor"] else "NO "
        mark = "✓" if pred.strip() == expected or expected == "?" else "✗"
        print(f"      reg={r['regularity']:.0%}  opm={r['onsets_per_min']:.0f}"
              f"  med_gap={r['median_gap']:.3f}s (exp {r['expected_gap']:.3f}s)"
              f"  n={r['n_onsets']}  →  {pred}  [{mark} expected {expected}]"
              f"  {r['elapsed']:.1f}s", flush=True)

    # ── Summary table ─────────────────────────────────────────────────────
    print(f"\n{'─'*100}")
    print(f"{'Track':<46} {'BPM':>5} {'Dur':>5} {'Reg':>5} {'OPM':>5}"
          f" {'MedGap':>7} {'ExpGap':>7} {'N':>4}  {'Gate':>5}  {'Exp':>3}  {'Match':>5}  {'Time':>5}")
    print(f"{'─'*100}")

    n_correct = 0
    n_judged  = 0
    for r in results:
        pred  = "YES" if r["is_four_to_floor"] else "NO "
        match = "?" if r["expected"] == "?" else ("✓" if pred.strip() == r["expected"] else "✗ WRONG")
        if r["expected"] != "?":
            n_judged += 1
            if pred.strip() == r["expected"]: n_correct += 1
        print(
            f"{r['label'][:45]:<46}"
            f" {r['bpm']:>5.1f}"
            f" {fmt_dur(r['dur_sec']):>5}"
            f" {r['regularity']:>5.0%}"
            f" {r['onsets_per_min']:>5.0f}"
            f" {r['median_gap']:>7.3f}"
            f" {r['expected_gap']:>7.3f}"
            f" {r['n_onsets']:>4}"
            f"  {'YES' if r['is_four_to_floor'] else 'NO ':>5}"
            f"  {r['expected']:>3}"
            f"  {match:>5}"
            f"  {r['elapsed']:>4.1f}s"
        )

    print(f"{'─'*100}")
    if n_judged:
        print(f"\nClassification accuracy on known tracks: {n_correct}/{n_judged} "
              f"({100*n_correct/n_judged:.0f}%)")

    # ── Threshold sensitivity ─────────────────────────────────────────────
    print(f"\nThreshold sensitivity (accuracy vs threshold on {n_judged} labelled tracks):")
    scored = [(r["regularity"], r["n_onsets"], r["expected"]) for r in results if r["expected"] != "?"]
    for thr in [0.50, 0.60, 0.70, 0.75, 0.80, 0.85]:
        correct = sum(
            1 for reg, n_o, exp in scored
            if (("YES" if (reg >= thr and n_o >= MIN_ONSETS) else "NO") == exp)
        )
        print(f"  thr={thr:.0%}: {correct}/{len(scored)} ({100*correct/len(scored):.0f}%)")

    # ── Time cost estimate ─────────────────────────────────────────────────
    if results:
        secs_per_min = np.mean([r["elapsed"] / (r["dur_sec"] / 60) for r in results])
        print(f"\nAvg gate cost: {secs_per_min:.1f}s / minute of audio")
        print(f"  560 matched tracks × avg ~4 min  → est. {int(560 * 4 * secs_per_min / 60)} min total")

    print("\nDone.")
