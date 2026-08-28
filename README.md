# decant

[![tests](https://github.com/jzstern/decant/actions/workflows/tests.yml/badge.svg)](https://github.com/jzstern/decant/actions/workflows/tests.yml)
[![version](https://img.shields.io/badge/version-0.3.0-blue.svg)](https://github.com/jzstern/decant/releases)
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
> only **after** the new `.aiff`/`.mp3` is verified readable. A failed or
> interrupted conversion never loses the source, and if an original can't be
> trashed you're told rather than left guessing. Still, try it on a copy first
> if you're cautious.

## Requirements

- macOS 13 (Ventura) or later — tested on Sequoia and Tahoe
- [ffmpeg](https://ffmpeg.org) — the Homebrew install below pulls it in for you;
  otherwise `decant` offers to install it on first run (see
  [Installing ffmpeg](#installing-ffmpeg))

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

Copies the CLI to `~/.local/bin/decant`. ffmpeg is not installed for you — see
[Installing ffmpeg](#installing-ffmpeg).
</details>

### Installing ffmpeg

`brew install jzstern/tap/decant` lists ffmpeg as a dependency, so a Homebrew
install already has it. Otherwise, on the first run that needs it:

- **In a terminal**, `decant` asks before installing — `brew install ffmpeg` is
  several hundred megabytes, so it never happens silently.
- **Anywhere without a terminal** (the Finder Quick Action, `cron`, CI), it does
  not install: there is nobody to ask and nowhere to show progress, so the run
  exits `69` and tells you to run `brew install ffmpeg` yourself. Under
  `--notify` that message arrives as a notification, since the Quick Action has
  no visible output.

### The Finder right-click action

`install.sh` and the Homebrew formula both install it — right-click audio files
or a folder in Finder ▸ **Quick Actions** ▸ **Decant**. No setup, and no
permission prompt.

It runs `decant --notify --jobs auto`, so a right-clicked album converts on
every core. Right-click is the one context with no way to pass a flag, which is
why the parallelism is baked into the action itself.

It works in protected folders (Desktop / Documents / Downloads) with **no Full
Disk Access needed** — see [How it works](#how-it-works).

> **Upgrading from the Shortcuts version?** Delete the **Decant** shortcut in
> Shortcuts.app. Otherwise two identically named entries appear in the
> right-click menu, and the Shortcut one still asks permission for every folder.

### Upgrading from `toaiff`

This tool used to be called `toaiff`, and its Quick Action was named **→ aiff**.
That shortcut runs `toaiff`, which no longer exists — so after upgrading, the
right-click action fails until you replace it:

`install.sh` and `brew upgrade` both install the current Quick Action for you,
so all that's left is to delete the old **→ aiff** shortcut in Shortcuts.app.

Two other things moved: every `TOAIFF_*` environment variable is now `DECANT_*`,
and the log lives at `~/Library/Logs/decant.log` instead of `toaiff.log`.

## Use from the terminal

```sh
decant ~/Music/Album              # recurse a folder
decant track.flac other.wav       # one or more files
decant --dry-run ~/Music/Album    # preview tags/conversions, write nothing
decant --keep ~/Music/Album       # convert, but leave the originals in place
decant --no-enrich ~/Music/Album  # pure transcode, skip all tag enrichment
decant --jobs auto ~/Music/Album  # convert several files at once
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

When a resample is unavoidable, `decant` uses **libsoxr at precision 28** —
measurably cleaner than ffmpeg's built-in resampler. libsoxr is an optional
ffmpeg build dependency (Homebrew's bottle currently ships without it, so
`ffmpeg -buildconf | grep libsoxr` is worth a look), so support is verified at
run time by actually pushing a few milliseconds of audio through it; builds
without it fall back to the default resampler rather than failing the
conversion. `DECANT_NO_SOXR=1` forces the fallback.

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
| **Folder artwork** | `cover`, then `folder`, then `front` — `.jpg`, then `.jpeg`, then `.png` — beside the file, or in the album root for a track in a disc subfolder | embedded cover | only if the source has no embedded art |

Tag keys are matched without regard to case. Vorbis comments are conventionally
upper case (`TITLE`, `GROUPING`) and the spec calls the key case-insensitive;
Matroska upper-cases its tag names whatever you wrote them as; an MP3's `TXXX`
description keeps the case it was given. So the four tags above are recognised
however the file spells them — a tag read as missing is a tag that gets a
derived value written over it, which is precisely what fill-gaps-only is for.
If you have already converted FLACs, Opus files or `.mka`s with decant, their
`grouping` is worth a look: earlier versions could not see an upper-case
`GROUPING` and replaced it with the folder's catalog number, and left `feat.`
in an upper-case `TITLE` un-normalized.

Catalog detection rejects look-alikes in the same brackets — format/quality
words (`[WEB FLAC]`, `[FLAC 24]`), years (`(2026)`), release types (`[EP]`), and
barcodes (`{…, 5056818805226}`). The heuristics are tuned to scene/label folder
naming; on a 7,988-folder test library it found ~5,500 real catalog numbers with
a single false positive. If your library is named differently and you don't want
the guesswork, run with `--no-enrich`.

Artwork lookup is case-insensitive and skips zero-byte files. The name and
extension order in the table is the tie-break when a folder holds several
candidates, so the same album always yields the same cover.

Multi-disc releases keep the art at the album root and the tracks one level
down, so a track in a **disc subfolder** — a folder named `CD1`, `CD 2`,
`Disc-03`, `disk4` and nothing else — falls back to its parent's cover:

```
Album/cover.jpg              ← embedded into both tracks below
Album/CD1/01 - Track.flac
Album/CD2/01 - Track.flac
```

That fallback goes exactly one level, and only from a disc folder. A track in
an ordinary folder never reaches up: the parent of `~/Music/Some Album` is
`~/Music`, and a stray `cover.jpg` sitting there belongs to nothing in
particular — embedding it would stamp one unrelated image onto every album in
the library.

Preview exactly what each file would get, without writing anything:

```sh
decant --dry-run ~/Music/Album
# decant: would convert 02 - Lion Soul (feat. X).flac (pcm_s24be) [grouping=ARTKL081 track=2 title=Lion Soul (ft. X) art=cover.png]
```

## How it works

ffmpeg writes the `.aiff`/`.mp3` directly to its final path, and the original is
trashed only after the output is verified to be readable audio. On any failure
the original is left exactly as it was.

### Interrupting a run

Because there is no temp-file stage, a run killed mid-encode would otherwise
leave a half-written file sitting at the destination. `decant` traps `INT`,
`TERM` and `HUP`, discards whatever ffmpeg was writing, and exits `128 + signal`
— nothing else in the folder is touched, and the source is still there.

If a stub survives anyway (a power cut, `kill -9`), the next run notices the
existing destination isn't readable audio, says so on stderr, logs it, and
re-converts over it — so a single bad interruption can't block a file forever.
A destination that *is* valid audio is still skipped as before; one that turns
out to be a **directory** is reported as a failure and left untouched.

### Converting several files at once

Conversions run in parallel by default: `decant` spreads a folder across as
many workers as the machine has logical cores. `--jobs N` (or
`DECANT_JOBS=N`) picks a specific worker count instead, and `--jobs auto` —
the default — is spelled out explicitly by `sysctl -n hw.ncpu`, which counts
every core the OS schedules on, so 18 on an M5 Max and 8 on an M1. Anything
above 64 is capped at 64, so a mistyped `--jobs 888` can't fork-bomb the
machine. A value that isn't a positive whole number or `auto` is a usage
error (exit `64`), never quietly rounded to something else.

Measured on an 18-core Apple M5 Max, over 50 files (32 lossless → AIFF,
18 lossy → MP3, ~30 s each), best of two runs:

| `--jobs` | Wall clock | Speedup |
|---------:|-----------:|--------:|
| `1` | 24.0 s | 1.0× |
| `2` | 14.3 s | 1.7× |
| `4` | 8.3 s | 2.9× |
| `8` | 5.7 s | 4.2× |
| `auto` (18, default) | 4.5 s | 5.3× |

Returns flatten past `8` because MP3 encoding is what dominates, and only 18
of those 50 files take that path; the AIFF side is closer to I/O-bound. Your
own ratio of lossless to lossy will move the numbers.

Parallelism used to be opt-in, on the theory that `decant` trashes originals
and concurrency was unproven. It's proven now: the test suite covers
interrupt-under-load, orphan process reaping, and the worker/ffmpeg race
around shutdown, and the Finder Quick Action has been running `--jobs auto`
in production the whole time. A terminal run defaulting to one core was
just giving worse throughput than a right-click in Finder. `--jobs 1` is
still there whenever you want the old behavior back — genuinely serial, one
ffmpeg at a time, the same loop down to the order of the lines it prints.

Under `--jobs` an interrupt still discards **every** destination in flight,
not just one: the run signals each worker and each ffmpeg beneath it, waits
for them all to exit, and only then decides what to delete — an encoder still
running would otherwise write straight back over the file just discarded.
Two sources that target the same output (`track.flac` and `track.wav` both
want `track.aiff`) are kept on one worker in the order the folder listed
them, so the result is the same one a serial run gives: the first converts,
the second finds a valid destination and is skipped.

### Trashing originals

Originals go to the Trash via `NSFileManager`, which uniquifies names itself.
The direct `~/.Trash` fallback (used when that call fails, and for files on
external volumes) picks a free name Finder-style — `01 - Intro 2.flac` — so a
same-named track from another album never overwrites one already in there. If
trashing fails outright, the conversion is still counted as a success, but a
warning and a `TRASH FAILED` log line make clear the original stayed put.

### Why the Quick Action is an Automator workflow

The obvious build is a Shortcut: receive the Finder selection, hand it to a Run
Shell Script action. That works, but macOS then asks *"Allow "Decant" to use 1
folder in a shell script?"* on **every run**. The grant is per folder, so
**Always Allow** never ends it — the next album is a new folder and a new
prompt.

It is not a file-permissions problem. It fires just as readily in `~/Music`,
which needs no privilege at all, so Full Disk Access does not help. Shortcuts
gates shell scripts reaching the Finder selection, full stop. Three wirings
were tried and all three prompt: the selection passed directly, the selection
coerced to its path in place, and the path passed as text out of a separate
action.

Automator services do not go through that gate, so the Quick Action is an
Automator `.workflow` instead. Two details in its `Info.plist` are
load-bearing:

- **`NSIconName`** is what puts the entry under **Quick Actions** with an icon
  rather than in the noisy Services submenu.
- **`NSRequiredContext`** scopes it to Finder, so it doesn't appear everywhere.

<details>
<summary>Why it works in protected folders without Full Disk Access</summary>

A Finder Quick Action runs the script sandboxed. In TCC-protected folders
(Desktop / Documents / Downloads) that sandbox lets a *child* process (ffmpeg)
**create** files but won't let the shell **rename or delete a file ffmpeg
made**. So `decant` has ffmpeg write the output **directly to its final name**
(no temp + rename) and trashes the original via `NSFileManager`, which the
Quick Action's scoped access to the selected file permits.

Earlier versions of this note claimed a hand-built Automator `.workflow` could
only ever register as a *Service* on recent macOS, and that a real Quick Action
therefore had to be a Shortcut. That is wrong: setting `NSIconName` in the
workflow's `Info.plist` puts it under **Quick Actions** with an icon. Verified
on macOS 26.
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

The log rotates itself so it can't grow without bound: once it reaches **2 MB**
the current file is renamed to `decant.log.1` and the run continues in a fresh
one. Exactly one previous generation is kept — the older `decant.log.1` is
discarded. If the rotation can't happen (say the directory isn't writable) the
run carries on and keeps logging; an oversized log is never a reason to fail a
conversion.

## Configuration

| Flag | Env | Effect |
|------|-----|--------|
| `--no-enrich` | `DECANT_NO_ENRICH` | Pure transcode; skip all tag enrichment. |
| `--jobs N` | `DECANT_JOBS` | Convert N files at once. Default `auto` — the machine's logical core count; `--jobs 1` forces serial. Capped at 64 workers. |
| `--dry-run` | — | Preview the tag/conversion plan; write and trash nothing. |
| `--keep` | `DECANT_KEEP_ORIGINALS` | Convert without trashing originals (cautious first pass). |
| `--debug` | `DECANT_DEBUG` | Log every run/conversion/skip, not just errors. |
| `--notify` | — | Post a completion notification (what the Quick Action uses). |
| `-h`, `--help` | — | Print the full usage — flags, env vars, exit codes — and exit. |
| `--version` | — | Print the version and exit. |
| `--` | — | End of options: every remaining argument is a path. |
| — | `DECANT_NO_NOTIFY` | Suppress the completion notification even with `--notify`. |
| — | `DECANT_NO_SOXR` | Resample with ffmpeg's default engine instead of libsoxr. |
| — | `DECANT_LOG` | Override the log file path (used by the test suite). |
| — | `DECANT_TRASH_DIR` | Override the directory the `~/.Trash` fallback moves originals into (used by the test suite). |
| — | `DECANT_FORCE_TRASH_FALLBACK` | Skip `NSFileManager` and always take the `~/.Trash` fallback (used by the test suite). |

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
| `69` | ffmpeg/ffprobe are unavailable and were not installed. |
| `77` | Refused a path that is too broad to recurse (a filesystem or home root). |
| `130` | Interrupted by a signal — `128 + signal`, so `143` for `TERM`, `129` for `HUP`. |

When one run hits several of these, the most severe wins: `1` over `77` over
`66`. So a script or Shortcut can branch on `decant … || handle "$?"` and trust
that a typo or a missing file never reads as success.

> **No stray output files:** as a Finder Quick Action the script runs with
> `--notify` and no terminal, so it writes nothing to stdout/stderr — output
> from a Run Shell Script action has ended up saved beside the converted files
> before now. Results come from the notification and the log instead.

## Uninstall

```sh
brew uninstall decant                 # or: rm ~/.local/bin/decant
rm -f ~/Library/Logs/decant.log
```

```sh
rm -rf ~/Library/Services/Decant.workflow
/System/Library/CoreServices/pbs -update
```

If you also used the older Shortcuts-based Quick Action, delete the **Decant**
shortcut in Shortcuts.app.

## Contributing

Issues and PRs welcome. Run the test suite before submitting:

```sh
./tests/run.sh
```

It generates fixtures with ffmpeg and exercises depth preservation, bitrate
capping, metadata and artwork retention (including the fallback that drops art
the muxer refuses), codec classification, stream mapping, `ffmpeg` resolution
and its bootstrap, enrichment + decoy rejection, recursion, skipping, trashing,
failure handling, logging and its rotation, `install.sh`, the CLI contract (exit
codes, flag parsing), interrupt cleanup, recovery from a stranded destination,
and Trash uniquification. CI syntax-checks every script and runs the same suite
on every PR.

**Nothing of yours is touched.** Fixtures live in a `/tmp` sandbox that is torn
down even if the run is interrupted, `DECANT_LOG` keeps the log out of
`~/Library/Logs`, and almost every assertion runs with `DECANT_KEEP_ORIGINALS`
set. The trash-fallback tests do move fixtures, but `DECANT_TRASH_DIR` sends
them to a throwaway folder rather than your real `~/.Trash`. The tests that must
exercise the *primary* `NSFileManager` path — which resolves the Trash from the
process owner and so ignores any override — mount a small temporary disk image
and run there: macOS trashes files from a non-boot volume into that volume's own
`.Trashes`, so your Trash never sees them, and the image is detached and deleted
afterwards. Where a disk image can't be created, those tests print that they
were skipped rather than falling back to your Trash.

The Quick Action is [`quickaction/Decant.workflow`](quickaction/). It is a
plain bundle — no signing step, unlike the Shortcut it replaced. Edit it either
in Automator (`open -a Automator quickaction/Decant.workflow`) or by editing
`Contents/Info.plist` and `Contents/Resources/document.wflow` directly, then
reinstall with `./install.sh`.

Keep `NSIconName` in the `Info.plist`: without it the entry drops out of the
Quick Actions section into the Services submenu.

## License

[MIT](LICENSE)
