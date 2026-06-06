# toaiff

Convert lossless audio to **AIFF** on macOS without any quality reduction,
preserving all available artwork and metadata. Works on a single file or a
folder (recursing into every subfolder). Lossy and non-audio files are left
untouched. Each original is moved to the **Trash** once its `.aiff` is written.

Ships as a Finder **Quick Action** (right-click) and a CLI.

## Install

```sh
./install.sh
```

This copies the CLI to `~/.local/bin/toaiff` and the Quick Action to
`~/Library/Services/`. ffmpeg is installed automatically via Homebrew on first
run if it isn't already present.

## Use

**Finder:** right-click any files or folders → **Quick Actions → → aiff**.
A notification reports how many files were converted / skipped / failed.

**Terminal:**

```sh
toaiff ~/Music/Album            # recurse a folder
toaiff track.flac other.wav     # one or more files
```

## What gets converted

Conversion is decided by the actual audio **codec**, not the file extension, so
a `.m4a` holding ALAC is converted while a `.m4a` holding AAC is skipped.

| Input | Action |
|-------|--------|
| FLAC, ALAC, WavPack, Monkey's Audio (APE), TAK, TTA, MLP/TrueHD | convert → AIFF |
| WAV / raw PCM | convert → AIFF (uncompressed passthrough) |
| Already AIFF | skipped |
| MP3, AAC, Vorbis, Opus, AC3, WMA, … (lossy) | skipped |
| DSD (`.dsf`/`.dff`) | skipped (no clean lossless PCM mapping) |
| Non-audio files | ignored |

## How quality is preserved

ffmpeg's AIFF encoder defaults to 16-bit, which would silently downsample
24-bit masters. `toaiff` reads each source's true bit depth and selects a PCM
target that is always **≥** the source depth:

| Source | AIFF target |
|--------|-------------|
| 8-bit  | `pcm_s8` |
| 16-bit | `pcm_s16be` |
| 24-bit | `pcm_s24be` |
| 32-bit int | `pcm_s32be` |
| 32/64-bit float | `pcm_f32be` / `pcm_f64be` (AIFF-C) |

Sample rate and channel layout are never touched (no resampling). Tags and
embedded cover art are carried over via `-map_metadata` and an ID3v2 chunk; if
the AIFF container rejects an embedded image, the audio still converts and the
artwork is dropped with a logged note.

## Safety

The `.aiff` is written to a temporary file first. The original is only trashed
after ffmpeg succeeds and the output is verified non-empty; on any failure the
original is left exactly as it was.
