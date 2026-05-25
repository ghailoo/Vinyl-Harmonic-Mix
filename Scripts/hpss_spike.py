#!/usr/bin/env python3
"""
SPIKE: HPSS-based kick-onset detection vs current LowPass-only method.
NOT for integration — test only. Does NOT touch essentia_cue.py.

Fitzgerald HPSS (2010) implemented from scratch with numpy (no scipy/librosa):
  1. Vectorized STFT via numpy rfft
  2. Median filter along TIME axis  → harmonic component H
  3. Median filter along FREQ axis  → percussive component P
  4. Binary mask: percussive wins where P >= H
  5. ISTFT via numpy irfft + overlap-add synthesis
  6. LowPass(150 Hz) on percussive audio
  7. SuperFlux onset detection
"""

import sys
import time
import numpy as np
import essentia.standard as es

# ── shared constants (match essentia_cue.py) ──────────────────────────────
_SR      = 44100
_FRAME   = 2048
_HOP     = 512
_LP_HZ   = 150.0

# ── HPSS kernel sizes ─────────────────────────────────────────────────────
# Time kernel (odd): larger = more harmonic smoothing; 21 frames @ hop=512 ≈ 0.24 s
# Freq kernel (odd): larger = more percussive broadening; 21 bins @ 2048 FFT ≈ 450 Hz
_HPSS_T  = 21
_HPSS_F  = 21


# ═══════════════════════════════════════════════════════════════════════════
# Core routines
# ═══════════════════════════════════════════════════════════════════════════

def load_audio(path: str) -> np.ndarray:
    return es.MonoLoader(filename=path, sampleRate=_SR)()


def method_old(audio: np.ndarray) -> np.ndarray:
    """Current pipeline: LowPass → SuperFlux."""
    lp = es.LowPass(cutoffFrequency=_LP_HZ, sampleRate=_SR)(audio)
    return np.asarray(
        es.SuperFluxExtractor(frameSize=_FRAME, hopSize=_HOP, sampleRate=_SR)(lp),
        dtype=np.float32
    )


def hpss_percussive(audio: np.ndarray) -> np.ndarray:
    """
    Return the percussive component of 'audio' via Fitzgerald HPSS.
    All numpy, no scipy/librosa needed.
    """
    n      = len(audio)
    hann   = np.hanning(_FRAME).astype(np.float32)

    # ── 1. Vectorized STFT ────────────────────────────────────────────────
    n_frames = max(0, (n - _FRAME) // _HOP + 1)
    view     = np.lib.stride_tricks.sliding_window_view(
                   np.pad(audio, (0, _FRAME), mode='constant'), _FRAME)
    windowed = (view[np.arange(n_frames) * _HOP] * hann).astype(np.float32)
    stft     = np.fft.rfft(windowed, axis=1)          # (n_frames, n_freq)
    S        = np.abs(stft).T.astype(np.float32)       # (n_freq,   n_frames)

    # ── 2. HPSS: median filter in time → H, in freq → P ──────────────────
    pad_t = _HPSS_T // 2
    pad_f = _HPSS_F // 2

    S_pt = np.pad(S, ((0, 0), (pad_t, pad_t)), mode='edge')
    H    = np.median(
               np.lib.stride_tricks.sliding_window_view(S_pt, _HPSS_T, axis=1),
               axis=-1
           )  # (n_freq, n_frames)

    S_pf = np.pad(S, ((pad_f, pad_f), (0, 0)), mode='edge')
    P    = np.median(
               np.lib.stride_tricks.sliding_window_view(S_pf, _HPSS_F, axis=0),
               axis=-1
           )  # (n_freq, n_frames)

    # ── 3. Binary percussive mask ─────────────────────────────────────────
    perc_mask = (P >= H).astype(np.float32)            # (n_freq, n_frames)

    # ── 4. ISTFT: mask the spectrum, reconstruct via irfft + OLA ─────────
    masked_stft  = (stft * perc_mask.T).astype(np.complex64)   # (n_frames, n_freq)
    time_frames  = np.fft.irfft(masked_stft, n=_FRAME, axis=1).astype(np.float32)

    # Synthesis with Hann window (WOLA); norm = sum(hann²) per sample
    out_len = (n_frames - 1) * _HOP + _FRAME
    output  = np.zeros(out_len, dtype=np.float64)
    norm    = np.zeros(out_len, dtype=np.float64)
    hann64  = hann.astype(np.float64)
    hann2   = (hann * hann).astype(np.float64)

    for i in range(n_frames):
        s = i * _HOP
        output[s:s + _FRAME] += time_frames[i] * hann64
        norm  [s:s + _FRAME] += hann2

    eps     = 1e-10
    output  = np.where(norm > eps, output / norm, 0.0).astype(np.float32)
    output  = output[:n]

    # Normalize amplitude so LowPass / SuperFlux operate on a sane scale
    peak = np.abs(output).max()
    if peak > 1e-6:
        output *= 0.9 / peak

    return output


def method_new(audio: np.ndarray) -> np.ndarray:
    """New pipeline: HPSS percussive → LowPass → SuperFlux."""
    perc = hpss_percussive(audio)
    lp   = es.LowPass(cutoffFrequency=_LP_HZ, sampleRate=_SR)(perc)
    return np.asarray(
        es.SuperFluxExtractor(frameSize=_FRAME, hopSize=_HOP, sampleRate=_SR)(lp),
        dtype=np.float32
    )


# ═══════════════════════════════════════════════════════════════════════════
# Reporting helpers
# ═══════════════════════════════════════════════════════════════════════════

def fmt(sec: float) -> str:
    s = max(0, int(round(sec)))
    return f"{s // 60}:{s % 60:02d}"


def nearby_onsets(onsets: np.ndarray, center: float, margin: float = 3.0) -> list:
    mask = (onsets >= center - margin) & (onsets <= center + margin)
    return onsets[mask].tolist()


def analyze(path: str, name: str, fp_checks: list[tuple[float, str]]) -> None:
    """
    fp_checks: list of (time_sec, description) known false-positive spots.
    """
    print(f"\n{'═'*64}")
    print(f"  {name}")
    print(f"{'═'*64}")

    audio    = load_audio(path)
    duration = len(audio) / _SR
    print(f"  Duration: {fmt(duration)} ({duration:.1f}s)")

    # ── OLD ───────────────────────────────────────────────────────────────
    t0  = time.time()
    old = method_old(audio)
    dt_old = time.time() - t0
    print(f"\n  OLD  (LP→SF):        {len(old):4d} onsets  [{dt_old:.1f}s]")

    # ── NEW ───────────────────────────────────────────────────────────────
    t0  = time.time()
    new = method_new(audio)
    dt_new = time.time() - t0
    print(f"  NEW  (HPSS+LP→SF):  {len(new):4d} onsets  [{dt_new:.1f}s]")

    # ── Per-60s bucket density ────────────────────────────────────────────
    WIN = 60.0
    n_win = int(np.ceil(duration / WIN))
    print(f"\n  Density per {int(WIN)}s window   OLD / NEW")
    for w in range(n_win):
        t_a, t_b = w * WIN, min((w + 1) * WIN, duration)
        n_old = int(np.sum((old >= t_a) & (old < t_b)))
        n_new = int(np.sum((new >= t_a) & (new < t_b)))
        bar_o = '▓' * (n_old // 10)
        bar_n = '▓' * (n_new // 10)
        print(f"    {fmt(t_a)}-{fmt(t_b)}: {n_old:4d} {bar_o:<12} {n_new:4d} {bar_n}")

    # ── False-positive checks ─────────────────────────────────────────────
    if fp_checks:
        print(f"\n  False-positive checks (±3 s window):")
        MARGIN = 3.0
        for tc, label in fp_checks:
            o_near = nearby_onsets(old, tc, MARGIN)
            n_near = nearby_onsets(new, tc, MARGIN)
            delta  = len(n_near) - len(o_near)
            if delta < -len(o_near) * 0.4:
                verdict = "✓ CLEANED"
            elif delta < 0:
                verdict = "~ REDUCED"
            elif delta == 0:
                verdict = "= SAME"
            else:
                verdict = "↑ WORSE"
            print(f"    {fmt(tc)} [{label}]")
            print(f"      OLD {len(o_near):3d} onsets  times: {[fmt(t) for t in sorted(o_near)]}")
            print(f"      NEW {len(n_near):3d} onsets  times: {[fmt(t) for t in sorted(n_near)]}  → {verdict}")


# ═══════════════════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════════════════

if __name__ == "__main__":
    FELIX = (
        "/Volumes/Music/Tracks/Felix"
        "/1992 - Don't You Want Me (Original Mixes And Remixes) (Europe CDS) (1992) - 74321 11050 2"
        "/01. Felix - Don't You Want Me (Hooj Mix Edit).flac"
    )
    MJ = (
        "/Volumes/Music/Tracks/Michael Jackson"
        "/Michael Jackson - Smooth Criminal. Remixes Vol.1"
        "/Michael Jackson - Smooth Criminal (2006 Electro Remix).mp3"
    )
    PJANOO = (
        "/Volumes/Music/Tracks/Eric Prydz"
        "/2008 Eric Prydz - Pjanoo [DIGI0229] WEB"
        "/01 Eric Prydz - Pjanoo (Radio Edit).mp3"
    )

    analyze(
        FELIX,
        "Felix – Don't You Want Me (Hooj Mix Edit)",
        fp_checks=[
            (76.0,  "1:16 bass-note FP"),
            (114.0, "1:54 bass-note FP"),
            (151.0, "2:31 bass-note FP"),
        ]
    )

    analyze(
        MJ,
        "MJ – Smooth Criminal (2006 Electro Remix)",
        fp_checks=[
            (119.0, "1:59 bass-note FP"),
        ]
    )

    analyze(
        PJANOO,
        "Eric Prydz – Pjanoo (Radio Edit)  [four-to-floor, real kicks must survive]",
        fp_checks=[]
    )

    print("\nDone.")
