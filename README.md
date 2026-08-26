# decant

[![tests](https://github.com/jzstern/decant/actions/workflows/tests.yml/badge.svg)](https://github.com/jzstern/decant/actions/workflows/tests.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![platform: macOS](https://img.shields.io/badge/platform-macOS-lightgrey.svg)

Right-click audio in Finder and pour it into the format your gear actually
wants — without disturbing what's inside. Lossless files become **AIFF** with
no quality loss; lossy `.m4a` (AAC) and `.opus` files become CDJ-ready **MP3**
at the highest bitrate that doesn't exceed the source's (never inflated).
Metadata is preserved, artwork carries over wherever the target format accepts
it, and originals move to the Trash. Works on a single file, a selection, or a
whole folder (recursing into subfolders). Other lossy and non-audio files are
left untouched.

It also **enriches** the ID3 tags as it converts — backfilling a catalog number,
track/disc numbers, and folder artwork from the file/folder names. Backfilling
never overwrites a tag the source already has; the one exception is normalizing
`feat.`→`ft.`, which edits the title in place.

<!-- TODO: demo.gif — right-click ▸ Quick Actions ▸ Decant, then the notification -->

> [!IMPORTANT]
> Originals are moved to the **Trash** (recoverable), never hard-deleted, and
> only **after** the new `.aiff`/`.mp3` is verified readable. A failed
> conversion never loses the source. Still, try it on a copy first if you're
> cautious.

## Requirements

- macOS 13 (Ventura) or later — tested on Sequoia and Tahoe
- [ffmpeg](https://ffmpeg.org) (installed automatically by Homebrew, below)

`decant` uses the first `ffmpeg`/`ffprobe` on your `PATH`, so a build you chose
deliberately (a static build with extra encoders, MacPorts, Nix) is the one that
runs. Homebrew's `/opt/homebrew/bin` and `/usr/local/bin` are added as a
*fallback* only — which is what makes the Finder Quick Action work, since a
GUI-launched process inherits a minimal `PATH` with no Homebrew on it.

## Install

### Homebrew (recommended)

```sh
brew install jzstern/tap/decant
```

This installs the `decant` CLI and pulls in `ffmpeg` automatically.

<details>
<summary>Or install manually from source</summary>

```sh
git clone https://github.com/jzstern/decant.git
cd decant && ./install.sh
```

Copies the CLI to `~/.local/bin/decant`. ffmpeg is installed via Homebrew on
first run if it isn't already present.
</details>

### Add the Finder right-click action (one time)

macOS won't let an installer register a Finder Quick Action — you add the
bundled Shortcut yourself. It takes about a minute:

1. Double-click [`shortcut/Decant.shortcut`](shortcut/) → **Add Shortcut**.
   It's pre-built to receive Files & Folders and run the CLI.
2. **Enable it.** macOS imports Shortcut Quick Actions *disabled*. Turn it on in
   **System Settings ▸ Login Items & Extensions ▸ Finder** → toggle **Decant** on.
   *(Easy to miss — without it the action won't appear in the menu.)*
3. Right-click any audio files or a folder in Finder →
   **Quick Actions ▸ Decant**.
4. **First run only:** macOS asks to let the shortcut access the file(s) —
   click **Always Allow**. Silent thereafter.

It works in protected folders (Desktop / Documents / Downloads) with **no Full
Disk Access needed** — see [How it works](#how-it-works).

### Upgrading from `toaiff`

This tool used to be called `toaiff`, and its Quick Action was named **→ aiff**.
That shortcut runs `toaiff`, which no longer exists — so after upgrading, the
right-click action fails until you replace it:

1. Add the new Quick Action using the steps above.
2. Delete the old **→ aiff** shortcut in Shortcuts.app.

Two other things moved: every `TOAIFF_*` environment variable is now `DECANT_*`,
and the log lives at `~/Library/Logs/decant.log` instead of `toaiff.log`.

## Use from the terminal

```sh
decant ~/Music/Album              # recurse a folder
decant track.flac other.wav       # one or more files
decant --dry-run ~/Music/Album    # preview tags/conversions, write nothing
decant --no-enrich ~/Music/Album  # pure transcode, skip all tag enrichment
decant -- -weird-name.flac        # a path that starts with a dash
decant --help                     # full usage, flags, env vars and exit codes
decant --version
```

Flags may appear anywhere before `--`, so `decant ~/Music/Album --dry-run`
works too. An unrecognised flag is an error, never a filename.

## What gets converted

Conversion is decided by the actual audio **codec**, not just the file
extension, so a `.m4a` holding ALAC converts losslessly to AIFF while a `.m4a`
holding AAC takes the MP3 path.

| Input | Action |
|-------|--------|
| FLAC, ALAC, WavPack, Monkey's Audio (APE), TAK, TTA, MLP/TrueHD, Shorten | convert → AIFF |
| WAV / raw PCM | convert → AIFF (uncompressed passthrough) |
| Already AIFF | skipped |
| Lossy `.m4a` (AAC), `.opus` | convert → MP3 (bitrate capped at the source's) |
| MP3, Vorbis, AC3, WMA, … (other lossy) | skipped |
| DSD (`.dsf`/`.dff`) | skipped — see below |
| Non-audio files | ignored |

DSD is the one lossless format `decant` declines. Decimating 1-bit sigma-delta
down to multi-bit PCM is a re-recording, not a copy, so there is no AIFF that
would still be the same audio — `decant` recognises DSD by name and leaves it
alone rather than pretending otherwise. Run with `--debug` and the log says so
explicitly, instead of filing it under "lossy".

## How quality is preserved

ffmpeg's AIFF encoder defaults to 16-bit, which would silently downsample
24-bit masters. `decant` reads each source's true bit depth and selects a PCM
target that is always **≥** the source depth:

| Source | AIFF target |
|--------|-------------|
| 8-bit  | `pcm_s8` |
| 16-bit | `pcm_s16be` |
| 24-bit | `pcm_s24be` |
| 32-bit int | `pcm_s32be` |
| 32/64-bit float | `pcm_f32be` / `pcm_f64be` (AIFF-C) |

Sample rate and channel layout are never touched (no resampling). AIFF and MP3
each hold exactly one audio stream, so a source carrying several (an `.mka` with
alternate mixes, say) contributes its **first** one; everything else the
container held besides the cover art is left behind. Tags and embedded cover art
are carried over via `-map_metadata` and an ID3v2 chunk; if the AIFF container
rejects an embedded image, the audio still converts and the artwork is dropped
with a logged note.

### Lossy `.m4a` / `.opus` → MP3

A lossy source can't become lossless again, so re-encoding it at a *higher*
bitrate would only waste space. `decant` reads the source's real bitrate and
picks the **highest standard MP3 CBR rate that doesn't exceed it** (320 kbps
max, LAME's best-quality algorithm): a 256 kbps AAC becomes a 256 kbps MP3, a
96 kbps Opus never becomes a 320 kbps MP3. If the source bitrate is unknown,
MP3's maximum (320 kbps) is used; a source below MP3's 32 kbps floor encodes
at 32 (the format's minimum). All tags — including Opus's stream-level Vorbis
comments — and embedded or folder cover art carry over, and the same
enrichment applies as on the AIFF path.

The output is deliberately the most **CDJ/rekordbox-compatible** MP3 possible:

- **CBR**, never VBR — VBR seeking is unreliable on older CDJ firmware
- **ID3v2.3** tags — the version Pioneer hardware reads most reliably
- **JPEG cover art** — CDJs ignore PNG APIC frames, so any non-JPEG art
  (embedded or folder) is re-encoded to baseline JPEG
- **32 / 44.1 / 48 kHz only** (MPEG-1 Layer III) — an off-spec source rate
  (e.g. 22.05 kHz) is resampled to 44.1 kHz (48 kHz for sources above 48 kHz);
  standard-rate sources are never resampled

## Metadata enrichment

During conversion, `decant` derives tags that live in the file/folder names but
are missing from the audio tags, and applies one normalization. Everything is
**fill-gaps-only** — an existing tag is never overwritten — and enrichment is
**on by default**. Turn it off with `--no-enrich` (or `DECANT_NO_ENRICH=1`) for
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
decant --dry-run ~/Music/Album
# decant: would convert 02 - Lion Soul (feat. X).flac (pcm_s24be) [grouping=ARTKL081 track=2 title=Lion Soul (ft. X) art=cover.png]
```

## How it works

ffmpeg writes the `.aiff`/`.mp3` directly to its final path, and the original is
trashed only after the output is verified to be readable audio. On any failure
the original is left exactly as it was.

<details>
<summary>Why it works in protected folders without Full Disk Access</summary>

A Finder Quick Action runs the script sandboxed under `ShortcutsMacHelper`. In
TCC-protected folders (Desktop / Documents / Downloads) that sandbox lets a
*child* process (ffmpeg) **create** files but won't let the shell **rename or
delete a file ffmpeg made**. So `decant` has ffmpeg write the output **directly
to its final name** (no temp + rename) and trashes the original via
`NSFileManager`, which the Quick Action's scoped access to the selected file
permits. That's also why a true Quick Action here must be a Shortcut: a
hand-built Automator `.workflow` only ever registers as a *Service* on recent
macOS.
</details>

## Logging

One central log at **`~/Library/Logs/decant.log`**, appended to no matter where
the action runs. **By default only errors are logged**, so a clean run writes
nothing. For a full trace of every run / conversion / skip:

```sh
decant --debug ~/Music/Album        # or set DECANT_DEBUG=1
tail -f ~/Library/Logs/decant.log
```

To debug the Finder Quick Action, add `--debug` to its Run Shell Script line
temporarily — change `exec decant --notify "$@"` to
`exec decant --notify --debug "$@"`.

## Configuration

| Flag | Env | Effect |
|------|-----|--------|
| `--no-enrich` | `DECANT_NO_ENRICH` | Pure transcode; skip all tag enrichment. |
| `--dry-run` | — | Preview the tag/conversion plan; write and trash nothing. |
| `--debug` | `DECANT_DEBUG` | Log every run/conversion/skip, not just errors. |
| `--notify` | — | Post a completion notification (what the Quick Action uses). |
| `-h`, `--help` | — | Print the full usage — flags, env vars, exit codes — and exit. |
| `--version` | — | Print the version and exit. |
| `--` | — | End of options: every remaining argument is a path. |
| — | `DECANT_KEEP_ORIGINALS` | Convert without trashing originals (cautious first pass). |
| — | `DECANT_NO_NOTIFY` | Suppress the completion notification even with `--notify`. |
| — | `DECANT_LOG` | Override the log file path (used by the test suite). |

### Exit codes

Skipping is normal, not a failure: a run that converts nothing because every
file was already AIFF, lossy, or unsupported still exits `0`. Only things
decant was asked to do and *couldn't* produce a non-zero status, using the
conventional [sysexits](https://man.freebsd.org/cgi/man.cgi?sysexits) codes.

| Code | Meaning |
|------|---------|
| `0` | Nothing was left undone — conversions, skips and dry runs all count. |
| `1` | At least one file failed to convert (the original is left untouched). |
| `64` | Usage error: no paths given, or an unrecognised option. |
| `66` | A given path does not exist. |
| `69` | ffmpeg/ffprobe are unavailable and could not be installed. |
| `77` | Refused a path that is too broad to recurse (a filesystem or home root). |

When one run hits several of these, the most severe wins: `1` over `77` over
`66`. So a script or Shortcut can branch on `decant … || handle "$?"` and trust
that a typo or a missing file never reads as success.

> **No stray output files:** as a Finder Quick Action the script runs with
> `--notify` and no terminal, so it writes nothing to stdout/stderr — which the
> Shortcuts "Run Shell Script" action would otherwise save as a `stdout.txt` /
> `stderr.txt` beside your files. Results come from the notification and the log.

## Uninstall

```sh
brew uninstall decant                 # or: rm ~/.local/bin/decant
rm -f ~/Library/Logs/decant.log
```

Then delete the **Decant** shortcut in Shortcuts.app and toggle it off in
System Settings ▸ Login Items & Extensions ▸ Finder.

## Contributing

Issues and PRs welcome. Run the test suite before submitting:

```sh
./tests/run.sh
```

It generates fixtures with ffmpeg and exercises depth preservation, bitrate
capping, metadata and artwork retention, codec classification, stream mapping,
`ffmpeg` resolution, enrichment + decoy rejection, recursion, skipping,
logging, and the CLI contract (exit codes, flag parsing) — all
non-destructively (no files are trashed). CI runs the same suite on every PR.

The Quick Action is built from [`shortcut/decant.shortcut.plist`](shortcut/).
After editing it, re-sign the distributable copy — note the input **must** end
in `.shortcut` or the signer rejects it:

```sh
cp shortcut/decant.shortcut.plist /tmp/Decant.shortcut
shortcuts sign --mode anyone --input /tmp/Decant.shortcut --output shortcut/Decant.shortcut
```

## License

[MIT](LICENSE)
