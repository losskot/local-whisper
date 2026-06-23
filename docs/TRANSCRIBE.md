# transcribe.sh — Batch Audio/Video Transcription

Bash script for batch transcription of audio and video files using [whisper.cpp](https://github.com/ggerganov/whisper.cpp) with the **large-v3-turbo** model.

## Requirements

| Dependency | Purpose | Install |
|---|---|---|
| `whisper-cli` | Transcription engine | Built from `~/whisper.cpp` |
| `ffmpeg` | Convert non-native formats | `brew install ffmpeg` |

The script expects:
- `~/whisper.cpp/build/bin/whisper-cli` — whisper binary
- `~/whisper.cpp/models/ggml-large-v3-turbo-q5_0.bin` — default model

## Usage

```
./tools/transcribe.sh [OPTIONS] FILE|DIR [FILE|DIR ...]
```

## Options

| Flag | Argument | Default | Description |
|------|----------|---------|-------------|
| `-m` | MODEL | `large-v3-turbo-q5_0` | Model path or name (see [Models](#models)) |
| `-l` | LANG | `auto` | Language code (`en`, `ru`, `fr`, `auto`, …) |
| `-f` | FORMAT | `txt` | Output format (see [Output formats](#output-formats)) |
| `-o` | DIR | same as input | Directory to write output files |
| `-t` | N | auto | Number of CPU threads |
| `-T` | — | off | Translate to English |
| `-p` | PROMPT | — | Initial prompt to guide transcription style |
| `-n` | — | off | Omit timestamps from plain-text output |
| `-r` | — | off | Recurse into sub-directories |
| `-h` | — | — | Show help and exit |

## Supported Formats

### Native (no conversion)
`flac` · `mp3` · `ogg` · `wav`

### Via ffmpeg (converted to 16 kHz mono WAV internally)
| Category | Formats |
|----------|---------|
| Apple / AAC | `m4a` `m4b` `aac` `caf` |
| Video containers | `mp4` `mov` `mkv` `webm` `avi` `flv` `vob` `mxf` `dv` |
| Windows / WMA | `wma` `wmv` `asf` |
| Broadcast / TS | `ts` `mts` `m2ts` `m2t` |
| Opus / Ogg variants | `opus` `oga` `spx` |
| AIFF / PCM | `aiff` `aif` `aifc` `au` `snd` |
| Mobile | `amr` `awb` `3gp` `3g2` |
| Lossless | `wv` `ape` `tak` `tta` `flac` |
| RealMedia | `ra` `rm` `rmvb` |
| MPEG audio | `mp2` `mp1` |
| Surround | `ac3` `eac3` `dts` `dtshd` |
| Streaming | `f4v` `f4a` `f4b` |
| Other | `mpg` `mpeg` `m2v` `m1v` `gsm` `mid` `midi` `nut` `roq` |

If ffmpeg is not installed, only the four native formats are accepted.

## Output Formats

| Flag value | Extension | Description |
|------------|-----------|-------------|
| `txt` | `.txt` | Plain text with timestamps (default) |
| `srt` | `.srt` | SubRip subtitles |
| `vtt` | `.vtt` | WebVTT subtitles |
| `json` | `.json` | JSON with segment data |
| `csv` | `.csv` | CSV with timing columns |
| `lrc` | `.lrc` | LRC lyrics format |

Output files are written next to each input file by default, or into the directory specified with `-o`.

## Models

The script resolves model names in order:

1. Absolute path — used as-is
2. Filename in `~/whisper.cpp/models/` — used as-is
3. Short name `foo` → `~/whisper.cpp/models/ggml-foo.bin`

Available models in `~/whisper.cpp/models/` can be listed with:

```bash
ls ~/whisper.cpp/models/ggml-*.bin | sed 's|.*/ggml-||;s|\.bin||'
```

Download additional models:

```bash
cd ~/whisper.cpp
bash models/download-ggml-model.sh large-v3-turbo
bash models/download-ggml-model.sh medium
bash models/download-ggml-model.sh small
```

## Examples

```bash
# Single file — auto-detect language, plain text output
./tools/transcribe.sh interview.mp4

# Russian language, SRT subtitles
./tools/transcribe.sh -l ru -f srt podcast.m4a

# Translate French audio to English
./tools/transcribe.sh -T -l fr conference.webm

# Batch: recurse a folder, write all results to ./transcripts/
./tools/transcribe.sh -r -o ./transcripts ./recordings/

# WhatsApp voice message, no timestamps
./tools/transcribe.sh -n 'voice note.opus'

# Use a specific model, JSON output, 4 threads
./tools/transcribe.sh -m medium -f json -t 4 lecture.mp3

# Guide transcription style with an initial prompt
./tools/transcribe.sh -p "Technical meeting about software architecture." standup.m4a
```

## Notes

- Conversion to WAV happens in a temporary directory and is cleaned up automatically after the run.
- Thread count defaults to the number of logical CPU cores (`sysctl hw.logicalcpu`).
- The script uses Metal GPU acceleration on Apple Silicon automatically (no extra flags needed).
- Exit code is `0` on full success, `1` if any file failed to transcribe.
