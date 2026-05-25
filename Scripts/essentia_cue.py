#!/usr/bin/env python3
"""
essentia_cue.py <audio_file>

Energy-only EXPERT cue-point detection.
(Zehren, Alunno, Bientinesi 2022 — "Automatic Detection of Cue Points for the Emulation
of DJ Mixing", Computer Music Journal — energy feature only, v2.)

Detects TWO classes of cue points per track:

  switch_points  — ONE intro mix-in point (unchanged from v1): the highest-novelty
                   position inside the intro's 4-bar-aligned grid.

  structural_points — 5-8 section-boundary points across the whole track (drops,
                   breakdowns, texture changes) found by greedy peak-picking the same
                   full-track novelty curve, with energy-direction labels.

Output JSON:
  {
    "switch_points":     [{"time_sec": 16.42, "feature": "energy", "novelty": 0.73, "beat_index": 32}],
    "structural_points": [{"time_sec": 48.5,  "novelty": 0.91,    "beat_index": 96,  "energy_direction": "rise"},
                          {"time_sec": 80.2,  "novelty": 0.78,    "beat_index": 160, "energy_direction": "fall"},
                          ...],
    "bpm": 124.0,
    "n_beats": 548
  }
  switch_points is [] when no usable intro is found (same conditions as v1).
  structural_points is [] only for very short / silent tracks.

Error:
  {"error": "description"}   exit code 1

Pipeline:
  Stages 1-4 run for EVERY track (energy curve, SSM/Foote novelty, 4-bar alignment).
  Structural detection uses the full aligned grid after Stage 4 (no recomputation).
  Stage 5 (intro salience + switch-in) runs only when a usable intro is found.
"""

import json
import os
import sys

import numpy as np

# ── Constants ────────────────────────────────────────────────────────────────

_FRAME_SIZE  = 2048
_HOP_SIZE    = 512
_SAMPLE_RATE = 44100

_MIN_BEATS   = 16    # fewer → no detection
_PERIOD      = 8     # strong-beat windows per 4-bar period (4 bars × 2 sb/bar)
_KERNEL_HALF = 8     # Foote kernel half-size in strong-beat windows (= 4 bars)
                     # → full 8-bar kernel of size (16 × 16)

# Structural peak-picking
_STRUCT_MAX          = 8    # maximum structural cue points per track
_STRUCT_MIN_SPACING  = 16   # min gap between picks in strong-beat windows (= 8 bars)
_STRUCT_THRESHOLD    = 0.25 # minimum normalised novelty score to qualify as a boundary
_STRUCT_MIN_TIME_SEC = 8.0  # skip candidates before this time (kills zero-padding artifacts)

# Energy-direction labeling
_DIR_WINDOW  = 4    # windows on each side of boundary for mean comparison (= 2 bars)
_DIR_EPSILON = 0.05 # minimum energy difference (normalised) to assign direction


# ── Feature extraction ───────────────────────────────────────────────────────

def _extract(path: str):
    """
    Load audio at 44.1 kHz mono, run RhythmExtractor2013 (degara) for beats,
    run FrameGenerator+RMS for the per-frame energy curve.
    Returns (bpm: float, beats: ndarray[float64], rms: ndarray[float32]).
    """
    import essentia.standard as es

    audio = es.MonoLoader(filename=path, sampleRate=_SAMPLE_RATE)()

    bpm, beats, _, _, _ = es.RhythmExtractor2013(method="degara")(audio)

    rms_algo = es.RMS()
    rms_curve = np.array(
        [float(rms_algo(frame))
         for frame in es.FrameGenerator(
             audio, frameSize=_FRAME_SIZE, hopSize=_HOP_SIZE, startFromZero=True)],
        dtype=np.float32,
    )
    return float(bpm), np.asarray(beats, dtype=np.float64), rms_curve


# ── Stage 2: energy per strong-beat window ───────────────────────────────────

def _window_energy(strong_beats: np.ndarray, rms: np.ndarray) -> np.ndarray:
    """
    For each consecutive pair of strong beats, compute the RMS of the energy
    frames that fall in that time window.  Returns shape (n_windows,).
    """
    n = len(strong_beats) - 1
    energy = np.zeros(n, dtype=np.float64)
    for i in range(n):
        f0 = max(0, int(strong_beats[i]     * _SAMPLE_RATE / _HOP_SIZE))
        f1 = min(len(rms), int(strong_beats[i + 1] * _SAMPLE_RATE / _HOP_SIZE))
        if f1 > f0:
            energy[i] = float(np.sqrt(np.mean(rms[f0:f1] ** 2)))
    return energy


# ── Stage 3: Foote checkerboard novelty ──────────────────────────────────────

def _foote_novelty(energy_norm: np.ndarray) -> np.ndarray:
    """
    1-D self-similarity matrix + Gaussian-tapered checkerboard kernel.
    Zero-padded at both ends by K windows so intro positions receive full
    kernel context (the paper's recommended treatment for the DJ search space).

    SSM[i,j] = 1 - |energy_norm[i] - energy_norm[j]|   (similarity in [0,1])
    Checkerboard: +1 in top-left and bottom-right quadrants, -1 in cross quadrants.
    Gaussian taper with sigma = K/2.
    """
    K  = _KERNEL_HALF
    ks = 2 * K           # full kernel edge length (16 strong-beat windows = 8 bars)

    # Zero-pad
    padded = np.concatenate([np.zeros(K), energy_norm, np.zeros(K)])
    N = len(padded)

    # SSM via broadcasting
    SSM = 1.0 - np.abs(padded[:, None] - padded[None, :])  # (N, N)

    # Gaussian-tapered checkerboard kernel
    idx   = np.arange(ks, dtype=np.float64) - K + 0.5
    gx, gy = np.meshgrid(idx, idx)
    sigma = K / 2.0
    gauss = np.exp(-(gx ** 2 + gy ** 2) / (2.0 * sigma ** 2))
    sign  = np.ones((ks, ks), dtype=np.float64)
    sign[:K, K:] = -1.0
    sign[K:, :K] = -1.0
    kernel = gauss * sign   # (ks, ks)

    # Slide the kernel along the SSM diagonal
    novelty_full = np.zeros(N, dtype=np.float64)
    for n in range(K, N - K):
        block = SSM[n - K: n + K, n - K: n + K]
        novelty_full[n] = float(np.sum(kernel * block))

    # Return only the original (non-padded) positions
    return novelty_full[K: K + len(energy_norm)]


# ── Structural peak-picking ───────────────────────────────────────────────────

def _pick_structural(aligned: np.ndarray, novelty_norm: np.ndarray,
                     energy_norm: np.ndarray, strong: np.ndarray) -> list:
    """
    Greedy peak-pick on the full 4-bar-aligned grid.

    Sort aligned positions by descending novelty; greedily accept each position
    that is (a) above _STRUCT_THRESHOLD and (b) at least _STRUCT_MIN_SPACING
    windows away from every already-accepted position.  _STRUCT_MAX is a sanity
    ceiling only — threshold and spacing are the natural limiters.
    Returned list is sorted chronologically.
    """
    n_w = len(energy_norm)
    scores      = novelty_norm[aligned]
    sorted_order = aligned[np.argsort(scores)[::-1]]  # highest novelty first

    picked = []
    for w in sorted_order:
        nov = float(novelty_norm[w])
        if nov < _STRUCT_THRESHOLD:
            break  # sorted descending — nothing better remains
        if float(strong[w]) < _STRUCT_MIN_TIME_SEC:
            continue  # zero-padding artifact near track start — skip, don't count
        if all(abs(int(w) - p) >= _STRUCT_MIN_SPACING for p in picked):
            picked.append(int(w))
        if len(picked) >= _STRUCT_MAX:
            break

    picked.sort()  # restore chronological order

    result = []
    for w in picked:
        # Energy direction: compare mean energy in the windows before vs after
        before = energy_norm[max(0, w - _DIR_WINDOW) : w]
        after  = energy_norm[w : min(n_w, w + _DIR_WINDOW)]
        bm = float(np.mean(before)) if len(before) > 0 else 0.0
        am = float(np.mean(after))  if len(after)  > 0 else 0.0

        if   am > bm + _DIR_EPSILON:  direction = "rise"
        elif bm > am + _DIR_EPSILON:  direction = "fall"
        else:                          direction = "neutral"

        result.append({
            "time_sec":         round(float(strong[w]), 3),
            "novelty":          round(float(novelty_norm[w]), 4),
            "beat_index":       w * 2,
            "energy_direction": direction,
            "energy_delta":     round(abs(am - bm), 2),
        })

    return result


# ── Main detection pipeline ───────────────────────────────────────────────────

def _detect(bpm: float, beats: np.ndarray, rms: np.ndarray) -> dict:
    n_beats = len(beats)
    base    = {"bpm": round(bpm, 2), "n_beats": n_beats}

    if n_beats < _MIN_BEATS:
        return {**base, "switch_points": [], "structural_points": []}

    # ── Stage 1: strong beats ─────────────────────────────────────────────────
    strong = beats[::2]           # shape (n_strong,)
    n_w    = len(strong) - 1      # number of strong-beat windows

    if n_w < _PERIOD * 2:         # need at least 2 full 4-bar periods
        return {**base, "switch_points": [], "structural_points": []}

    # ── Stage 2: windowed energy, normalised 0..1 ─────────────────────────────
    energy = _window_energy(strong, rms)
    e_max  = energy.max()
    if e_max <= 0.0:
        return {**base, "switch_points": [], "structural_points": []}
    energy_norm = energy / e_max

    # ── Stage 3: Foote novelty, normalised 0..1 ───────────────────────────────
    novelty = _foote_novelty(energy_norm)
    nov_rng = novelty.max() - novelty.min()
    if nov_rng <= 0.0:
        return {**base, "switch_points": [], "structural_points": []}
    novelty_norm = (novelty - novelty.min()) / nov_rng

    # ── Stage 4: 4-bar phase offset detection ────────────────────────────────
    best_p, best_score = 0, -np.inf
    for p in range(_PERIOD):
        cands = np.arange(p, n_w, _PERIOD)
        score = float(np.dot(novelty_norm[cands], energy_norm[cands]))
        if score > best_score:
            best_score, best_p = score, p
    aligned = np.arange(best_p, n_w, _PERIOD)

    # ── Structural detection — runs for ALL tracks ────────────────────────────
    structural_points = _pick_structural(aligned, novelty_norm, energy_norm, strong)

    # ── Stage 5a: DJ search space — intro boundary ────────────────────────────
    _SAL_BAND     = 16
    _SAL_SUSTAIN  = 16
    threshold_e   = float(np.percentile(energy_norm, 75))
    salience_found = False
    salience_idx   = n_w

    if n_w >= _SAL_BAND + _SAL_SUSTAIN:
        rolling = np.convolve(energy_norm, np.ones(_SAL_BAND) / _SAL_BAND, mode="valid")
        above   = rolling >= threshold_e
        for i in range(len(above) - _SAL_SUSTAIN + 1):
            if np.all(above[i: i + _SAL_SUSTAIN]):
                salience_idx   = i
                salience_found = True
                break

    # No intro found — return structural points only
    if not salience_found or salience_idx < _PERIOD:
        return {**base, "switch_points": [], "structural_points": structural_points}

    # ── Stage 5b: peak-pick inside the intro ─────────────────────────────────
    intro_cands = aligned[aligned < salience_idx]
    if len(intro_cands) == 0:
        return {**base, "switch_points": [], "structural_points": structural_points}

    best_w    = int(intro_cands[np.argmax(novelty_norm[intro_cands])])
    time_sec  = float(strong[best_w])
    beat_idx  = best_w * 2

    # ── Post-detection guards ─────────────────────────────────────────────────
    estimated_duration = float(beats[-1]) + 60.0 / bpm
    if time_sec < 4.0 or beat_idx < 8:
        return {**base, "switch_points": [], "structural_points": structural_points}
    if time_sec > 0.30 * estimated_duration:
        return {**base, "switch_points": [], "structural_points": structural_points}

    return {
        **base,
        "switch_points": [{
            "time_sec":   round(time_sec, 3),
            "feature":    "energy",
            "novelty":    round(float(novelty_norm[best_w]), 4),
            "beat_index": beat_idx,
        }],
        "structural_points": structural_points,
    }


# ── Entry point ───────────────────────────────────────────────────────────────

def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "usage: essentia_cue.py <audio_file>"}))
        sys.stdout.flush()
        os._exit(1)

    path = sys.argv[1]
    try:
        bpm, beats, rms = _extract(path)
        result          = _detect(bpm, beats, rms)
        print(json.dumps(result))
        sys.stdout.flush()
        os._exit(0)
    except Exception as exc:
        print(json.dumps({"error": str(exc)}))
        sys.stdout.flush()
        os._exit(1)


if __name__ == "__main__":
    main()
