#!/usr/bin/env python3
"""
essentia_cue.py <audio_file>

Energy-only EXPERT cue-point detection.
(Zehren, Alunno, Bientinesi 2022 — "Automatic Detection of Cue Points for the Emulation
of DJ Mixing", Computer Music Journal — energy feature only, v1.)

Detects ONE switch-in point per track: the highest-novelty position inside the intro's
4-bar-aligned grid where a DJ would cleanly mix this track in.

Output JSON:
  {
    "switch_points": [{"time_sec": 16.42, "feature": "energy", "novelty": 0.73, "beat_index": 32}],
    "bpm": 124.0,
    "n_beats": 548
  }
  or {"switch_points": [], "bpm": ..., "n_beats": ...} on no detection (too short, no intro, etc.)

Error:
  {"error": "description"}   exit code 1

Pipeline (5 stages):
  1. Strong-beat grid:     beats[0,2,4,...] (every other beat = 2 per bar in 4/4)
  2. Energy per window:    per-frame RMS aggregated into each half-bar window; normalised 0..1
  3. Foote novelty:        1-D SSM + Gaussian-tapered 8-bar checkerboard kernel (zero-padded)
  4. 4-bar offset:         find phase p in [0..7] that maximises sum(novelty * energy) on 8-step grid
  5. Intro peak-pick:      restrict to intro (< first sustained-energy salience point),
                           take the aligned candidate with highest novelty
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


# ── Main detection pipeline ───────────────────────────────────────────────────

def _detect(bpm: float, beats: np.ndarray, rms: np.ndarray) -> dict:
    n_beats = len(beats)
    base    = {"bpm": round(bpm, 2), "n_beats": n_beats}

    if n_beats < _MIN_BEATS:
        return {**base, "switch_points": []}

    # ── Stage 1: strong beats ─────────────────────────────────────────────────
    strong = beats[::2]           # shape (n_strong,)
    n_w    = len(strong) - 1      # number of strong-beat windows

    if n_w < _PERIOD * 2:         # need at least 2 full 4-bar periods
        return {**base, "switch_points": []}

    # ── Stage 2: windowed energy, normalised 0..1 ─────────────────────────────
    energy = _window_energy(strong, rms)
    e_max  = energy.max()
    if e_max <= 0.0:
        return {**base, "switch_points": []}
    energy_norm = energy / e_max

    # ── Stage 3: Foote novelty, normalised 0..1 ───────────────────────────────
    novelty = _foote_novelty(energy_norm)
    nov_rng = novelty.max() - novelty.min()
    if nov_rng <= 0.0:
        return {**base, "switch_points": []}
    novelty_norm = (novelty - novelty.min()) / nov_rng

    # ── Stage 4: 4-bar phase offset detection ────────────────────────────────
    # Find offset p in [0, PERIOD) that maximises sum(novelty * energy) on the
    # period-aligned grid.  Weight by energy per the paper.
    best_p, best_score = 0, -np.inf
    for p in range(_PERIOD):
        cands = np.arange(p, n_w, _PERIOD)
        score = float(np.dot(novelty_norm[cands], energy_norm[cands]))
        if score > best_score:
            best_score, best_p = score, p
    aligned = np.arange(best_p, n_w, _PERIOD)

    # ── Stage 5a: DJ search space — intro boundary ────────────────────────────
    # Stricter energy-only salience: the rolling mean over a 16-strong-beat-window
    # band (≈ 8 bars) must exceed the track's 75th-percentile energy, sustained for
    # 16 consecutive windows.  Using the 75th pct (not median) and a wider sustain
    # window avoids firing on tracks that are simply loud throughout.
    _SAL_BAND     = 16   # rolling-mean window (strong-beat windows)
    _SAL_SUSTAIN  = 16   # how many consecutive windows must all exceed the threshold
    threshold_e   = float(np.percentile(energy_norm, 75))
    salience_found = False
    salience_idx   = n_w  # placeholder; only used if salience_found is True

    if n_w >= _SAL_BAND + _SAL_SUSTAIN:
        rolling = np.convolve(energy_norm, np.ones(_SAL_BAND) / _SAL_BAND, mode="valid")
        above   = rolling >= threshold_e
        for i in range(len(above) - _SAL_SUSTAIN + 1):
            if np.all(above[i: i + _SAL_SUSTAIN]):
                salience_idx   = i
                salience_found = True
                break

    # No salience boundary found → wall-to-wall energy, no real intro.
    # Treating the entire track as intro would let the peak-pick land anywhere.
    if not salience_found:
        return {**base, "switch_points": []}

    if salience_idx < _PERIOD:
        # Salience fires within the first full period → no usable intro
        return {**base, "switch_points": []}

    # ── Stage 5b: peak-pick inside the intro ─────────────────────────────────
    intro_cands = aligned[aligned < salience_idx]
    if len(intro_cands) == 0:
        return {**base, "switch_points": []}

    best_w    = int(intro_cands[np.argmax(novelty_norm[intro_cands])])
    time_sec  = float(strong[best_w])
    beat_idx  = best_w * 2        # strong-beat window i → original beat index 2i

    # ── Post-detection guards ─────────────────────────────────────────────────
    # 1. Minimum: first 4 bars is not a usable mix-in point.
    if time_sec < 4.0 or beat_idx < 8:
        return {**base, "switch_points": []}

    # 2. Maximum: intro must fall within the first 30% of the track.
    #    Proxy for track duration: last beat time + one beat length.
    estimated_duration = float(beats[-1]) + 60.0 / bpm
    if time_sec > 0.30 * estimated_duration:
        return {**base, "switch_points": []}

    return {
        **base,
        "switch_points": [{
            "time_sec":   round(time_sec, 3),
            "feature":    "energy",
            "novelty":    round(float(novelty_norm[best_w]), 4),
            "beat_index": beat_idx,
        }],
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
