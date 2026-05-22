#!/usr/bin/env python3
"""
essentia_analyze.py <audio_file>

Prints ONE JSON line to stdout:
  {"bpm": 128.0, "key": "A", "scale": "minor", "key_strength": 0.78}

On any error:
  {"error": "description"}
  exit code 1
"""

import json
import sys


def analyze(path: str) -> dict:
    import essentia.standard as es

    loader = es.MonoLoader(filename=path, sampleRate=44100)
    audio = loader()

    # BPM — degara is faster; multifeature is more accurate on complex material.
    # degara is the default and good enough for the majority of music.
    rhythm = es.RhythmExtractor2013(method="degara")
    bpm, _, _, _, _ = rhythm(audio)

    # Key / scale / strength — Temperley profile is most accurate per Essentia docs.
    key_extractor = es.KeyExtractor(profileType="temperley")
    key, scale, strength = key_extractor(audio)

    return {
        "bpm": round(float(bpm), 2),
        "key": key,
        "scale": scale,
        "key_strength": round(float(strength), 4),
    }


def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "usage: essentia_analyze.py <audio_file>"}))
        sys.exit(1)

    path = sys.argv[1]
    try:
        result = analyze(path)
        print(json.dumps(result))
    except Exception as exc:
        print(json.dumps({"error": str(exc)}))
        sys.exit(1)


if __name__ == "__main__":
    main()
