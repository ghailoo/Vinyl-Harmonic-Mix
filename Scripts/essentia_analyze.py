#!/usr/bin/env python3
"""
essentia_analyze.py <audio_file>

Prints ONE JSON line to stdout:
  {
    "bpm": 128.0, "key": "A", "scale": "minor", "key_strength": 0.78,
    "beats": [0.46, 0.93, ...],
    "beats_confidence": 0.95,
    "energy": {"rms": [0.03, 0.05, ...], "hop_size": 512, "frame_size": 2048, "sample_rate": 44100}
  }

The 4 original keys (bpm, key, scale, key_strength) are unchanged — same names, same values.
beats/energy are additive; existing consumers that read only the 4 original keys are unaffected.

Time of energy frame i: t = i * hop_size / sample_rate (seconds)
Time of beat i: beats[i] (seconds, from track start)

On any error:
  {"error": "description"}
  exit code 1
"""

import json
import os
import sys

_FRAME_SIZE = 2048
_HOP_SIZE   = 512
_SAMPLE_RATE = 44100


def analyze(path: str) -> dict:
    import essentia.standard as es

    loader = es.MonoLoader(filename=path, sampleRate=_SAMPLE_RATE)
    audio = loader()

    # BPM + beat positions. degara is faster; multifeature is more accurate on complex material.
    # Previously beats were discarded with _; now captured for cue-point detection downstream.
    rhythm = es.RhythmExtractor2013(method="degara")
    bpm, beats, beats_confidence, _, _ = rhythm(audio)

    # Key / scale / strength — Temperley profile is most accurate per Essentia docs.
    key_extractor = es.KeyExtractor(profileType="temperley")
    key, scale, strength = key_extractor(audio)

    # Per-frame RMS energy curve. Frame i covers audio[i*hop : i*hop+frame_size].
    # Time of frame i = i * _HOP_SIZE / _SAMPLE_RATE seconds.
    rms_algo = es.RMS()
    rms_values = [
        float(rms_algo(frame))
        for frame in es.FrameGenerator(
            audio, frameSize=_FRAME_SIZE, hopSize=_HOP_SIZE, startFromZero=True
        )
    ]

    return {
        # ---- original 4 keys: unchanged ----
        "bpm":          round(float(bpm), 2),
        "key":          key,
        "scale":        scale,
        "key_strength": round(float(strength), 4),
        # ---- new: beat grid ----
        "beats":            [round(float(t), 4) for t in beats],
        "beats_confidence": round(float(beats_confidence), 4),
        # ---- new: RMS energy curve ----
        "energy": {
            "rms":         [round(v, 6) for v in rms_values],
            "hop_size":    _HOP_SIZE,
            "frame_size":  _FRAME_SIZE,
            "sample_rate": _SAMPLE_RATE,
        },
    }


def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "usage: essentia_analyze.py <audio_file>"}))
        sys.stdout.flush()
        os._exit(1)

    path = sys.argv[1]
    try:
        result = analyze(path)
        print(json.dumps(result))
        sys.stdout.flush()
        os._exit(0)
    except Exception as exc:
        print(json.dumps({"error": str(exc)}))
        sys.stdout.flush()
        os._exit(1)


if __name__ == "__main__":
    main()
