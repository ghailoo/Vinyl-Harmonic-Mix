#!/usr/bin/env python3
"""
essentia_cue.py <audio_file>

Four-to-floor gated cue-point detection (v2.0).

Detects TWO classes of cue points per track:

  switch_points  — ONE intro mix-in point (energy novelty, unchanged).
  structural_points — up to _STRUCT_MAX section-boundary points.

Gate: HPSS soft-mask → full-band SuperFlux → inter-onset regularity.
  four_to_floor=True  → two-feature path: energy + kick novelty merged.
  four_to_floor=False → energy-only path: no kick feature, no false positives.

Output JSON:
  {
    "bpm": 124.0,
    "n_beats": 548,
    "four_to_floor": true,
    "kick_regularity": 0.85,
    "switch_points":     [{"time_sec": 16.42, "feature": "energy",
                           "novelty": 0.73, "beat_index": 32}],
    "structural_points": [{"time_sec": 48.5, "novelty": 0.91,
                           "beat_index": 96, "energy_direction": "rise",
                           "energy_delta": 0.31, "source": "both"}, ...]
  }

  source field: "energy" | "kick" | "both"
  On energy-only tracks (four_to_floor=false) all structural points have source="energy".

Error:
  {"error": "description"}   exit code 1
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
_MERGE_TOLERANCE     = 2    # windows — energy + kick picks within this are the same boundary

# Energy-direction labeling
_DIR_WINDOW  = 4    # windows on each side of boundary for mean comparison (= 2 bars)
_DIR_EPSILON = 0.05 # minimum energy difference (normalised) to assign direction

# Four-to-floor gate (validated: 92% accuracy, 0 false enables on vocal/pop tracks)
# Spike data: house/techno ≥80%, vocal/pop ≤14%; threshold=50% gives 36-pt safety margin.
_FTF_REGULARITY_THRESHOLD = 0.50   # min fraction of kick gaps within ±_FTF_BEAT_WINDOW of beat_dur
_FTF_MIN_ONSETS           = 20     # min total kick onsets for a valid gate reading
_FTF_BEAT_WINDOW          = 0.20   # ±20% of beat_dur counts as "regular"
_HPSS_T                   = 21     # HPSS time-axis median kernel (harmonic smoothing, frames)
_HPSS_F                   = 21     # HPSS freq-axis median kernel (percussive spreading, bins)


# ── Feature extraction ───────────────────────────────────────────────────────

def _extract(path: str):
    """
    Load audio at 44.1 kHz mono.
    - RhythmExtractor2013 (degara) for beats.
    - FrameGenerator+RMS for the per-frame energy curve.
    Returns (audio, bpm, beats, rms_curve).
    Kick onsets are computed separately via the FTF gate (_ftf_gate).
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

    return (audio,
            float(bpm),
            np.asarray(beats, dtype=np.float64),
            rms_curve)


# ── HPSS soft-mask percussive separation ─────────────────────────────────────

def _hpss_soft_percussive(audio: np.ndarray) -> np.ndarray:
    """
    Fitzgerald HPSS with Wiener soft mask (numpy only, no scipy/librosa).
    Returns percussive-component audio at full bandwidth.

    Algorithm:
      1. Vectorised STFT (numpy rfft)
      2. Median-filter magnitude along TIME axis  → harmonic component H
      3. Median-filter magnitude along FREQ axis  → percussive component P
      4. Wiener soft mask: P² / (H² + P² + ε) per (freq, frame) bin
      5. ISTFT via irfft + WOLA (Hann synthesis window)
    """
    n    = len(audio)
    hann = np.hanning(_FRAME_SIZE).astype(np.float32)
    nf   = (n - _FRAME_SIZE) // _HOP_SIZE + 1
    if nf < 2:
        return audio

    # Vectorised STFT
    view     = np.lib.stride_tricks.sliding_window_view(
                   np.pad(audio, (0, _FRAME_SIZE), mode='constant'), _FRAME_SIZE)
    windowed = (view[np.arange(nf) * _HOP_SIZE] * hann).astype(np.float32)
    stft     = np.fft.rfft(windowed, axis=1)           # (nf, n_freq)
    S        = np.abs(stft).T.astype(np.float32)        # (n_freq, nf)

    # Harmonic: median along time axis
    pt = _HPSS_T // 2
    H  = np.median(
             np.lib.stride_tricks.sliding_window_view(
                 np.pad(S, ((0, 0), (pt, pt)), mode='edge'),
                 _HPSS_T, axis=1),
             axis=-1)  # (n_freq, nf)

    # Percussive: median along freq axis
    pf = _HPSS_F // 2
    P  = np.median(
             np.lib.stride_tricks.sliding_window_view(
                 np.pad(S, ((pf, pf), (0, 0)), mode='edge'),
                 _HPSS_F, axis=0),
             axis=-1)  # (n_freq, nf)

    # Wiener soft mask: P² / (H² + P² + ε)
    soft = P * P / (H * H + P * P + 1e-8)             # (n_freq, nf)

    # ISTFT via irfft + WOLA synthesis
    tf  = np.fft.irfft(stft * soft.T, n=_FRAME_SIZE, axis=1).astype(np.float32)
    out = np.zeros((nf - 1) * _HOP_SIZE + _FRAME_SIZE, np.float64)
    nrm = np.zeros_like(out)
    h64 = hann.astype(np.float64)
    h2  = (hann * hann).astype(np.float64)
    for i in range(nf):
        s = i * _HOP_SIZE
        out[s:s + _FRAME_SIZE] += tf[i] * h64
        nrm[s:s + _FRAME_SIZE] += h2
    out = np.where(nrm > 1e-10, out / nrm, 0.0).astype(np.float32)[:n]
    pk  = np.abs(out).max()
    return out / pk * 0.9 if pk > 1e-6 else out


# ── Four-to-floor gate ────────────────────────────────────────────────────────

def _ftf_gate(audio: np.ndarray, bpm: float):
    """
    Four-to-floor gate: HPSS soft-mask → full-band SuperFlux → regularity.

    Returns (four_to_floor, kick_regularity, n_kick_onsets, kick_onset_times).

    Validated (ftf_gate_validate.py):
      house/techno regularity ≥ 80%  →  threshold=50% has a 36-pt safety margin
      vocal/pop    regularity ≤ 14%  →  0 false enables across 6 test tracks
    """
    import essentia.standard as es

    perc   = _hpss_soft_percussive(audio)
    onsets = np.asarray(
        es.SuperFluxExtractor(frameSize=_FRAME_SIZE, hopSize=_HOP_SIZE,
                              sampleRate=_SAMPLE_RATE)(perc),
        dtype=np.float64)
    n = len(onsets)

    if n < 2:
        return False, 0.0, n, onsets

    beat_dur   = 60.0 / bpm if bpm > 0 else 0.48
    gaps       = np.diff(np.sort(onsets))
    n_regular  = int(np.sum(np.abs(gaps - beat_dur) <= beat_dur * _FTF_BEAT_WINDOW))
    regularity = n_regular / len(gaps)

    four_to_floor = (regularity >= _FTF_REGULARITY_THRESHOLD) and (n >= _FTF_MIN_ONSETS)
    return four_to_floor, round(regularity, 3), n, onsets


# ── Stage 2a: energy per strong-beat window ──────────────────────────────────

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


# ── Stage 2b: kick-onset density per strong-beat window ──────────────────────

def _kick_density_curve(onset_times: np.ndarray, strong: np.ndarray) -> np.ndarray:
    """
    Count bass-drum onsets in each strong-beat window, divided by window
    duration (seconds) → onset density (events/sec).  Returns shape (n_windows,).
    """
    n = len(strong) - 1
    density = np.zeros(n, dtype=np.float64)
    if len(onset_times) == 0:
        return density
    for i in range(n):
        t0, t1 = float(strong[i]), float(strong[i + 1])
        dur = t1 - t0
        if dur <= 0:
            continue
        density[i] = float(np.sum((onset_times >= t0) & (onset_times < t1))) / dur
    return density


# ── Stage 3: Foote checkerboard novelty ──────────────────────────────────────

def _foote_novelty(energy_norm: np.ndarray) -> np.ndarray:
    """
    1-D self-similarity matrix + Gaussian-tapered checkerboard kernel.
    Zero-padded at both ends by K windows so intro positions receive full
    kernel context (the paper's recommended treatment for the DJ search space).

    SSM[i,j] = 1 - |energy_norm[i] - energy_norm[j]|   (similarity in [0,1])
    Checkerboard: +1 in top-left and bottom-right quadrants, -1 in cross quadrants.
    Gaussian taper with sigma = K/2.
    Accepts any normalised 1-D curve (energy or kick density).
    """
    K  = _KERNEL_HALF
    ks = 2 * K

    padded = np.concatenate([np.zeros(K), energy_norm, np.zeros(K)])
    N = len(padded)

    SSM = 1.0 - np.abs(padded[:, None] - padded[None, :])

    idx    = np.arange(ks, dtype=np.float64) - K + 0.5
    gx, gy = np.meshgrid(idx, idx)
    sigma  = K / 2.0
    gauss  = np.exp(-(gx ** 2 + gy ** 2) / (2.0 * sigma ** 2))
    sign   = np.ones((ks, ks), dtype=np.float64)
    sign[:K, K:] = -1.0
    sign[K:, :K] = -1.0
    kernel = gauss * sign

    novelty_full = np.zeros(N, dtype=np.float64)
    for n in range(K, N - K):
        block = SSM[n - K: n + K, n - K: n + K]
        novelty_full[n] = float(np.sum(kernel * block))

    return novelty_full[K: K + len(energy_norm)]


# ── Structural peak-picking (two-feature merge) ───────────────────────────────

def _pick_structural(aligned: np.ndarray,
                     novelty_energy: np.ndarray, novelty_kick: np.ndarray,
                     energy_norm: np.ndarray, strong: np.ndarray) -> list:
    """
    Two-feature greedy peak-pick.

    1. Each novelty curve (energy, kick) is peak-picked independently with the
       same threshold + spacing.  No cap at this stage.
    2. Candidates are merged into a pool {window → (best_novelty, source)}.
       Pairs within _MERGE_TOLERANCE windows are deduplicated: the higher-novelty
       position is kept and labelled "both".
    3. A final greedy pass (descending novelty, spacing, cap) selects the best
       _STRUCT_MAX boundaries from the merged pool.
    4. Energy direction + delta are always computed from energy_norm.
    """
    n_w = len(energy_norm)

    def _greedy(nov):
        """Independent greedy pick from one novelty curve (no cap)."""
        scores = nov[aligned]
        order  = aligned[np.argsort(scores)[::-1]]
        picks  = []
        for w in order:
            if float(nov[w]) < _STRUCT_THRESHOLD:
                break
            if float(strong[w]) < _STRUCT_MIN_TIME_SEC:
                continue
            if all(abs(int(w) - p) >= _STRUCT_MIN_SPACING for p in picks):
                picks.append(int(w))
        return picks

    energy_cands = set(_greedy(novelty_energy))
    kick_cands   = set(_greedy(novelty_kick))

    # Build merged pool {w: (novelty_score, source)}
    pool = {}
    for w in energy_cands:
        pool[w] = (float(novelty_energy[w]), "energy")

    for w in kick_cands:
        close = [m for m in pool if abs(int(w) - int(m)) <= _MERGE_TOLERANCE]
        if close:
            m  = min(close, key=lambda m: abs(int(w) - int(m)))
            nk = float(novelty_kick[w])
            nm = pool[m][0]
            if nk > nm:
                # kick position has stronger novelty — move to kick's window, mark "both"
                del pool[m]
                pool[w] = (nk, "both")
            else:
                # energy position wins — keep it, just mark "both"
                pool[m] = (nm, "both")
        else:
            pool[w] = (float(novelty_kick[w]), "kick")

    # Final greedy pass: sort by novelty desc, enforce spacing, apply cap
    sorted_pool = sorted(pool.items(), key=lambda x: -x[1][0])
    picked = []
    for w, _ in sorted_pool:
        if all(abs(int(w) - p) >= _STRUCT_MIN_SPACING for p in picked):
            picked.append(int(w))
        if len(picked) >= _STRUCT_MAX:
            break
    picked.sort()

    result = []
    for w in picked:
        nov_score, source = pool[w]
        before = energy_norm[max(0, w - _DIR_WINDOW): w]
        after  = energy_norm[w: min(n_w, w + _DIR_WINDOW)]
        bm = float(np.mean(before)) if len(before) > 0 else 0.0
        am = float(np.mean(after))  if len(after)  > 0 else 0.0

        if   am > bm + _DIR_EPSILON: direction = "rise"
        elif bm > am + _DIR_EPSILON: direction = "fall"
        else:                        direction = "neutral"

        result.append({
            "time_sec":         round(float(strong[w]), 3),
            "novelty":          round(nov_score, 4),
            "beat_index":       w * 2,
            "energy_direction": direction,
            "energy_delta":     round(abs(am - bm), 2),
            "source":           source,
        })

    return result


# ── Energy-only structural peak-picking ──────────────────────────────────────

def _pick_structural_energy_only(aligned: np.ndarray, novelty_energy: np.ndarray,
                                  energy_norm: np.ndarray, strong: np.ndarray) -> list:
    """
    Single-feature greedy peak-pick from energy novelty only.
    Used for non-four-to-floor tracks. All structural points get source="energy".
    Identical algorithm to _pick_structural but for one curve with no merge step.
    """
    n_w    = len(energy_norm)
    scores = novelty_energy[aligned]
    order  = aligned[np.argsort(scores)[::-1]]
    picks  = []
    for w in order:
        if float(novelty_energy[w]) < _STRUCT_THRESHOLD:
            break
        if float(strong[w]) < _STRUCT_MIN_TIME_SEC:
            continue
        if all(abs(int(w) - p) >= _STRUCT_MIN_SPACING for p in picks):
            picks.append(int(w))
        if len(picks) >= _STRUCT_MAX:
            break
    picks.sort()

    result = []
    for w in picks:
        nov_score = float(novelty_energy[w])
        before = energy_norm[max(0, w - _DIR_WINDOW): w]
        after  = energy_norm[w: min(n_w, w + _DIR_WINDOW)]
        bm = float(np.mean(before)) if len(before) > 0 else 0.0
        am = float(np.mean(after))  if len(after)  > 0 else 0.0

        if   am > bm + _DIR_EPSILON: direction = "rise"
        elif bm > am + _DIR_EPSILON: direction = "fall"
        else:                        direction = "neutral"

        result.append({
            "time_sec":         round(float(strong[w]), 3),
            "novelty":          round(nov_score, 4),
            "beat_index":       w * 2,
            "energy_direction": direction,
            "energy_delta":     round(abs(am - bm), 2),
            "source":           "energy",
        })
    return result


# ── Main detection pipeline ───────────────────────────────────────────────────

def _detect(bpm: float, beats: np.ndarray, rms: np.ndarray,
            four_to_floor: bool, kick_onset_times: np.ndarray) -> dict:
    n_beats = len(beats)
    base    = {"bpm": round(bpm, 2), "n_beats": n_beats}

    if n_beats < _MIN_BEATS:
        return {**base, "switch_points": [], "structural_points": []}

    # ── Stage 1: strong beats ─────────────────────────────────────────────────
    strong = beats[::2]
    n_w    = len(strong) - 1

    if n_w < _PERIOD * 2:
        return {**base, "switch_points": [], "structural_points": []}

    # ── Stage 2a: windowed energy, normalised 0..1 ────────────────────────────
    energy = _window_energy(strong, rms)
    e_max  = energy.max()
    if e_max <= 0.0:
        return {**base, "switch_points": [], "structural_points": []}
    energy_norm = energy / e_max

    # ── Stage 3: Foote novelty on energy, normalised 0..1 ────────────────────
    novelty_e = _foote_novelty(energy_norm)
    ne_rng = novelty_e.max() - novelty_e.min()
    if ne_rng <= 0.0:
        return {**base, "switch_points": [], "structural_points": []}
    novelty_energy_norm = (novelty_e - novelty_e.min()) / ne_rng

    # ── Stage 4: 4-bar phase offset (energy-driven) ───────────────────────────
    best_p, best_score = 0, -np.inf
    for p in range(_PERIOD):
        cands = np.arange(p, n_w, _PERIOD)
        score = float(np.dot(novelty_energy_norm[cands], energy_norm[cands]))
        if score > best_score:
            best_score, best_p = score, p
    aligned = np.arange(best_p, n_w, _PERIOD)

    # ── Structural detection: two-feature (four-to-floor) or energy-only ──────
    if four_to_floor:
        # Stage 2b: kick-onset density per window, from HPSS-gated onsets
        kick_density = _kick_density_curve(kick_onset_times, strong)
        kd_max = kick_density.max()
        kick_norm = kick_density / kd_max if kd_max > 0.0 else energy_norm.copy()

        novelty_k = _foote_novelty(kick_norm)
        nk_rng = novelty_k.max() - novelty_k.min()
        novelty_kick_norm = (novelty_k - novelty_k.min()) / nk_rng if nk_rng > 0.0 \
                            else novelty_energy_norm.copy()

        structural_points = _pick_structural(
            aligned, novelty_energy_norm, novelty_kick_norm, energy_norm, strong
        )
    else:
        # Energy-only: no kick density, no kick novelty, source="energy" on all points
        structural_points = _pick_structural_energy_only(
            aligned, novelty_energy_norm, energy_norm, strong
        )

    # ── Stage 5a: DJ search space — intro boundary (energy only) ─────────────
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

    if not salience_found or salience_idx < _PERIOD:
        return {**base, "switch_points": [], "structural_points": structural_points}

    # ── Stage 5b: peak-pick inside the intro (energy only) ───────────────────
    intro_cands = aligned[aligned < salience_idx]
    if len(intro_cands) == 0:
        return {**base, "switch_points": [], "structural_points": structural_points}

    best_w   = int(intro_cands[np.argmax(novelty_energy_norm[intro_cands])])
    time_sec = float(strong[best_w])
    beat_idx = best_w * 2

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
            "novelty":    round(float(novelty_energy_norm[best_w]), 4),
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
        audio, bpm, beats, rms = _extract(path)
        four_to_floor, kick_regularity, _n_kick, kick_onsets = _ftf_gate(audio, bpm)
        result = _detect(bpm, beats, rms, four_to_floor, kick_onsets)
        result["four_to_floor"]   = four_to_floor
        result["kick_regularity"] = kick_regularity
        print(json.dumps(result))
        sys.stdout.flush()
        os._exit(0)
    except Exception as exc:
        print(json.dumps({"error": str(exc)}))
        sys.stdout.flush()
        os._exit(1)


if __name__ == "__main__":
    main()
