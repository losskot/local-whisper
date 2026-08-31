#!/usr/bin/env python3
"""
Port of Lua splitAtSilence / getWavRMS from hammerspoon/init.lua.
For each session directory, produces tmp/<session>/seg_NN.wav files
that exactly replicate what the app would send to whisper-cli.
"""
import sys, os, struct, glob, subprocess, math, json

FINAL_SEGMENT_SECS = 55
LOOKBACK_SECS = 8
FFMPEG = "/usr/local/bin/ffmpeg"
ARCHIVE = os.path.expanduser("~/.local-whisper/voice-archive")
TMP = os.path.join(os.path.dirname(__file__), "tmp")

SESSIONS = [
    "20260831_162820_g16",
    "20260831_175508_g23",
    "20260830_033027_g62",
    "20260829_030347_g4",
    "20260831_180501_g25",
    "20260830_022709_g38",
    "20260831_171450_g7",
    "20260830_031623_g54",
    "20260830_223738_g82",
    "20260831_175406_g22",
    "20260829_161020_g7",
    "20260830_022647_g37",
    "20260831_175627_g24",
    "20260830_042249_g73",
    "20260829_155540_g3",
]


def get_wav_rms(wav_path):
    try:
        with open(wav_path, "rb") as f:
            f.seek(44)  # skip standard WAV header
            data = f.read()
        if not data or len(data) < 2:
            return math.inf
        n = len(data) // 2
        samples = struct.unpack_from(f"<{n}h", data)
        rms = math.sqrt(sum(s * s for s in samples) / n) if n > 0 else math.inf
        return rms
    except Exception:
        return math.inf


def split_at_silence(chunks, max_secs, lookback_secs=LOOKBACK_SECS):
    groups = []
    i = 0
    while i < len(chunks):
        remaining = len(chunks) - i
        if remaining <= max_secs:
            groups.append(chunks[i:])
            break
        hard_end = i + max_secs - 1
        scan_start = max(i + max_secs // 2, hard_end - lookback_secs + 1)
        best_idx = hard_end
        best_rms = math.inf
        for j in range(hard_end, scan_start - 1, -1):
            rms = get_wav_rms(chunks[j])
            if rms < best_rms:
                best_rms = rms
                best_idx = j
                if rms < 300:
                    break
        groups.append(chunks[i : best_idx + 1])
        i = best_idx + 1
    return groups


def concat_wav(chunk_paths, out_wav):
    concat_list = out_wav + ".txt"
    with open(concat_list, "w") as f:
        for p in chunk_paths:
            f.write(f"file '{p}'\n")
    result = subprocess.run(
        [FFMPEG, "-y", "-f", "concat", "-safe", "0", "-i", concat_list, "-c", "copy", out_wav],
        capture_output=True,
    )
    os.unlink(concat_list)
    if result.returncode != 0:
        raise RuntimeError(f"ffmpeg failed: {result.stderr.decode()[:200]}")


def process_session(session):
    src = os.path.join(ARCHIVE, session)
    chunks = sorted(glob.glob(os.path.join(src, "chunk_*.wav")))
    if not chunks:
        print(f"  SKIP {session}: no chunks")
        return []

    groups = split_at_silence(chunks, FINAL_SEGMENT_SECS)
    out_dir = os.path.join(TMP, session)
    os.makedirs(out_dir, exist_ok=True)

    seg_paths = []
    for idx, group in enumerate(groups):
        seg_wav = os.path.join(out_dir, f"seg_{idx:02d}.wav")
        concat_wav(group, seg_wav)
        dur = len(group)
        print(f"  seg_{idx:02d}.wav  {dur} chunks ({dur:.1f}s)")
        seg_paths.append(seg_wav)
    return seg_paths


def main():
    targets = sys.argv[1:] if len(sys.argv) > 1 else SESSIONS
    manifest = {}
    for session in targets:
        print(f"\n[{session}]")
        segs = process_session(session)
        manifest[session] = segs

    manifest_path = os.path.join(TMP, "segments.json")
    with open(manifest_path, "w") as f:
        json.dump(manifest, f, indent=2)
    print(f"\nManifest written to {manifest_path}")


if __name__ == "__main__":
    main()
