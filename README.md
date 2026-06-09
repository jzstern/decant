# toaiff

Convert lossless audio to **AIFF** on macOS without any quality reduction,
preserving all available artwork and metadata. Works on a single file or a
folder (recursing into every subfolder). Lossy and non-audio files are left
untouched. Each original is moved to the **Trash** once its `.aiff` is written.

It also **enriches** the ID3 tags during conversion — backfilling a catalog
number, track/disc numbers, and folder artwork from the file/folder names, and
normalizing `feat.`→`ft.` — without ever overwriting tags the source already
has. See [Metadata enrichment](#metadata-enrichment).

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
toaiff --dry-run ~/Music/Album  # preview tags/conversions, write nothing
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

> **Protected folders (Desktop / Documents / Downloads):** works here too, with
> **no Full Disk Access needed.** A Finder Quick Action runs the script
> sandboxed under `ShortcutsMacHelper`, and in these TCC-protected folders that
> sandbox lets a *child* process (ffmpeg) **create** files but won't let the
> shell **rename or delete a file ffmpeg made**. So `toaiff` has ffmpeg write
> the `.aiff` **directly to its final name** (no temp + rename) and trashes the
> original via `NSFileManager` (which the Quick Action's scoped access to the
> selected file permits). The original is removed only after the output is
> verified valid, so a failed conversion never loses the source.

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

## Metadata enrichment

During conversion, `toaiff` derives tags that live in the file/folder names but
are missing from the audio tags, and applies one normalization. Everything is
**fill-gaps-only** — an existing tag is never overwritten — and enrichment is
**on by default** for every conversion, including the Finder Quick Action.

| Enrichment | Source | Written to | Rule |
|------------|--------|-----------|------|
| **Catalog number** | album folder name, e.g. `[SHA300]`, `(snf137)`, `{LLR004}`, bare `USB002` | `grouping` (uppercased, e.g. `SHA300`) | only if no `grouping` tag |
| **Track / disc** | leading filename token: `01 - …`, `001 - …`, `(01 - 02) …` | `track` / `disc` | only the leading number; trailing numbers in a title are ignored; only if absent |
| **`feat.`→`ft.`** | the `title` itself | `title` | word-anchored (so `FEISTY` is safe); the one value that is *edited*, not gap-filled |
| **Folder artwork** | `cover`/`folder`/`front`.`jpg`/`png` beside the file | embedded cover | only if the source has no embedded art |

Catalog detection rejects look-alikes in the same brackets — format/quality
words (`[WEB FLAC]`, `[FLAC 24]`), years (`(2026)`), release types (`[EP]`), and
barcodes (`{…, 5056818805226}`). Validated against a 7,988-folder library:
~5,500 real catalog numbers detected with a single false positive.

Use **`--dry-run`** to preview exactly what each file would get before writing:

```sh
toaiff --dry-run ~/Music/Album
# toaiff: would convert 02 - Lion Soul (feat. X).flac (pcm_s24be) [grouping=ARTKL081 track=2 title=Lion Soul (ft. X) art=cover.png]
```

## Safety

ffmpeg writes the `.aiff` directly to its final path, and the original is
trashed only after the output is verified to be a readable AIFF (via ffprobe).
On any failure the original is left exactly as it was.

## Logging

One central log at **`~/Library/Logs/toaiff.log`**, appended to no matter where
the action runs. **By default only errors are logged** (a failed conversion or a
refused-too-broad path), so a clean run writes nothing. For a full trace of
every run / conversion / skip, enable debug:

```sh
toaiff --debug ~/Music/Album        # or set TOAIFF_DEBUG=1
tail -f ~/Library/Logs/toaiff.log
```

To debug the Finder Quick Action, add `--debug` to its Run Shell Script line
temporarily: `"$HOME/.local/bin/toaiff" --notify --debug "$@"`.

## Environment variables

| Variable | Effect |
|----------|--------|
| `TOAIFF_DEBUG` | Log every run/conversion/skip, not just errors (same as `--debug`). |
| `TOAIFF_KEEP_ORIGINALS` | Convert without trashing originals (cautious first pass / testing). |
| `TOAIFF_LOG` | Override the log file path (used by the test suite). |

## Tests

```sh
./tests/run.sh
```

Generates fixtures with ffmpeg and exercises depth preservation, metadata and
artwork retention, recursion, lossy/non-audio skipping, and logging — all
non-destructively (no files are trashed).
