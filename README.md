# toaiff

[![tests](https://github.com/jzstern/toaiff/actions/workflows/tests.yml/badge.svg)](https://github.com/jzstern/toaiff/actions/workflows/tests.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![platform: macOS](https://img.shields.io/badge/platform-macOS-lightgrey.svg)

Right-click lossless audio in Finder and convert it to **AIFF** — no quality
loss, all artwork and metadata preserved, originals moved to the Trash. Works on
a single file, a selection, or a whole folder (recursing into subfolders). Lossy
and non-audio files are left untouched.

It also **enriches** the ID3 tags as it converts — backfilling a catalog number,
track/disc numbers, and folder artwork from the file/folder names, and
normalizing `feat.`→`ft.` — without ever overwriting tags the source already has.

<!-- TODO: demo.gif — right-click ▸ Quick Actions ▸ → aiff, then the notification -->

> [!IMPORTANT]
> Originals are moved to the **Trash** (recoverable), never hard-deleted, and
> only **after** the new `.aiff` is verified readable. A failed conversion never
> loses the source. Still, try it on a copy first if you're cautious.

## Requirements

- macOS 13 (Ventura) or later — tested on Sequoia and Tahoe
- [ffmpeg](https://ffmpeg.org) (installed automatically by Homebrew, below)

## Install

### Homebrew (recommended)

```sh
brew install jzstern/tap/toaiff
```

This installs the `toaiff` CLI and pulls in `ffmpeg` automatically.

<details>
<summary>Or install manually from source</summary>

```sh
git clone https://github.com/jzstern/toaiff.git
cd toaiff && ./install.sh
```

Copies the CLI to `~/.local/bin/toaiff`. ffmpeg is installed via Homebrew on
first run if it isn't already present.
</details>

### Add the Finder right-click action (one time)

macOS won't let an installer register a Finder Quick Action — you add the
bundled Shortcut yourself. It takes about a minute:

1. Double-click [`shortcut/→ aiff.shortcut`](shortcut/) → **Add Shortcut**.
   It's pre-built to receive Files & Folders and run the CLI.
2. **Enable it.** macOS imports Shortcut Quick Actions *disabled*. Turn it on in
   **System Settings ▸ Login Items & Extensions ▸ Finder** → toggle **→ aiff** on.
   *(Easy to miss — without it the action won't appear in the menu.)*
3. Right-click any lossless files or a folder in Finder →
   **Quick Actions ▸ → aiff**.
4. **First run only:** macOS asks to let the shortcut access the file(s) —
   click **Always Allow**. Silent thereafter.

It works in protected folders (Desktop / Documents / Downloads) with **no Full
Disk Access needed** — see [How it works](#how-it-works).

## Use from the terminal

```sh
toaiff ~/Music/Album            # recurse a folder
toaiff track.flac other.wav     # one or more files
toaiff --dry-run ~/Music/Album  # preview tags/conversions, write nothing
toaiff --no-enrich ~/Music/Album  # pure transcode, skip all tag enrichment
toaiff --version
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

## Metadata enrichment

During conversion, `toaiff` derives tags that live in the file/folder names but
are missing from the audio tags, and applies one normalization. Everything is
**fill-gaps-only** — an existing tag is never overwritten — and enrichment is
**on by default**. Turn it off with `--no-enrich` (or `TOAIFF_NO_ENRICH=1`) for
a pure transcode.

| Enrichment | Source | Written to | Rule |
|------------|--------|-----------|------|
| **Catalog number** | album folder name, e.g. `[SHA300]`, `(snf137)`, `{LLR004}`, bare `USB002` | `grouping` (uppercased, e.g. `SHA300`) | only if no `grouping` tag |
| **Track / disc** | leading filename token: `01 - …`, `001 - …`, `(01 - 02) …` | `track` / `disc` | leading number only (trailing numbers in a title ignored); only if absent |
| **`feat.`→`ft.`** | the `title` itself | `title` | word-anchored (`FEISTY` is safe); the one value that is *edited*, not gap-filled |
| **Folder artwork** | `cover`/`folder`/`front`.`jpg`/`png` beside the file | embedded cover | only if the source has no embedded art |

Catalog detection rejects look-alikes in the same brackets — format/quality
words (`[WEB FLAC]`, `[FLAC 24]`), years (`(2026)`), release types (`[EP]`), and
barcodes (`{…, 5056818805226}`). The heuristics are tuned to scene/label folder
naming; on a 7,988-folder test library it found ~5,500 real catalog numbers with
a single false positive. If your library is named differently and you don't want
the guesswork, run with `--no-enrich`.

Preview exactly what each file would get, without writing anything:

```sh
toaiff --dry-run ~/Music/Album
# toaiff: would convert 02 - Lion Soul (feat. X).flac (pcm_s24be) [grouping=ARTKL081 track=2 title=Lion Soul (ft. X) art=cover.png]
```

## How it works

ffmpeg writes the `.aiff` directly to its final path, and the original is
trashed only after the output is verified to be a readable AIFF. On any failure
the original is left exactly as it was.

<details>
<summary>Why it works in protected folders without Full Disk Access</summary>

A Finder Quick Action runs the script sandboxed under `ShortcutsMacHelper`. In
TCC-protected folders (Desktop / Documents / Downloads) that sandbox lets a
*child* process (ffmpeg) **create** files but won't let the shell **rename or
delete a file ffmpeg made**. So `toaiff` has ffmpeg write the `.aiff` **directly
to its final name** (no temp + rename) and trashes the original via
`NSFileManager`, which the Quick Action's scoped access to the selected file
permits. That's also why a true Quick Action here must be a Shortcut: a
hand-built Automator `.workflow` only ever registers as a *Service* on recent
macOS.
</details>

## Logging

One central log at **`~/Library/Logs/toaiff.log`**, appended to no matter where
the action runs. **By default only errors are logged**, so a clean run writes
nothing. For a full trace of every run / conversion / skip:

```sh
toaiff --debug ~/Music/Album        # or set TOAIFF_DEBUG=1
tail -f ~/Library/Logs/toaiff.log
```

To debug the Finder Quick Action, add `--debug` to its Run Shell Script line
temporarily — change `exec toaiff --notify "$@"` to
`exec toaiff --notify --debug "$@"`.

## Configuration

| Flag | Env | Effect |
|------|-----|--------|
| `--no-enrich` | `TOAIFF_NO_ENRICH` | Pure transcode; skip all tag enrichment. |
| `--dry-run` | — | Preview the tag/conversion plan; write and trash nothing. |
| `--debug` | `TOAIFF_DEBUG` | Log every run/conversion/skip, not just errors. |
| — | `TOAIFF_KEEP_ORIGINALS` | Convert without trashing originals (cautious first pass). |
| — | `TOAIFF_NO_NOTIFY` | Suppress the completion notification even with `--notify`. |
| — | `TOAIFF_LOG` | Override the log file path (used by the test suite). |

> **No stray output files:** as a Finder Quick Action the script runs with
> `--notify` and no terminal, so it writes nothing to stdout/stderr — which the
> Shortcuts "Run Shell Script" action would otherwise save as a `stdout.txt` /
> `stderr.txt` beside your files. Results come from the notification and the log.

## Uninstall

```sh
brew uninstall toaiff                 # or: rm ~/.local/bin/toaiff
rm -f ~/Library/Logs/toaiff.log
```

Then delete the **→ aiff** shortcut in Shortcuts.app and toggle it off in
System Settings ▸ Login Items & Extensions ▸ Finder.

## Contributing

Issues and PRs welcome. Run the test suite before submitting:

```sh
./tests/run.sh
```

It generates fixtures with ffmpeg and exercises depth preservation, metadata and
artwork retention, enrichment + decoy rejection, recursion, skipping, and
logging — all non-destructively (no files are trashed). CI runs the same suite
on every PR.

## License

[MIT](LICENSE)
