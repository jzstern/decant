#!/usr/bin/env zsh
#
# Behavioural tests for decant. Non-destructive: DECANT_KEEP_ORIGINALS keeps
# source files in place (no Trash side effects) and DECANT_LOG redirects the
# log away from ~/Library/Logs. Requires ffmpeg/ffprobe.

emulate -L zsh

DECANT="${0:A:h}/../bin/decant"
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
WORK=$(mktemp -d /tmp/decant-tests.XXXXXX)
LOG="$WORK/decant.log"
mkdir -p "$WORK/sub"

gen_flac24_with_art() {
  ffmpeg -nostdin -hide_banner -loglevel error \
    -f lavfi -i "sine=frequency=440:duration=1" -sample_fmt s32 -bits_per_raw_sample 24 -c:a flac "$WORK/_t.flac"
  ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "color=c=red:s=64x64:d=1" -frames:v 1 "$WORK/_a.png"
  ffmpeg -nostdin -hide_banner -loglevel error -i "$WORK/_t.flac" -i "$WORK/_a.png" \
    -map 0:a -map 1:v -c copy -disposition:v attached_pic \
    -metadata title="Test Tone" -metadata artist="decant" "$WORK/album24.flac"
  rm -f "$WORK/_t.flac" "$WORK/_a.png"
}

gen_flac24_with_art
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=220:duration=1" -c:a pcm_s16le "$WORK/sub/tone16.wav"
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=300:duration=1" -c:a pcm_s24le \
  -metadata title="Wav Meta" -metadata artist="decant" "$WORK/tagged24.wav"
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=330:duration=1" -c:a libmp3lame -q:a 4 "$WORK/song.mp3"
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=550:duration=1" -c:a pcm_s16be "$WORK/already.aiff"
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=600:duration=2" -c:a aac -b:a 160k \
  -metadata title="Aac Meta" -metadata artist="decant" "$WORK/pop.m4a"
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=610:duration=1" -c:a alac "$WORK/alactrack.m4a"
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=620:duration=2" -c:a libopus -b:a 96k \
  -metadata title="Opus Meta" "$WORK/voice.opus"
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=630:duration=2" -ar 22050 -c:a aac -b:a 48k \
  "$WORK/lofi.m4a"
# Same audio packets as voice.opus but with a huge tag — the container-average
# bitrate is inflated, the audio-only measurement must not be.
ffmpeg -nostdin -hide_banner -loglevel error -i "$WORK/voice.opus" -map 0:a -c copy \
  -metadata title="${(l:131072::x:)}" "$WORK/padded.opus"
print -r -- "not audio" > "$WORK/readme.txt"
: > "$WORK/corrupt.flac"   # 0-byte file with a lossless extension
# A text file whose extension (.al) ffmpeg would otherwise mis-detect as raw
# A-law audio — must be ignored by the extension gate.
print -r -- "frame a = b + c" > "$WORK/notes.al"

# #when the whole tree is converted (recursively, keeping originals)
# (DECANT_DEBUG so the verbose CONVERTED/SKIP lines are logged for assertions)
DECANT_KEEP_ORIGINALS=1 DECANT_DEBUG=1 DECANT_LOG="$LOG" "$DECANT" "$WORK" >/dev/null
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

print -r -- "lossy m4a/opus → MP3 (bitrate-capped, metadata preserved)"
assert_eq   "AAC .m4a converts to an MP3" \
            "mp3" \
            "$(probe -select_streams a:0 -show_entries stream=codec_name -of default=nw=1:nk=1 -- "$WORK/pop.mp3")"
assert_eq   "carries the m4a title tag into the MP3" \
            "Aac Meta" \
            "$(probe -show_entries format_tags=title -of default=nw=1:nk=1 -- "$WORK/pop.mp3")"
assert_eq   "carries the m4a artist tag into the MP3" \
            "decant" \
            "$(probe -show_entries format_tags=artist -of default=nw=1:nk=1 -- "$WORK/pop.mp3")"
M4A_BR="$(probe -select_streams a:0 -show_entries stream=bit_rate -of default=nw=1:nk=1 -- "$WORK/pop.m4a")"
MP3_BR="$(probe -select_streams a:0 -show_entries stream=bit_rate -of default=nw=1:nk=1 -- "$WORK/pop.mp3")"
assert_true "MP3 bitrate does not exceed the m4a source (no upscaling)" \
            test "${MP3_BR:-999999999}" -le "${M4A_BR:-0}"
assert_eq   ".opus converts to an MP3" \
            "mp3" \
            "$(probe -select_streams a:0 -show_entries stream=codec_name -of default=nw=1:nk=1 -- "$WORK/voice.mp3")"
assert_eq   "carries the opus title tag into the MP3" \
            "Opus Meta" \
            "$(probe -show_entries format_tags=title -of default=nw=1:nk=1 -- "$WORK/voice.mp3")"
OPUS_BR="$(probe -show_entries format=bit_rate -of default=nw=1:nk=1 -- "$WORK/voice.opus")"
OMP3_BR="$(probe -select_streams a:0 -show_entries stream=bit_rate -of default=nw=1:nk=1 -- "$WORK/voice.mp3")"
assert_true "MP3 bitrate does not exceed the opus source (no upscaling)" \
            test "${OMP3_BR:-999999999}" -le "${OPUS_BR:-0}"
assert_eq   "tag-padded opus gets the same cap as its identical-audio twin" \
            "$OMP3_BR" \
            "$(probe -select_streams a:0 -show_entries stream=bit_rate -of default=nw=1:nk=1 -- "$WORK/padded.mp3")"
assert_true "ALAC .m4a still becomes AIFF (lossless path unchanged)" \
            test -f "$WORK/alactrack.aiff"
assert_true "ALAC .m4a does not get an MP3" \
            test ! -f "$WORK/alactrack.mp3"

print -r -- "CDJ compatibility (sample rates in the 32/44.1/48kHz set)"
assert_eq   "48kHz opus keeps its native rate (48k is CDJ-supported)" "48000" \
            "$(probe -select_streams a:0 -show_entries stream=sample_rate -of default=nw=1:nk=1 -- "$WORK/voice.mp3")"
assert_eq   "22.05kHz m4a is resampled to 44.1kHz for CDJ playback" "44100" \
            "$(probe -select_streams a:0 -show_entries stream=sample_rate -of default=nw=1:nk=1 -- "$WORK/lofi.mp3")"

print -r -- "mp3 bitrate cap (highest standard rate ≤ source, 320 max)"
assert_eq   "unknown source bitrate -> 320" "320" "$("$DECANT" --mp3-bitrate '')"
assert_eq   "1411kbps (CD) -> capped at 320" "320" "$("$DECANT" --mp3-bitrate 1411000)"
assert_eq   "exactly 256k -> 256" "256" "$("$DECANT" --mp3-bitrate 256000)"
assert_eq   "129k -> 128 (rounded down, never up)" "128" "$("$DECANT" --mp3-bitrate 129000)"
assert_eq   "127k -> 112 (next standard rate below)" "112" "$("$DECANT" --mp3-bitrate 127000)"
assert_eq   "8k -> floor of 32" "32" "$("$DECANT" --mp3-bitrate 8000)"

print -r -- "originals + logging"
assert_true "originals are preserved when DECANT_KEEP_ORIGINALS is set" \
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
: > "$DLOG"; DECANT_KEEP_ORIGINALS=1 DECANT_LOG="$DLOG" "$DECANT" "$DD/clean1.flac" >/dev/null 2>&1
assert_true "a clean run writes nothing to the log by default" \
            test ! -s "$DLOG"
: > "$DLOG"; DECANT_KEEP_ORIGINALS=1 DECANT_DEBUG=1 DECANT_LOG="$DLOG" "$DECANT" "$DD/clean2.flac" >/dev/null 2>&1
assert_true "--debug logs the conversion" \
            grep -q "CONVERTED" "$DLOG"
: > "$DLOG"; DECANT_LOG="$DLOG" "$DECANT" "/" >/dev/null 2>&1
assert_true "errors are logged even without --debug (REFUSED)" \
            grep -q "REFUSED" "$DLOG"

print -r -- "concise summary (only the categories that occurred)"
S1="$WORK/s1"; mkdir -p "$S1"
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=440:duration=1" -c:a flac "$S1/a.flac"
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=441:duration=1" -c:a flac "$S1/b.flac"
assert_eq   "all-success shows only the converted count" \
            "decant: 2 converted" \
            "$(DECANT_KEEP_ORIGINALS=1 DECANT_LOG="$LOG" "$DECANT" "$S1" 2>&1 >/dev/null | tail -1)"
S2="$WORK/s2"; mkdir -p "$S2"
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=442:duration=1" -c:a flac "$S2/a.flac"
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=443:duration=1" -c:a libmp3lame "$S2/b.mp3"
assert_eq   "mixed run lists converted and skipped" \
            "decant: 1 converted · 1 skipped" \
            "$(DECANT_KEEP_ORIGINALS=1 DECANT_LOG="$LOG" "$DECANT" "$S2" 2>&1 >/dev/null | tail -1)"

print -r -- "enrichment: feat. -> ft. normalization (title only, word-anchored)"
assert_eq   "lowercase feat. -> ft." "Lights Out (ft. Romy)" \
            "$("$DECANT" --normalize-feat 'Lights Out (feat. Romy)')"
assert_eq   "capital Feat. -> ft." "Track (ft. X)" \
            "$("$DECANT" --normalize-feat 'Track (Feat. X)')"
assert_eq   "FEISTY untouched (needs literal dot)" "..FEISTY (ft. Bia)" \
            "$("$DECANT" --normalize-feat '..FEISTY (feat. Bia)')"
assert_eq   "idempotent on already-ft." "A (ft. B)" \
            "$("$DECANT" --normalize-feat 'A (ft. B)')"

print -r -- "enrichment: catalog detection from folder name (uppercased)"
assert_eq   "[SHA300] bracketed" "SHA300" \
            "$("$DECANT" --detect-catalog '[SHA300] VA - 20 Years Of Shogun Audio [2024]')"
assert_eq   "(snf137) lowercase -> SNF137" "SNF137" \
            "$("$DECANT" --detect-catalog 'back 2 earth (snf137) (2026) [flac] [24b-44.1khz]')"
assert_eq   "scene paren (FXPLY025)" "FXPLY025" \
            "$("$DECANT" --detect-catalog 'Kassian-Grain__Shell_Dub-(FXPLY025)-WEB-2026-PTC')"
assert_eq   "bare scene token USB002" "USB002" \
            "$("$DECANT" --detect-catalog 'Fred again.. - USB002 - [2025]')"
assert_eq   "{LLR004} curly braces" "LLR004" \
            "$("$DECANT" --detect-catalog 'a.s.o. - a.s.o. remixed (2023) [FLAC] {LLR004}')"
assert_eq   "trailing letters NB011EP" "NB011EP" \
            "$("$DECANT" --detect-catalog 'VA - Various Artists, Vol. 2 [NB011EP]')"
assert_eq   "decoy [FLAC 24] -> none" "" \
            "$("$DECANT" --detect-catalog 'CHASING LIGHT (2026) [FLAC 24]')"
assert_eq   "decoy year/format only -> none" "" \
            "$("$DECANT" --detect-catalog 'Gallows ep (2022) [WEB FLAC]')"
assert_eq   "barcode in braces -> none" "" \
            "$("$DECANT" --detect-catalog 'OPN - Tranquilizer (2025) [FLAC] {Warp Records, 5056818805226}')"

print -r -- "enrichment: track/disc from leading filename token only"
assert_eq   "NN - Title -> track" "track=1" \
            "$("$DECANT" --derive-track-disc '01 - Adrift.flac')"
assert_eq   "NNN - Artist - Title -> track" "track=3" \
            "$("$DECANT" --derive-track-disc '003 - DJ Q - I Couldnt See.flac')"
assert_eq   "(disc - track) form" "disc=1 track=2" \
            "$("$DECANT" --derive-track-disc '(01 - 02) Bangarang.aiff')"
assert_eq   "trailing year in title ignored" "track=1" \
            "$("$DECANT" --derive-track-disc '01 - 1983.aiff')"
assert_eq   "no leading number -> nothing" "" \
            "$("$DECANT" --derive-track-disc '# Dr. Derg - Depression.flac')"

print -r -- "enrichment: end-to-end tagging (catalog folder + feat + folder art)"
EN="$WORK/[ARTKL081] Cadik - Lion Soul (2025)"; mkdir -p "$EN"
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=440:duration=1" \
  -sample_fmt s32 -bits_per_raw_sample 24 -c:a flac \
  -metadata title="Lion Soul (feat. Someone)" "$EN/02 - Lion Soul (feat. Someone).flac"
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "color=c=blue:s=48x48:d=1" -frames:v 1 "$EN/cover.png"
# A sibling that already has track=7 — fill-gaps-only must not overwrite it.
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=330:duration=1" \
  -c:a flac -metadata track=7 -metadata title="Preset" "$EN/05 - Preset.flac"
# A lossy sibling — enrichment must apply on the MP3 path too.
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=520:duration=2" \
  -c:a aac -b:a 128k -metadata title="Lion Dub" "$EN/03 - Lion Dub.m4a"
DECANT_KEEP_ORIGINALS=1 DECANT_LOG="$LOG" "$DECANT" "$EN" >/dev/null 2>&1
ENA="$EN/02 - Lion Soul (feat. Someone).aiff"
ENB="$EN/05 - Preset.aiff"
ENC="$EN/03 - Lion Dub.mp3"
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
assert_eq   "catalog grouping written to the MP3 too" "ARTKL081" \
            "$(probe -show_entries format_tags=grouping -of default=nw=1:nk=1 -- "$ENC")"
assert_eq   "track backfilled into the MP3 too" "3" \
            "$(probe -show_entries format_tags=track -of default=nw=1:nk=1 -- "$ENC")"
assert_eq   "folder art embedded into the MP3 as JPEG (CDJs ignore PNG APIC)" "mjpeg" \
            "$(probe -select_streams v -show_entries stream=codec_name -of default=nw=1:nk=1 -- "$ENC")"

print -r -- "enrichment: --dry-run changes nothing"
DR="$WORK/dryrun"; mkdir -p "$DR"
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=460:duration=1" -c:a flac "$DR/01 - Tone.flac"
DROUT="$(DECANT_LOG="$LOG" "$DECANT" --dry-run "$DR" 2>&1)"
assert_true "dry-run writes no .aiff" \
            test ! -f "$DR/01 - Tone.aiff"
assert_true "dry-run leaves the original in place" \
            test -f "$DR/01 - Tone.flac"
assert_true "dry-run reports the would-convert plan" \
            grep -q "would convert" <<< "$DROUT"

print -r -- "--version prints the version and exits 0"
assert_true "version string looks like 'decant N.N.N'" \
            grep -qE '^decant [0-9]+\.[0-9]+\.[0-9]+$' <<< "$("$DECANT" --version)"

print -r -- "--no-enrich does a pure transcode (no derived/normalized tags)"
NE="$WORK/[ARTKL099] NoEnrich Test"; mkdir -p "$NE"
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=440:duration=1" \
  -sample_fmt s32 -bits_per_raw_sample 24 -c:a flac \
  -metadata title="Lion Soul (feat. Someone)" "$NE/02 - Lion Soul (feat. Someone).flac"
DECANT_KEEP_ORIGINALS=1 DECANT_LOG="$LOG" "$DECANT" --no-enrich "$NE" >/dev/null 2>&1
NEA="$NE/02 - Lion Soul (feat. Someone).aiff"
assert_eq   "no catalog grouping written under --no-enrich" "" \
            "$(probe -show_entries format_tags=grouping -of default=nw=1:nk=1 -- "$NEA")"
assert_eq   "no track backfilled under --no-enrich" "" \
            "$(probe -show_entries format_tags=track -of default=nw=1:nk=1 -- "$NEA")"
assert_eq   "title untouched (feat. NOT normalized) under --no-enrich" "Lion Soul (feat. Someone)" \
            "$(probe -show_entries format_tags=title -of default=nw=1:nk=1 -- "$NEA")"
assert_eq   "audio bit depth still preserved under --no-enrich" "pcm_s24be" \
            "$(probe -select_streams a:0 -show_entries stream=codec_name -of default=nw=1:nk=1 -- "$NEA")"
assert_true "DECANT_NO_ENRICH env matches the flag (dry-run shows no plan)" \
            test -z "$(DECANT_NO_ENRICH=1 DECANT_LOG="$LOG" "$DECANT" --dry-run "$NE" 2>&1 | grep 'grouping=')"

print -r -- "quick action: --notify with no TTY writes nothing to stdout/stderr"
QA="$WORK/qa"; mkdir -p "$QA"
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=450:duration=1" -c:a flac "$QA/01 - Tone.flac"
# $(...) gives the script a non-TTY stdout/stderr, exactly like the Finder Quick
# Action's captured streams (which otherwise become a stray stdout/stderr.txt).
QAOUT="$(DECANT_KEEP_ORIGINALS=1 DECANT_NO_NOTIFY=1 DECANT_LOG="$LOG" "$DECANT" --notify "$QA" 2>&1)"
assert_eq   "no captured output under --notify (no stray stdout/stderr.txt)" \
            "" "$QAOUT"
assert_true "conversion still happens silently under --notify" \
            test -f "$QA/01 - Tone.aiff"
assert_true "interactive run (no --notify) still prints its summary" \
            grep -q "decant:" <<< "$(DECANT_KEEP_ORIGINALS=1 DECANT_LOG="$LOG" "$DECANT" "$WORK/s1" 2>&1)"

# #given the bundled Finder shortcut, which must find the CLI whether it was
# installed by Homebrew (/opt/homebrew|/usr/local/bin) or install.sh (~/.local/bin)
print -r -- "quick action shortcut: resolves the CLI regardless of install location"
PLIST="${0:A:h}/../shortcut/decant.shortcut.plist"
assert_true "shortcut puts Homebrew bin on PATH (works for brew installs)" \
            grep -q '/opt/homebrew/bin' "$PLIST"
assert_true "shortcut invokes decant via PATH, not a hardcoded path" \
            grep -q 'exec decant --notify' "$PLIST"
assert_eq   "shortcut no longer hardcodes the ~/.local-only invocation" "0" \
            "$(grep -c '"$HOME/.local/bin/decant" --notify' "$PLIST")"

print -r -- "safety: forbidden-root guard (checked without scanning)"
"$DECANT" --check-root "/" >/dev/null 2>&1
assert_eq   "refuses /" "0" "$?"
"$DECANT" --check-root "$HOME" >/dev/null 2>&1
assert_eq   "refuses \$HOME" "0" "$?"
"$DECANT" --check-root "/Volumes" >/dev/null 2>&1
assert_eq   "refuses /Volumes" "0" "$?"
"$DECANT" --check-root "$WORK/sub" >/dev/null 2>&1
assert_eq   "allows a normal album folder" "2" "$?"

print -r -- "safety: binary on stdin does nothing (no stdin path-guessing)"
head -c 4096 /dev/urandom | DECANT_LOG="$LOG" "$DECANT" >/dev/null 2>&1
assert_eq   "no arguments + binary stdin exits with usage code 64, no scan" \
            "64" "$?"

print -r -- "CLI contract: --help / -h"
HELP_OUT="$("$DECANT" --help)"
assert_eq   "--help exits 0" "0" "$?"
"$DECANT" -h >/dev/null 2>&1
assert_eq   "-h exits 0" "0" "$?"
assert_eq   "-h prints exactly the same usage as --help" \
            "$HELP_OUT" "$("$DECANT" -h)"
assert_eq   "usage goes to stdout, leaving stderr clean" "" \
            "$("$DECANT" --help 2>&1 >/dev/null)"
for FLAG in --notify --debug --dry-run --no-enrich --version '-h, --help'; do
  assert_true "--help documents $FLAG" grep -qF -- "$FLAG" <<< "$HELP_OUT"
done
assert_true "--help documents the -- end-of-options marker" \
            grep -qE '^  --  +Treat' <<< "$HELP_OUT"
assert_true "--help documents the environment variables" \
            grep -qF -- "DECANT_KEEP_ORIGINALS" <<< "$HELP_OUT"
assert_true "--help documents the exit-status contract" \
            grep -qF -- "Exit status:" <<< "$HELP_OUT"
assert_true "--help shows worked examples" \
            grep -qF -- "decant --dry-run ~/Music/Album" <<< "$HELP_OUT"

print -r -- "CLI contract: exit codes"
EX="$WORK/exitcodes"; mkdir -p "$EX"
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=480:duration=1" -c:a flac "$EX/clean.flac"
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=481:duration=1" -c:a flac "$EX/mixed.flac"
DECANT_KEEP_ORIGINALS=1 DECANT_LOG="$LOG" "$DECANT" "$EX/clean.flac" >/dev/null 2>&1
assert_eq   "a clean conversion exits 0" "0" "$?"
DECANT_KEEP_ORIGINALS=1 DECANT_LOG="$LOG" "$DECANT" "$WORK/song.mp3" >/dev/null 2>&1
assert_eq   "a run that only skips exits 0 (skipping is not an error)" "0" "$?"
DECANT_LOG="$LOG" "$DECANT" --dry-run "$EX" >/dev/null 2>&1
assert_eq   "a clean --dry-run exits 0" "0" "$?"
"$DECANT" --version >/dev/null 2>&1
assert_eq   "--version exits 0" "0" "$?"
DECANT_LOG="$LOG" "$DECANT" "$WORK/no-such-file.flac" >/dev/null 2>&1
assert_eq   "a path that does not exist exits 66" "66" "$?"
DECANT_LOG="$LOG" "$DECANT" --dry-run "$WORK/no-such-file.flac" >/dev/null 2>&1
assert_eq   "--dry-run over a missing path still exits 66" "66" "$?"
DECANT_LOG="$LOG" "$DECANT" "/" >/dev/null 2>&1
assert_eq   "a refused forbidden root exits 77" "77" "$?"
DECANT_LOG="$LOG" "$DECANT" >/dev/null 2>&1 </dev/null
assert_eq   "no arguments exits 64" "64" "$?"
DECANT_LOG="$LOG" "$DECANT" --dry-run >/dev/null 2>&1 </dev/null
assert_eq   "a flag with no path exits 64" "64" "$?"
DECANT_LOG="$LOG" "$DECANT" --notifyy "$EX" >/dev/null 2>&1
assert_eq   "an unknown option exits 64" "64" "$?"
DECANT_KEEP_ORIGINALS=1 DECANT_LOG="$LOG" "$DECANT" "$EX/mixed.flac" "$WORK/no-such-file.flac" >/dev/null 2>&1
assert_eq   "a good conversion beside a missing path still exits 66" "66" "$?"
assert_true "...and the good file was converted anyway" \
            test -f "$EX/mixed.aiff"
DECANT_LOG="$LOG" "$DECANT" "$WORK/song.mp3" "$WORK/no-such-file.flac" >/dev/null 2>&1
assert_eq   "skips do not mask a missing path" "66" "$?"
DECANT_LOG="$LOG" "$DECANT" "$WORK/no-such-file.flac" "/" >/dev/null 2>&1
assert_eq   "a refusal outranks a missing path" "77" "$?"
# A read-only folder is the cheapest real conversion failure: ffmpeg cannot
# create the output, so nothing is trashed and the run has to say so.
RO="$WORK/readonly"; mkdir -p "$RO"
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=482:duration=1" -c:a flac "$RO/t.flac"
chmod a-w "$RO"
DECANT_KEEP_ORIGINALS=1 DECANT_LOG="$LOG" "$DECANT" "$RO/t.flac" >/dev/null 2>&1
assert_eq   "a conversion failure exits 1" "1" "$?"
DECANT_KEEP_ORIGINALS=1 DECANT_LOG="$LOG" "$DECANT" "$RO/t.flac" "$WORK/no-such-file.flac" >/dev/null 2>&1
assert_eq   "a conversion failure outranks a missing path" "1" "$?"
assert_true "the original survives a failed conversion" \
            test -f "$RO/t.flac"
chmod u+w "$RO"

print -r -- "CLI contract: unknown options are rejected, never treated as paths"
UNK_ERR="$(DECANT_LOG="$LOG" "$DECANT" --notifyy "$WORK" 2>&1 >/dev/null)"
assert_true "the error names the offending option" \
            grep -qF -- "unknown option: --notifyy" <<< "$UNK_ERR"
assert_true "the error points at --help" \
            grep -qF -- "--help" <<< "$UNK_ERR"
assert_true "a typo is never reported as a missing path" \
            test -z "$(grep 'not found' <<< "$UNK_ERR")"
"$DECANT" -x "$WORK" >/dev/null 2>&1
assert_eq   "a mistyped short option exits 64" "64" "$?"
"$DECANT" --dry-runn "$WORK" >/dev/null 2>&1
assert_eq   "a near-miss of a real flag exits 64" "64" "$?"
"$DECANT" "$WORK" --notifyy >/dev/null 2>&1
assert_eq   "an unknown option after a path is still rejected" "64" "$?"
UO="$WORK/unknownopt"; mkdir -p "$UO"
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=483:duration=1" -c:a flac "$UO/01 - Tone.flac"
DECANT_KEEP_ORIGINALS=1 DECANT_LOG="$LOG" "$DECANT" --notifyy "$UO" >/dev/null 2>&1
assert_true "a rejected run converts nothing at all" \
            test ! -f "$UO/01 - Tone.aiff"

print -r -- "CLI contract: -- ends option parsing"
DASH="$WORK/dashnames"; mkdir -p "$DASH"
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=484:duration=1" -c:a flac "$DASH/-foo.flac"
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=485:duration=1" -c:a flac "$DASH/-bar.flac"
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=486:duration=1" -c:a flac "$DASH/--notify.flac"
# Only a *relative* name exercises this — an absolute path never starts with a dash.
( cd "$DASH" && DECANT_KEEP_ORIGINALS=1 DECANT_LOG="$LOG" "$DECANT" -- -foo.flac >/dev/null 2>&1 )
assert_eq   "a file named -foo.flac converts when passed after --" "0" "$?"
assert_true "...and its .aiff lands beside it" \
            test -f "$DASH/-foo.aiff"
( cd "$DASH" && DECANT_KEEP_ORIGINALS=1 DECANT_LOG="$LOG" "$DECANT" -- --notify.flac >/dev/null 2>&1 )
assert_true "a filename beginning with -- is a path after --, not a flag" \
            test -f "$DASH/--notify.aiff"
( cd "$DASH" && DECANT_LOG="$LOG" "$DECANT" -foo.flac >/dev/null 2>&1 )
assert_eq   "the same name without -- is rejected as an option" "64" "$?"
"$DECANT" -- >/dev/null 2>&1 </dev/null
assert_eq   "-- with nothing after it is a usage error" "64" "$?"
DASH_DRY="$( cd "$DASH" && DECANT_LOG="$LOG" "$DECANT" --dry-run -- -bar.flac 2>&1 )"
assert_true "options before -- are still honoured" \
            grep -q "would convert" <<< "$DASH_DRY"
assert_true "...and that --dry-run wrote nothing" \
            test ! -f "$DASH/-bar.aiff"

print -r -- "CLI contract: option placement, repeats, and --version"
FA="$WORK/flagorder"; mkdir -p "$FA"
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=487:duration=1" -c:a flac "$FA/01 - Tone.flac"
FA_OUT="$(DECANT_LOG="$LOG" "$DECANT" "$FA" --dry-run 2>&1)"
assert_true "a flag placed after the path still takes effect" \
            test ! -f "$FA/01 - Tone.aiff"
assert_true "...and the dry-run plan is still printed" \
            grep -q "would convert" <<< "$FA_OUT"
DECANT_LOG="$LOG" "$DECANT" --dry-run --dry-run "$FA" >/dev/null 2>&1
assert_eq   "a repeated flag is harmless" "0" "$?"
DECANT_KEEP_ORIGINALS=1 DECANT_LOG="$LOG" "$DECANT" --no-enrich --no-enrich --debug "$FA" >/dev/null 2>&1
assert_eq   "repeated and combined flags all parse" "0" "$?"
assert_true "--version still prints the version when it follows another flag" \
            grep -qE '^decant [0-9]+\.[0-9]+\.[0-9]+$' <<< "$("$DECANT" --debug --version)"
"$DECANT" --version "$WORK/no-such-file.flac" >/dev/null 2>&1
assert_eq   "--version short-circuits before any path is read" "0" "$?"
"$DECANT" --dry-run --version >/dev/null 2>&1
assert_eq   "--version combined with --dry-run exits 0" "0" "$?"

print -r -- "CLI contract: hidden diagnostics survive the option check"
for HD in --detect-catalog --derive-track-disc --normalize-feat --mp3-bitrate; do
  "$DECANT" "$HD" '' >/dev/null 2>&1
  assert_eq "$HD dispatches instead of being rejected as an option" "0" "$?"
done
"$DECANT" --check-root "$WORK/sub" >/dev/null 2>&1
assert_eq   "--check-root dispatches instead of being rejected as an option" "2" "$?"

print -r -- "mp3 bitrate: only digits reach zsh arithmetic"
assert_eq   "letters are not a bitrate (unmeasurable -> 320)" "320" \
            "$("$DECANT" --mp3-bitrate abc)"
assert_eq   "a negative number is not a bitrate" "320" \
            "$("$DECANT" --mp3-bitrate -5)"
assert_eq   "a decimal is not a bitrate" "320" \
            "$("$DECANT" --mp3-bitrate 12.5)"
assert_eq   "digits with a trailing unit are not a bitrate" "320" \
            "$("$DECANT" --mp3-bitrate 256000k)"
assert_eq   "a space-padded number is not a bitrate" "320" \
            "$("$DECANT" --mp3-bitrate ' 256000 ')"
# zsh reads a bare word in arithmetic as a variable name and keeps expanding it,
# so a value that happens to name a variable must never reach the comparison.
assert_eq   "'converted' names a counter in the script but is not a bitrate" "320" \
            "$("$DECANT" --mp3-bitrate converted)"
assert_eq   "'skipped' names a counter in the script but is not a bitrate" "320" \
            "$("$DECANT" --mp3-bitrate skipped)"
assert_eq   "'PATH' expands to a string but is not a bitrate" "320" \
            "$("$DECANT" --mp3-bitrate PATH)"
assert_eq   "no arithmetic error leaks out on a variable-shaped input" "" \
            "$("$DECANT" --mp3-bitrate PATH 2>&1 >/dev/null)"
assert_eq   "real digits still cap normally after the guard" "192" \
            "$("$DECANT" --mp3-bitrate 200000)"

# ffmpeg decodes Shorten and DSD but cannot encode either, so no fixture can be
# generated for them — the classifier is unit-tested through the hidden dispatch
# instead (same trick as --mp3-bitrate above).
print -r -- "codec classification (lossless / DSD / lossy)"
assert_eq   "shorten is lossless, so .shn takes the AIFF path" "lossless" \
            "$("$DECANT" --classify-codec shorten)"
assert_eq   "dsd_lsbf is recognised as DSD, not lumped in with lossy" "dsd" \
            "$("$DECANT" --classify-codec dsd_lsbf)"
assert_eq   "dsd_msbf is recognised as DSD" "dsd" \
            "$("$DECANT" --classify-codec dsd_msbf)"
assert_eq   "dsd_lsbf_planar is recognised as DSD" "dsd" \
            "$("$DECANT" --classify-codec dsd_lsbf_planar)"
assert_eq   "dsd_msbf_planar is recognised as DSD" "dsd" \
            "$("$DECANT" --classify-codec dsd_msbf_planar)"
assert_eq   "any pcm_* variant is lossless" "lossless" \
            "$("$DECANT" --classify-codec pcm_f64be)"
assert_eq   "an unknown codec is never treated as lossless" "lossy" \
            "$("$DECANT" --classify-codec some_future_codec)"
assert_eq   "an empty codec is never treated as lossless" "lossy" \
            "$("$DECANT" --classify-codec '')"

# #given every extension the gate accepts, paired with a codec a file of that
# extension really holds, and the class that codec must land in. An extension
# accepted here but classified into no handled path is a dead end: the file is
# probed and then rejected with a reason that isn't true of it.
EXT_TABLE=(
  flac:flac:lossless      wav:pcm_s16le:lossless  wave:pcm_s16le:lossless
  w64:pcm_s16le:lossless  rf64:pcm_s16le:lossless bwf:pcm_s16le:lossless
  aif:pcm_s16be:lossless  aiff:pcm_s16be:lossless aifc:pcm_s16be:lossless
  m4a:alac:lossless       m4b:alac:lossless       mp4:alac:lossless
  caf:pcm_s16be:lossless  alac:alac:lossless      ape:ape:lossless
  wv:wavpack:lossless     tak:tak:lossless        tta:tta:lossless
  mlp:mlp:lossless        thd:truehd:lossless     shn:shorten:lossless
  dsf:dsd_lsbf:dsd        dff:dsd_msbf:dsd
  mp3:mp3:lossy           aac:aac:lossy           ogg:vorbis:lossy
  oga:vorbis:lossy        opus:opus:lossy         wma:wmav2:lossy
  ac3:ac3:lossy           eac3:eac3:lossy         dts:dca:lossy
  mka:vorbis:lossy
)

# Echo the offending rows (nothing when the whole table agrees), so a failure
# names the extension instead of just the count.
ext_table_mismatches() {
  local row ext codec want got
  local -a bad
  for row in $EXT_TABLE; do
    ext="${${(s.:.)row}[1]}"; codec="${${(s.:.)row}[2]}"; want="${${(s.:.)row}[3]}"
    "$DECANT" --is-audio-ext "$ext" || bad+=("$ext:gate-rejects-it")
    got="$("$DECANT" --classify-codec "$codec")"
    [[ "$got" == "$want" ]] || bad+=("$ext/$codec:got-$got-want-$want")
  done
  print -r -- "${(j: :)bad}"
}

# The gate's own list, scraped from the source, so adding an extension without
# adding a table row fails here instead of silently going untested.
gate_exts() {
  sed -n '/^is_audio_ext()/,/^}/p' "$DECANT" |
    grep -oE '^[[:space:]]+[a-z0-9|]+\) return 0' |
    sed 's/) return 0//; s/^[[:space:]]*//' | tr '|' '\n' | sort -u
}
table_exts() { print -l -- ${EXT_TABLE[@]%%:*} | sort -u }

print -r -- "extension gate and codec classifier agree (no dead extensions)"
assert_eq   "every accepted extension classifies into a handled path" "" \
            "$(ext_table_mismatches)"
assert_eq   "the table covers every extension the gate accepts" "" \
            "$(comm -23 <(gate_exts) <(table_exts) | tr '\n' ' ' | sed 's/ *$//')"
assert_eq   "the table lists no extension the gate rejects" "" \
            "$(comm -13 <(gate_exts) <(table_exts) | tr '\n' ' ' | sed 's/ *$//')"
assert_true "the unsubstantiated .aifr extension is gone" \
            test "$("$DECANT" --is-audio-ext aifr; print $?)" -eq 2
assert_true "a non-audio extension is still rejected" \
            test "$("$DECANT" --is-audio-ext txt; print $?)" -eq 2

# ffmpeg cannot encode DSD, so write the (fixed-layout, fully specified) DSF
# header by hand: DSD chunk, fmt chunk, then one 4096-byte block of samples.
gen_dsf() {
  /usr/bin/perl -e '
    my $blk = 4096; my $data = "\x69" x $blk;
    print "DSD ", pack("Q<", 28), pack("Q<", 28 + 52 + 12 + length($data)), pack("Q<", 0);
    print "fmt ", pack("Q<", 52), pack("V", 1), pack("V", 0), pack("V", 1), pack("V", 1),
          pack("V", 2822400), pack("V", 1), pack("Q<", $blk * 8), pack("V", $blk), pack("V", 0);
    print "data", pack("Q<", 12 + length($data)), $data;
  ' > "$1"
}

print -r -- "DSD is recognised and declined for an accurate reason"
DSD="$WORK/dsd"; mkdir -p "$DSD"
gen_dsf "$DSD/pure.dsf"
DSDLOG="$WORK/dsd.log"; : > "$DSDLOG"
assert_eq   "the hand-built fixture really is DSD" "dsd_lsbf_planar" \
            "$(probe -select_streams a:0 -show_entries stream=codec_name -of default=nw=1:nk=1 -- "$DSD/pure.dsf")"
DSDOUT="$(DECANT_KEEP_ORIGINALS=1 DECANT_DEBUG=1 DECANT_LOG="$DSDLOG" "$DECANT" "$DSD" 2>&1 >/dev/null)"
assert_true "no AIFF is written (DSD→PCM would not be bit-exact)" \
            test ! -f "$DSD/pure.aiff"
assert_true "the original is left alone" \
            test -f "$DSD/pure.dsf"
assert_true "the log gives DSD as the reason, by name" \
            grep -q "SKIP (DSD, no bit-exact PCM conversion: dsd_lsbf_planar)" "$DSDLOG"
assert_eq   "DSD is never called lossy/unsupported" "0" \
            "$(grep -c 'lossy/unsupported' "$DSDLOG")"
assert_eq   "it counts as a skip, not a failure" \
            "decant: 1 skipped" "$(tail -1 <<< "$DSDOUT")"

# #given a shim that records itself and then execs the real binary, so the test
# can tell WHICH ffmpeg the script picked without breaking the conversion
print -r -- "ffmpeg resolution: the PATH's own ffmpeg wins, Homebrew is a fallback"
REAL_FFMPEG="$(command -v ffmpeg)"
REAL_FFPROBE="$(command -v ffprobe)"
PB="$WORK/pathbin"; mkdir -p "$PB"
SHIMLOG="$WORK/shim.log"
make_shim() {
  cat > "$PB/$1" <<EOF
#!/bin/sh
printf '%s\n' "$1" >> "$SHIMLOG"
exec "$2" "\$@"
EOF
  chmod +x "$PB/$1"
}
make_shim ffmpeg "$REAL_FFMPEG"
make_shim ffprobe "$REAL_FFPROBE"
PS1D="$WORK/path-user"; mkdir -p "$PS1D"
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=700:duration=1" -c:a flac "$PS1D/tone.flac"
: > "$SHIMLOG"
PATH="$PB:$PATH" DECANT_KEEP_ORIGINALS=1 DECANT_LOG="$LOG" "$DECANT" "$PS1D/tone.flac" >/dev/null 2>&1
assert_true "an ffmpeg already first on PATH is used, not overridden by Homebrew" \
            test -s "$SHIMLOG"
assert_true "the run still converts through the caller's ffmpeg" \
            test -f "$PS1D/tone.aiff"

# #when launched the way a Finder Quick Action is — a minimal PATH with no
# Homebrew on it at all — the bundled fallback must still find the tools
PS2D="$WORK/path-gui"; mkdir -p "$PS2D"
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=710:duration=1" -c:a flac "$PS2D/tone.flac"
PATH=/usr/bin:/bin:/usr/sbin:/sbin DECANT_KEEP_ORIGINALS=1 DECANT_LOG="$LOG" \
  "$DECANT" "$PS2D/tone.flac" >/dev/null 2>&1
if [[ "${REAL_FFMPEG:h}" == (/opt/homebrew/bin|/usr/local/bin) ]]; then
  assert_true "a GUI-minimal PATH still finds ffmpeg via the Homebrew fallback" \
              test -f "$PS2D/tone.aiff"
else
  print -r -- "  – skipped GUI-PATH fallback (ffmpeg is not in a Homebrew bin dir)"
fi

# #given sources whose extra streams would make `-map 0` fail outright, silently
# demoting the file to the audio-only fallback and losing art it really had
print -r -- "stream mapping: first audio + cover art, never every stream"
SM="$WORK/streams"; mkdir -p "$SM/folderart"
mk_two_stream() {
  ffmpeg -nostdin -hide_banner -loglevel error -y \
    -f lavfi -i "sine=frequency=300:duration=1" -f lavfi -i "sine=frequency=500:duration=1" \
    -map 0:a -map 1:a -c:a flac "$1"
}
mk_two_stream "$SM/twostream.mka"
mk_two_stream "$SM/folderart/twostream.mka"
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "color=c=green:s=32x32:d=1" -frames:v 1 "$SM/_art.png"
ffmpeg -nostdin -hide_banner -loglevel error -y \
  -f lavfi -i "sine=frequency=300:duration=1" -f lavfi -i "sine=frequency=500:duration=1" -i "$SM/_art.png" \
  -map 0:a -map 1:a -map 2:v -disposition:v attached_pic -c:a flac -c:v copy "$SM/twostream-art.mka"
mv "$SM/_art.png" "$SM/folderart/cover.png"
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=310:duration=1" -c:a flac "$SM/noart.flac"
SMOUT="$(DECANT_KEEP_ORIGINALS=1 DECANT_LOG="$LOG" "$DECANT" "$SM" 2>&1 >/dev/null)"
assert_eq   "a two-audio-stream .mka converts (was failing the art-preserving pass)" \
            "pcm_s16be" \
            "$(probe -select_streams a:0 -show_entries stream=codec_name -of default=nw=1:nk=1 -- "$SM/twostream.aiff")"
assert_eq   "only the first audio stream is kept (AIFF holds exactly one)" "1" \
            "$(probe -select_streams a -show_entries stream=index -of default=nw=1:nk=1 -- "$SM/twostream.aiff" | grep -c .)"
assert_eq   "no false 'dropped artwork' note for a source that had none" "0" \
            "$(grep -c 'dropped unembeddable artwork' <<< "$SMOUT")"
assert_eq   "every source in the tree converts, none fails" "decant: 4 converted" \
            "$(tail -1 <<< "$SMOUT")"
assert_eq   "cover art survives on a multi-audio-stream source" "png" \
            "$(probe -select_streams v -show_entries stream=codec_name -of default=nw=1:nk=1 -- "$SM/twostream-art.aiff")"
assert_true "a source with no art converts cleanly" \
            test -f "$SM/noart.aiff"
assert_eq   "no art is invented for a source that had none" "" \
            "$(probe -select_streams v -show_entries stream=codec_name -of default=nw=1:nk=1 -- "$SM/noart.aiff")"
assert_eq   "folder art still embeds alongside the precise stream mapping" "png" \
            "$(probe -select_streams v -show_entries stream=codec_name -of default=nw=1:nk=1 -- "$SM/folderart/twostream.aiff")"

print -r -- "awkward filenames (spaces, unicode, quotes, leading dash)"
FN="$WORK/odd names"; mkdir -p "$FN"
ODD=("a file with spaces.flac" "ünïcødé — 日本語 🎧.flac" "quote'and\"double.flac" "-leading-dash.flac")
for n in $ODD; do
  ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=440:duration=1" -c:a flac "$FN/$n"
done
DECANT_KEEP_ORIGINALS=1 DECANT_LOG="$LOG" "$DECANT" "$FN" >/dev/null 2>&1
for n in $ODD; do
  assert_true "converts [$n]" test -f "$FN/${n:r}.aiff"
done
# A leading dash must read as a path, not as an option, when passed directly.
LD="$WORK/lead"; mkdir -p "$LD"
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=450:duration=1" -c:a flac "$LD/-dash.flac"
DECANT_KEEP_ORIGINALS=1 DECANT_LOG="$LOG" "$DECANT" "$LD/-dash.flac" >/dev/null 2>&1
assert_true "a leading-dash file passed as an argument is treated as a path" \
            test -f "$LD/-dash.aiff"

rm -rf "$WORK"

print -r -- ""
print -r -- "Results: ${pass} passed, ${fail} failed"
(( fail == 0 ))
