# toaiff

Convert lossless audio to **AIFF** on macOS without any quality reduction,
preserving all available artwork and metadata. Works on a single file or a
folder (recursing into every subfolder). Lossy and non-audio files are left
untouched. Each original is moved to the **Trash** once its `.aiff` is written.

Runs as a CLI, plus a one-time **Shortcuts** Quick Action for right-clicking in
Finder.

## Install

```sh
./install.sh
```

This copies the CLI to `~/.local/bin/toaiff`. ffmpeg is installed automatically
via Homebrew on first run if it isn't already present.

## Use from Terminal

```sh
toaiff ~/Music/Album            # recurse a folder
toaiff track.flac other.wav     # one or more files
```

## Finder Quick Action

On macOS Sequoia/Tahoe, a true Finder **Quick Action** must be a Shortcut or an
app extension — a hand-built Automator `.workflow` only ever registers as a
*Service*. So the right-click integration is a Shortcut that calls the CLI.

**Install the ready-made one:**

1. Double-click [`shortcut/→ aiff.shortcut`](shortcut/) → **Add Shortcut**.
   (It's pre-built: receives Files and Folders, runs the CLI, passes input
   **as arguments**, and is flagged as a Finder Quick Action.)
2. **Enable it** — macOS imports Shortcut Quick Actions *disabled*. Turn it on
   in **System Settings ▸ Login Items & Extensions ▸ Finder** → toggle **→ aiff**
   on. *(This step is easy to miss; without it the action won't appear.)*
3. Right-click any FLAC/WAV files or a folder in Finder →
   **Quick Actions ▸ → aiff**.
4. **First run only:** macOS asks to let the shortcut access the file(s) and
   output text — click **Always Allow** on each. Silent thereafter.

To rebuild the signed shortcut from source:

```sh
cd shortcut && cp toaiff.shortcut.plist in.shortcut \
  && shortcuts sign --mode anyone -i in.shortcut -o "→ aiff.shortcut" && rm in.shortcut
```

> **Protected folders (Desktop / Documents / Downloads):** shell scripts run
> from a Shortcut are sandboxed and, in these three TCC-protected folders,
> macOS blocks the rename that puts the `.aiff` in place. Runs there fail
> **safely** (original untouched, error logged) until you grant access:
>
> 1. Run the action once on a file in Downloads (it'll fail) — this adds
>    **`siriactionsd`** (the Shortcuts action daemon) to the Full Disk Access
>    list, disabled.
> 2. **System Settings ▸ Privacy & Security ▸ Full Disk Access** → toggle
>    **`siriactionsd`** on (authenticate when prompted).
> 3. It now works in those folders too. (Restarting helps: `killall siriactionsd`.)
>
> Everywhere else (`~/Music`, external drives, …) it works with no Full Disk
> Access needed.

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

## Logging

Every run appends to `~/Library/Logs/toaiff.log` — one line per converted,
skipped, or failed file, plus the underlying ffmpeg error on failure. This
matters most for the Finder Quick Action, which otherwise discards all output:

```sh
tail -f ~/Library/Logs/toaiff.log
```

## Environment variables

| Variable | Effect |
|----------|--------|
| `TOAIFF_KEEP_ORIGINALS` | Convert without trashing originals (cautious first pass / testing). |
| `TOAIFF_LOG` | Override the log file path. |

## Tests

```sh
./tests/run.sh
```

Generates fixtures with ffmpeg and exercises depth preservation, metadata and
artwork retention, recursion, lossy/non-audio skipping, and logging — all
non-destructively (no files are trashed).
