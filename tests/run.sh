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

rm -rf "$WORK"

print -r -- ""
print -r -- "Results: ${pass} passed, ${fail} failed"
(( fail == 0 ))
