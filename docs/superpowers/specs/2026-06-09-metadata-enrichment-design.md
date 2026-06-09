# toaiff metadata enrichment — design

## Goal

Extend `toaiff` from a faithful transcoder into a transcoder that also
**enriches ID3 metadata** during conversion, deriving information that is
present in folder/file names but missing from the audio tags. Enrichment is
**default-on** for every conversion (including the Finder Quick Action) and is
governed by a strict **fill-gaps-only** rule so it can never clobber correct
existing tags.

Feasibility verified: `grouping`, `track`, `disc`, and a rewritten `title` all
round-trip through ffmpeg's AIFF/ID3 muxer, and the audio codec is preserved.

## Features

1. **Catalog number → `grouping`** — detected from the parent folder name,
   normalized to **uppercase**.
2. **Track / disc backfill** — parsed from the filename, written only when the
   source lacks them.
3. **`feat.` → `ft.`** — normalized in the `title` only.
4. **Folder artwork embedding** — embed `cover.jpg`/`folder.jpg`/`front.*` from
   the album folder, only when the source has no embedded cover.
5. **`--dry-run`** — print the computed tag plan per file without converting or
   trashing.

Out of scope (YAGNI): track totals (`TRCK n/total`), artist/album backfill,
filename rewriting, barcode capture.

## Architecture

A new **enrichment stage** runs between probing and converting, inside
`process_file`, leaving the faithful-transcode core untouched. The stage reads
existing format tags, computes derived/normalized values, enforces
fill-gaps-only, and produces an ffmpeg argument array consumed by
`convert_file`.

New functions (each independently testable):

| Function | Input | Output |
|----------|-------|--------|
| `detect_catalog` | parent folder name | uppercase catalog token, or empty |
| `derive_track_disc` | filename (no ext) | `track` and/or `disc`, or empty |
| `normalize_feat` | a title string | title with `feat.`→`ft.` |
| `find_folder_art` | album dir | path to a cover image, or empty |
| `build_meta_args` | src path + probed tags | array of ffmpeg `-metadata`/art args |

`convert_file` gains an extra parameter: the metadata-args array (and, when art
is embedded, an extra input + map). Its existing two-attempt structure (full
map → audio-only fallback that sets `ART_DROPPED`) is preserved; folder-art
embedding reuses that fallback so a rejected image never fails the conversion.

**Rejected alternatives:** a Python parsing helper (breaks the self-contained
zsh tool); post-hoc tagging via AtomicParsley/mutagen (extra dependency —
ffmpeg already tags in the same pass).

## Catalog number detection

Source: the file's **immediate parent folder** basename. For a single-file
target, that is the folder the file sits in.

1. Collect candidate tokens from `[...]`, `(...)`, `{...}` groups and from bare
   `-`/`_`-delimited scene tokens.
2. A candidate qualifies iff it matches **letters-then-digits**, case-insensitive:
   `^[A-Za-z]{2,}[-_ ]?[0-9]{2,}[A-Za-z]*$`
   (matches `SHA300`, `FXPLY025`, `snf137`, `NB011EP`).
3. Reject via blocklist (case-insensitive):
   - format/quality words: `FLAC WAV WAVE MP3 AAC ALAC WEB WEBFLAC CD VINYL EP LP VA OST REMIX REMIXES`
   - bit/rate strings: matches `^[0-9]+(B|BIT|KHZ|HZ|KBPS)` or contains `KHZ`/`BIT`
   - 4-digit years: `^(19|20)[0-9]{2}$`
   - pure digits (barcodes/`No. 11110`).
4. Normalize the winner to **uppercase**.
5. If multiple survive: prefer a **bracketed** candidate over a bare one, then
   the **last** bracketed; log the ambiguity at debug level.

Written to `grouping` only when the source has no `grouping` tag.

## Track / disc backfill

Parse the **leading** token of the filename basename only (never a trailing
number such as `01 - 1983`):

1. `^\(\s*0*([0-9]{1,2})\s*-\s*0*([0-9]{1,3})\s*\)` → `disc`=g1, `track`=g2
   (the `(01 - 01)` disc–track form).
2. `^\s*0*([0-9]{1,3})\s*[-._)]` → `track`=g1 (`01 - `, `001 - `, `09 -`).

Reject 4-digit-or-longer leading integers (years). `track` and `disc` are each
written only when the source lacks that tag.

## feat normalization

Case-insensitive, word-anchored replacement of `feat.` with `ft.` in the
**title** value (existing or derived). `FEISTY`, `feature` (no following `.`),
etc. are untouched. This is the **only** transform that edits an existing value
rather than gap-filling; it is idempotent (`ft.` contains no `feat.`).

## Folder artwork

Only when the source has **no** embedded cover (no `attached_pic` video stream):
search the album folder for `cover`, `folder`, `front` with extension
`jpg/jpeg/png` (case-insensitive). If found, add it as a second input mapped as
`attached_pic`. If the AIFF muxer rejects it, the existing `ART_DROPPED`
fallback drops it and the audio still converts.

## CLI / safety

- **`--dry-run`**: prints, per file, the computed tag plan (catalog, track,
  disc, title change, art source) and exits without running ffmpeg or trashing
  anything. The dry-run printer and the real arg-builder share one code path so
  tests assert against the same logic that runs in production.
- Enrichment is **default-on everywhere**; there is no disable flag (per user
  choice). `TOAIFF_KEEP_ORIGINALS` and `--debug` behave as before.
- **Idempotent**: fill-gaps-only derivation plus idempotent feat-normalization
  means re-running on the same inputs is stable.

## Logging

Errors-only by default (unchanged). At `--debug`: each derived/normalized tag
and the reason, plus catalog-ambiguity notes.

## Testing

Extend `tests/run.sh` (non-destructive: `TOAIFF_KEEP_ORIGINALS`, `TOAIFF_LOG`)
with fixtures whose **folder names** carry catalog + decoy patterns and whose
**filenames** carry track/disc/feat patterns, plus a no-embedded-art file beside
a `cover.jpg`. Assertions:

- catalog `[SHA300]` / `(snf137)` / bare `USB002` → `grouping=SHA300` etc.;
  decoys (`[FLAC 24]`, `(2026)`, `[EP]`, barcode) produce **no** grouping.
- `01 - Title.flac` → `track=1`; `(01 - 02) Title.flac` → `disc=1 track=2`;
  `01 - 1983.flac` → `track=1` (trailing year ignored).
- existing track tag is **not** overwritten (fill-gaps-only).
- `… (feat. X).flac` title → `… (ft. X)`; `FEISTY` untouched.
- no-embedded-art file + folder `cover.jpg` → AIFF gains a `png/mjpeg` video
  stream; a file that already has art is unchanged.
- `--dry-run` writes no `.aiff` and trashes nothing.

Parser functions are also exercised directly through `--dry-run` output.
