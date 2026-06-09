#!/usr/bin/env zsh
#
# Behavioural tests for toaiff. Non-destructive: TOAIFF_KEEP_ORIGINALS keeps
# source files in place (no Trash side effects) and TOAIFF_LOG redirects the
# log away from ~/Library/Logs. Requires ffmpeg/ffprobe.

emulate -L zsh

TOAIFF="${0:A:h}/../bin/toaiff"
typeset -i pass=0 fail=0

probe() { ffprobe -v error "$@" 2>/dev/null }

assert_eq() {
  # #then compare actual to expected for one logical assertion
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    print -r -- "  ✓ $desc"
    (( pass++ ))
  else
    print -r -- "  ✗ $desc — expected [$expected], got [$actual]"
    (( fail++ ))
  fi
}

assert_true() {
  local desc="$1"; shift
  if "$@"; then
    print -r -- "  ✓ $desc"; (( pass++ ))
  else
    print -r -- "  ✗ $desc"; (( fail++ ))
  fi
}

# #given a sandbox with one representative file per scenario
WORK=$(mktemp -d /tmp/toaiff-tests.XXXXXX)
LOG="$WORK/toaiff.log"
mkdir -p "$WORK/sub"

gen_flac24_with_art() {
  ffmpeg -nostdin -hide_banner -loglevel error \
    -f lavfi -i "sine=frequency=440:duration=1" -sample_fmt s32 -bits_per_raw_sample 24 -c:a flac "$WORK/_t.flac"
  ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "color=c=red:s=64x64:d=1" -frames:v 1 "$WORK/_a.png"
  ffmpeg -nostdin -hide_banner -loglevel error -i "$WORK/_t.flac" -i "$WORK/_a.png" \
    -map 0:a -map 1:v -c copy -disposition:v attached_pic \
    -metadata title="Test Tone" -metadata artist="toaiff" "$WORK/album24.flac"
  rm -f "$WORK/_t.flac" "$WORK/_a.png"
}

gen_flac24_with_art
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=220:duration=1" -c:a pcm_s16le "$WORK/sub/tone16.wav"
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=300:duration=1" -c:a pcm_s24le \
  -metadata title="Wav Meta" -metadata artist="toaiff" "$WORK/tagged24.wav"
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=330:duration=1" -c:a libmp3lame -q:a 4 "$WORK/song.mp3"
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=550:duration=1" -c:a pcm_s16be "$WORK/already.aiff"
print -r -- "not audio" > "$WORK/readme.txt"
: > "$WORK/corrupt.flac"   # 0-byte file with a lossless extension
# A text file whose extension (.al) ffmpeg would otherwise mis-detect as raw
# A-law audio — must be ignored by the extension gate.
print -r -- "frame a = b + c" > "$WORK/notes.al"

# #when the whole tree is converted (recursively, keeping originals)
# (TOAIFF_DEBUG so the verbose CONVERTED/SKIP lines are logged for assertions)
TOAIFF_KEEP_ORIGINALS=1 TOAIFF_DEBUG=1 TOAIFF_LOG="$LOG" "$TOAIFF" "$WORK" >/dev/null
typeset -i run_rc=$?

print -r -- "24-bit FLAC → AIFF"
assert_eq   "produces a pcm_s24be AIFF (depth preserved, no downsampling)" \
            "pcm_s24be" \
            "$(probe -select_streams a:0 -show_entries stream=codec_name -of default=nw=1:nk=1 -- "$WORK/album24.aiff")"
assert_eq   "preserves the title tag" \
            "Test Tone" \
            "$(probe -show_entries format_tags=title -of default=nw=1:nk=1 -- "$WORK/album24.aiff")"
assert_eq   "preserves embedded cover art as a video stream" \
            "png" \
            "$(probe -select_streams v -show_entries stream=codec_name -of default=nw=1:nk=1 -- "$WORK/album24.aiff")"

print -r -- "16-bit WAV in a subfolder"
assert_true "is converted (recursion into subfolders works)" \
            test -f "$WORK/sub/tone16.aiff"

print -r -- "24-bit WAV with metadata"
assert_eq   "converts to pcm_s24be (depth preserved)" \
            "pcm_s24be" \
            "$(probe -select_streams a:0 -show_entries stream=codec_name -of default=nw=1:nk=1 -- "$WORK/tagged24.aiff")"
assert_eq   "carries the WAV title tag into the AIFF" \
            "Wav Meta" \
            "$(probe -show_entries format_tags=title -of default=nw=1:nk=1 -- "$WORK/tagged24.aiff")"

print -r -- "lossy + non-audio + existing AIFF + corrupt"
assert_true "MP3 is left untouched (no sibling AIFF created)" \
            test ! -f "$WORK/song.aiff"
assert_true "non-audio .txt is ignored (no sibling AIFF created)" \
            test ! -f "$WORK/readme.aiff"
assert_eq   "existing AIFF is left bit-identical (skipped, not re-encoded)" \
            "pcm_s16be" \
            "$(probe -select_streams a:0 -show_entries stream=codec_name -of default=nw=1:nk=1 -- "$WORK/already.aiff")"
assert_true "a 0-byte/corrupt .flac is skipped, not failed (no AIFF written)" \
            test ! -f "$WORK/corrupt.aiff"
assert_true "a non-audio .al file is ignored by the extension gate (no AIFF)" \
            test ! -f "$WORK/notes.aiff"
assert_eq   "the run exits 0 even with a corrupt file present" \
            "0" "$run_rc"

print -r -- "originals + logging"
assert_true "originals are preserved when TOAIFF_KEEP_ORIGINALS is set" \
            test -f "$WORK/album24.flac"
assert_true "a CONVERTED entry is written to the log" \
            grep -q "CONVERTED .*album24.flac" "$LOG"
assert_true "a lossy SKIP reason is written to the log (debug run)" \
            grep -q "SKIP (lossy/unsupported: mp3)" "$LOG"

print -r -- "logging: errors-only by default, verbose with --debug"
DD="$WORK/dlog"; mkdir -p "$DD"
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=470:duration=1" -c:a flac "$DD/clean1.flac"
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=471:duration=1" -c:a flac "$DD/clean2.flac"
DLOG="$WORK/d.log"
: > "$DLOG"; TOAIFF_KEEP_ORIGINALS=1 TOAIFF_LOG="$DLOG" "$TOAIFF" "$DD/clean1.flac" >/dev/null 2>&1
assert_true "a clean run writes nothing to the log by default" \
            test ! -s "$DLOG"
: > "$DLOG"; TOAIFF_KEEP_ORIGINALS=1 TOAIFF_DEBUG=1 TOAIFF_LOG="$DLOG" "$TOAIFF" "$DD/clean2.flac" >/dev/null 2>&1
assert_true "--debug logs the conversion" \
            grep -q "CONVERTED" "$DLOG"
: > "$DLOG"; TOAIFF_LOG="$DLOG" "$TOAIFF" "/" >/dev/null 2>&1
assert_true "errors are logged even without --debug (REFUSED)" \
            grep -q "REFUSED" "$DLOG"

print -r -- "concise summary (only the categories that occurred)"
S1="$WORK/s1"; mkdir -p "$S1"
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=440:duration=1" -c:a flac "$S1/a.flac"
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=441:duration=1" -c:a flac "$S1/b.flac"
assert_eq   "all-success shows only the converted count" \
            "toaiff: 2 converted" \
            "$(TOAIFF_KEEP_ORIGINALS=1 TOAIFF_LOG="$LOG" "$TOAIFF" "$S1" 2>&1 >/dev/null | tail -1)"
S2="$WORK/s2"; mkdir -p "$S2"
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=442:duration=1" -c:a flac "$S2/a.flac"
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=443:duration=1" -c:a libmp3lame "$S2/b.mp3"
assert_eq   "mixed run lists converted and skipped" \
            "toaiff: 1 converted · 1 skipped" \
            "$(TOAIFF_KEEP_ORIGINALS=1 TOAIFF_LOG="$LOG" "$TOAIFF" "$S2" 2>&1 >/dev/null | tail -1)"

print -r -- "enrichment: feat. -> ft. normalization (title only, word-anchored)"
assert_eq   "lowercase feat. -> ft." "Lights Out (ft. Romy)" \
            "$("$TOAIFF" --normalize-feat 'Lights Out (feat. Romy)')"
assert_eq   "capital Feat. -> ft." "Track (ft. X)" \
            "$("$TOAIFF" --normalize-feat 'Track (Feat. X)')"
assert_eq   "FEISTY untouched (needs literal dot)" "..FEISTY (ft. Bia)" \
            "$("$TOAIFF" --normalize-feat '..FEISTY (feat. Bia)')"
assert_eq   "idempotent on already-ft." "A (ft. B)" \
            "$("$TOAIFF" --normalize-feat 'A (ft. B)')"

print -r -- "enrichment: catalog detection from folder name (uppercased)"
assert_eq   "[SHA300] bracketed" "SHA300" \
            "$("$TOAIFF" --detect-catalog '[SHA300] VA - 20 Years Of Shogun Audio [2024]')"
assert_eq   "(snf137) lowercase -> SNF137" "SNF137" \
            "$("$TOAIFF" --detect-catalog 'back 2 earth (snf137) (2026) [flac] [24b-44.1khz]')"
assert_eq   "scene paren (FXPLY025)" "FXPLY025" \
            "$("$TOAIFF" --detect-catalog 'Kassian-Grain__Shell_Dub-(FXPLY025)-WEB-2026-PTC')"
assert_eq   "bare scene token USB002" "USB002" \
            "$("$TOAIFF" --detect-catalog 'Fred again.. - USB002 - [2025]')"
assert_eq   "{LLR004} curly braces" "LLR004" \
            "$("$TOAIFF" --detect-catalog 'a.s.o. - a.s.o. remixed (2023) [FLAC] {LLR004}')"
assert_eq   "trailing letters NB011EP" "NB011EP" \
            "$("$TOAIFF" --detect-catalog 'VA - Various Artists, Vol. 2 [NB011EP]')"
assert_eq   "decoy [FLAC 24] -> none" "" \
            "$("$TOAIFF" --detect-catalog 'CHASING LIGHT (2026) [FLAC 24]')"
assert_eq   "decoy year/format only -> none" "" \
            "$("$TOAIFF" --detect-catalog 'Gallows ep (2022) [WEB FLAC]')"
assert_eq   "barcode in braces -> none" "" \
            "$("$TOAIFF" --detect-catalog 'OPN - Tranquilizer (2025) [FLAC] {Warp Records, 5056818805226}')"

print -r -- "enrichment: track/disc from leading filename token only"
assert_eq   "NN - Title -> track" "track=1" \
            "$("$TOAIFF" --derive-track-disc '01 - Adrift.flac')"
assert_eq   "NNN - Artist - Title -> track" "track=3" \
            "$("$TOAIFF" --derive-track-disc '003 - DJ Q - I Couldnt See.flac')"
assert_eq   "(disc - track) form" "disc=1 track=2" \
            "$("$TOAIFF" --derive-track-disc '(01 - 02) Bangarang.aiff')"
assert_eq   "trailing year in title ignored" "track=1" \
            "$("$TOAIFF" --derive-track-disc '01 - 1983.aiff')"
assert_eq   "no leading number -> nothing" "" \
            "$("$TOAIFF" --derive-track-disc '# Dr. Derg - Depression.flac')"

print -r -- "enrichment: end-to-end tagging (catalog folder + feat + folder art)"
EN="$WORK/[ARTKL081] Cadik - Lion Soul (2025)"; mkdir -p "$EN"
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=440:duration=1" \
  -sample_fmt s32 -bits_per_raw_sample 24 -c:a flac \
  -metadata title="Lion Soul (feat. Someone)" "$EN/02 - Lion Soul (feat. Someone).flac"
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "color=c=blue:s=48x48:d=1" -frames:v 1 "$EN/cover.png"
# A sibling that already has track=7 — fill-gaps-only must not overwrite it.
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=330:duration=1" \
  -c:a flac -metadata track=7 -metadata title="Preset" "$EN/05 - Preset.flac"
TOAIFF_KEEP_ORIGINALS=1 TOAIFF_LOG="$LOG" "$TOAIFF" "$EN" >/dev/null 2>&1
ENA="$EN/02 - Lion Soul (feat. Someone).aiff"
ENB="$EN/05 - Preset.aiff"
assert_eq   "catalog -> grouping (uppercased)" "ARTKL081" \
            "$(probe -show_entries format_tags=grouping -of default=nw=1:nk=1 -- "$ENA")"
assert_eq   "track backfilled from filename" "2" \
            "$(probe -show_entries format_tags=track -of default=nw=1:nk=1 -- "$ENA")"
assert_eq   "feat. normalized in title" "Lion Soul (ft. Someone)" \
            "$(probe -show_entries format_tags=title -of default=nw=1:nk=1 -- "$ENA")"
assert_eq   "folder art embedded when source has none" "png" \
            "$(probe -select_streams v -show_entries stream=codec_name -of default=nw=1:nk=1 -- "$ENA")"
assert_eq   "audio depth still preserved alongside enrichment" "pcm_s24be" \
            "$(probe -select_streams a:0 -show_entries stream=codec_name -of default=nw=1:nk=1 -- "$ENA")"
assert_eq   "existing track tag is NOT overwritten (fill-gaps-only)" "7" \
            "$(probe -show_entries format_tags=track -of default=nw=1:nk=1 -- "$ENB")"

print -r -- "enrichment: --dry-run changes nothing"
DR="$WORK/dryrun"; mkdir -p "$DR"
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=460:duration=1" -c:a flac "$DR/01 - Tone.flac"
DROUT="$(TOAIFF_LOG="$LOG" "$TOAIFF" --dry-run "$DR" 2>&1)"
assert_true "dry-run writes no .aiff" \
            test ! -f "$DR/01 - Tone.aiff"
assert_true "dry-run leaves the original in place" \
            test -f "$DR/01 - Tone.flac"
assert_true "dry-run reports the would-convert plan" \
            grep -q "would convert" <<< "$DROUT"

print -r -- "safety: forbidden-root guard (checked without scanning)"
"$TOAIFF" --check-root "/" >/dev/null 2>&1
assert_eq   "refuses /" "0" "$?"
"$TOAIFF" --check-root "$HOME" >/dev/null 2>&1
assert_eq   "refuses \$HOME" "0" "$?"
"$TOAIFF" --check-root "/Volumes" >/dev/null 2>&1
assert_eq   "refuses /Volumes" "0" "$?"
"$TOAIFF" --check-root "$WORK/sub" >/dev/null 2>&1
assert_eq   "allows a normal album folder" "2" "$?"

print -r -- "safety: binary on stdin does nothing (no stdin path-guessing)"
head -c 4096 /dev/urandom | TOAIFF_LOG="$LOG" "$TOAIFF" >/dev/null 2>&1
assert_eq   "no arguments + binary stdin exits with usage code 64, no scan" \
            "64" "$?"

rm -rf "$WORK"

print -r -- ""
print -r -- "Results: ${pass} passed, ${fail} failed"
(( fail == 0 ))
