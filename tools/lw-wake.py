#!/usr/bin/env python3
"""lw-wake — wake-word daemon for local-whisper.

Listens for a single spoken phrase ("hey mycroft" by default) and, on detection, tells
Hammerspoon to start a dictation exactly as a key-press would. It never transcribes and
never sees the dictation itself: it answers one yes/no question and gets out of the way.

Audio comes in as raw 16 kHz mono int16 on stdin, produced by `lw-record -`. That is
deliberate. ffmpeg's avfoundation input drops ~10% of the samples it is handed (see the
header of tools/lw-record.swift), and PortAudio would be a new brew dependency capturing
through a path this project has never verified. lw-record is the one capture already
proven here not to lose audio, so the daemon reuses it rather than opening its own device.

openWakeWord's default backend is tflite-runtime, which has no macOS build at all — pip
reports "No matching distribution found", which reads like a broken environment rather
than an unsupported platform. The onnx backend is forced below and must stay forced.

Detection is not transcription: the model is a ~860 KB binary classifier over a mel
spectrogram, not a decoder. It cannot invent words the way whisper does on short windows
of near-silence, which is exactly why whisper is the wrong tool for the always-on half of
this feature.
"""

import argparse
import collections
import os
import subprocess
import sys
import threading
import time

FRAME_SAMPLES = 1280          # 80 ms at 16 kHz — the frame size openWakeWord expects
FRAME_BYTES = FRAME_SAMPLES * 2

# Inference is skipped on frames quiet enough that nobody is speaking into the microphone.
# Measured on this machine: one paced frame costs 8.2 ms of CPU (2.3 ms back-to-back — the
# difference is real, a bursty background process runs on efficiency cores), so a working day
# that is mostly room noise pays for silence it need not evaluate.
#
# The gate must never clip the front of the phrase, so it does not simply drop quiet frames:
# it keeps the last PREROLL_FRAMES of them and replays that run-up into the model the moment
# the room gets loud. Without that the model would meet "hey mycroft" with an empty history
# and score it far below a phrase it had heard the approach to.
GATE_HOLD_FRAMES = 25         # ~2 s of inference after any sound crosses the gate
PREROLL_FRAMES = 13           # ~1 s of context replayed on the way in


# Firing goes through a hammerspoon:// URL, not the `hs` CLI. The CLI is a synchronous
# round-trip over a CFMessagePort to Hammerspoon's main thread, and it blocks for seconds
# exactly when this fires -- while Hammerspoon is busy starting a recording -- sometimes
# never returning at all ("CFMessagePort: dropping corrupt reply Mach message"). A URL open
# is delivered asynchronously by the system and returns immediately whether or not
# Hammerspoon has got to it yet.
#
# It still runs on a thread. `open` is a process spawn, and the read loop must never stall:
# lw-record keeps producing 80 ms frames throughout, so any stall makes the daemon deaf for
# its duration -- which is precisely when a user who saw nothing happen says the word again.
_firing = threading.Lock()


def fire(args, when):
    def run():
        if not _firing.acquire(blocking=False):
            log(args.log, "a trigger is still in flight, skipping this one")
            return
        try:
            # -g: do not bring Hammerspoon to the foreground, which would steal focus from
            # whatever the dictation is about to be typed into.
            subprocess.run(["/usr/bin/open", "-g", args.url], timeout=10,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except (OSError, subprocess.SubprocessError) as e:
            log(args.log, f"trigger failed: {e}")
        finally:
            _firing.release()
    threading.Thread(target=run, daemon=True).start()


def log(path, msg):
    line = time.strftime("%H:%M:%S") + " [wake] " + msg
    print(line, file=sys.stderr, flush=True)
    if path:
        try:
            with open(path, "a") as f:
                f.write(line + "\n")
        except OSError:
            pass          # a missing log directory must never take the daemon down


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="hey_mycroft")
    ap.add_argument("--threshold", type=float, default=0.5)
    # One utterance produces a run of frames over threshold, and the tail of the phrase
    # keeps scoring for a moment after the trigger fires. Without a refractory window a
    # single "hey mycroft" would start several dictations.
    ap.add_argument("--refractory", type=float, default=3.0)
    ap.add_argument("--url", default="hammerspoon://lw-voice-trigger")
    ap.add_argument("--log", default="")
    # Frame RMS below which the room counts as quiet. The noise floor on this machine measures
    # 15-19 and speech 400-700, so 40 sits clear of both. Deliberately permissive: a frame
    # evaluated needlessly costs 8 ms, a frame skipped wrongly costs a missed wake word.
    ap.add_argument("--gate-rms", type=float, default=40.0)
    # Prints every frame's score instead of firing. This is how the threshold gets tuned
    # against a real room rather than against the default in the documentation.
    ap.add_argument("--scores", action="store_true")
    args = ap.parse_args()

    import numpy as np
    from openwakeword.model import Model

    model = Model(wakeword_models=[args.model], inference_framework="onnx")
    log(args.log, f"loaded {args.model} (onnx), threshold={args.threshold}")

    stdin = sys.stdin.buffer
    last_fire = 0.0
    peak = 0.0
    preroll = collections.deque(maxlen=PREROLL_FRAMES)
    active = 0                # frames of inference still owed after the last loud frame
    gated = 0                 # skipped frames, for the periodic cost line

    while True:
        buf = b""
        while len(buf) < FRAME_BYTES:
            part = stdin.read(FRAME_BYTES - len(buf))
            if not part:
                log(args.log, "audio stream closed, exiting")
                return 0
            buf += part

        frame = np.frombuffer(buf, dtype=np.int16)

        # Energy gate. --scores bypasses it: tuning a threshold against a recording is the one
        # case where every frame must be evaluated, gate or no gate.
        if not args.scores:
            rms = float(np.sqrt(np.mean(np.square(frame.astype(np.float32)))))
            if rms >= args.gate_rms:
                if active == 0 and preroll:
                    # Coming out of silence: give the model the run-up it missed before
                    # judging the frame that woke the gate.
                    for old in preroll:
                        model.predict(old)
                    preroll.clear()
                active = GATE_HOLD_FRAMES
            if active == 0:
                preroll.append(frame)
                gated += 1
                continue
            active -= 1

        scores = model.predict(frame)
        score = float(scores.get(args.model, 0.0))

        if args.scores:
            peak = max(peak, score)
            if score > 0.05:
                print(f"{score:.3f}", flush=True)
            continue

        now = time.monotonic()
        if score >= args.threshold and (now - last_fire) >= args.refractory:
            last_fire = now
            log(args.log, f"DETECTED {args.model} score={score:.3f} -> {args.url}")
            # The model's internal feature buffer still holds the phrase that just fired.
            # Without this reset the following frames keep scoring high and the refractory
            # window becomes the only thing standing between one word and many triggers.
            model.reset()
            fire(args, last_fire)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)
