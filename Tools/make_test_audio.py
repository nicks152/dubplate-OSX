#!/usr/bin/env python3
"""Generates the synthetic audio Dubplate is tested against.

Everything here is computed from first principles — sine tones, sweeps and noise —
so the repository contains no copyrighted recording of any kind.

    python3 Tools/make_test_audio.py            # the small committed set
    python3 Tools/make_test_audio.py --large    # adds the 5-minute and 45-minute files

The set covers what comes out of a DAW: 44.1 and 48 and 96 kHz, 16 and 24 bit,
mono and stereo. It also writes a gapless pair — two files that are consecutive
halves of one continuous tone — so a click at a track boundary is audible and
measurable rather than a matter of opinion.
"""

from __future__ import annotations

import argparse
import math
import os
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURES = os.path.join(ROOT, "Fixtures", "Audio")


def write_wav(path, samples, sample_rate, bit_depth, channels):
    """Writes interleaved float samples in [-1, 1] as a PCM WAV."""
    if bit_depth == 16:
        frame_format, sample_bytes, scale = "<h", 2, 32767
    elif bit_depth == 24:
        frame_format, sample_bytes, scale = None, 3, 8388607
    elif bit_depth == 32:
        frame_format, sample_bytes, scale = "<i", 4, 2147483647
    else:
        raise ValueError(f"unsupported bit depth {bit_depth}")

    body = bytearray()
    for value in samples:
        clamped = max(-1.0, min(1.0, value))
        quantised = int(round(clamped * scale))
        if sample_bytes == 3:
            quantised &= 0xFFFFFF
            body += bytes((quantised & 0xFF, (quantised >> 8) & 0xFF, (quantised >> 16) & 0xFF))
        else:
            body += struct.pack(frame_format, quantised)

    byte_rate = sample_rate * channels * sample_bytes
    block_align = channels * sample_bytes
    header = b"RIFF" + struct.pack("<I", 36 + len(body)) + b"WAVE"
    header += b"fmt " + struct.pack("<IHHIIHH", 16, 1, channels, sample_rate, byte_rate, block_align, bit_depth)
    header += b"data" + struct.pack("<I", len(body))

    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as handle:
        handle.write(header)
        handle.write(body)
    return len(header) + len(body)


def tone(frequency, seconds, sample_rate, channels, amplitude=0.5, phase=0.0):
    """A steady tone, with a short fade so the file does not start with a click."""
    total = int(seconds * sample_rate)
    fade = min(int(0.005 * sample_rate), total // 2)
    for frame in range(total):
        value = amplitude * math.sin(2 * math.pi * frequency * frame / sample_rate + phase)
        if frame < fade:
            value *= frame / fade
        elif frame >= total - fade:
            value *= (total - frame) / fade
        for channel in range(channels):
            # A little detuning on the right channel so stereo is audibly stereo.
            yield value if channel == 0 else value * 0.92


def sweep(start, end, seconds, sample_rate, channels, amplitude=0.4):
    total = int(seconds * sample_rate)
    for frame in range(total):
        progress = frame / total
        frequency = start * (end / start) ** progress
        value = amplitude * math.sin(2 * math.pi * frequency * frame / sample_rate)
        for _ in range(channels):
            yield value


def continuous_halves(frequency, seconds, sample_rate, channels, amplitude=0.5):
    """Two halves of one unbroken tone.

    No fades at the join: played back-to-back they are indistinguishable from one
    file, and any gap or click at the boundary is the player's fault.
    """
    total = int(seconds * sample_rate)
    half = total // 2
    for part in (range(half), range(half, total)):
        def frames(indices=part):
            for frame in indices:
                value = amplitude * math.sin(2 * math.pi * frequency * frame / sample_rate)
                for _ in range(channels):
                    yield value
        yield frames()


SMALL_SET = [
    ("01 Intro 44k1-16 mono.wav", 3.0, 44_100, 16, 1, 220.0),
    ("02 Dust 44k1-24 stereo.wav", 4.0, 44_100, 24, 2, 330.0),
    ("03 Midnight 48k-24 stereo.wav", 4.0, 48_000, 24, 2, 440.0),
    ("04 After Dark 96k-24 stereo.wav", 3.0, 96_000, 24, 2, 550.0),
    ("05 Untitled 48k-32 stereo.wav", 2.0, 48_000, 32, 2, 660.0),
]

LARGE_SET = [
    ("Long 30 seconds 48k-24 stereo.wav", 30.0, 48_000, 24, 2, 440.0),
    ("Long 5 minutes 48k-24 stereo.wav", 300.0, 48_000, 24, 2, 440.0),
    ("Long 45 minute mix 44k1-24 stereo.wav", 2_700.0, 44_100, 24, 2, 110.0),
]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--large", action="store_true", help="also write the multi-minute files")
    parser.add_argument("--out", default=FIXTURES)
    args = parser.parse_args()

    written = 0
    for name, seconds, rate, depth, channels, frequency in SMALL_SET:
        path = os.path.join(args.out, name)
        size = write_wav(path, tone(frequency, seconds, rate, channels), rate, depth, channels)
        written += size
        print(f"{name:44} {size / 1024:8.0f} KB")

    # A version of track 3, so version switching has something real to switch to.
    path = os.path.join(args.out, "03 Midnight mix 6 48k-24 stereo.wav")
    size = write_wav(path, sweep(200, 2_000, 4.0, 48_000, 2), 48_000, 24, 2)
    written += size
    print(f"{'03 Midnight mix 6 48k-24 stereo.wav':44} {size / 1024:8.0f} KB")

    for index, frames in enumerate(continuous_halves(440.0, 6.0, 48_000, 2), start=1):
        name = f"Gapless pair {index} of 2 48k-24 stereo.wav"
        size = write_wav(os.path.join(args.out, name), frames, 48_000, 24, 2)
        written += size
        print(f"{name:44} {size / 1024:8.0f} KB")

    if args.large:
        for name, seconds, rate, depth, channels, frequency in LARGE_SET:
            path = os.path.join(args.out, name)
            size = write_wav(path, tone(frequency, seconds, rate, channels), rate, depth, channels)
            written += size
            print(f"{name:44} {size / 1024 / 1024:8.1f} MB")

    print(f"\n{written / 1024 / 1024:.1f} MB written to {os.path.relpath(args.out, ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
