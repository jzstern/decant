#!/usr/bin/env zsh
#
# Behavioural tests for decant. Nothing outside the /tmp sandbox is touched:
# DECANT_KEEP_ORIGINALS keeps source files in place and DECANT_LOG redirects the
# log away from ~/Library/Logs. The trash-fallback tests do move fixtures, but
# DECANT_TRASH_DIR points them at a throwaway folder inside $WORK; the tests of
# the primary NSFileManager path, which no environment variable can redirect,
# run on a temporary disk image whose Trash is its own. Neither ever reaches the
# real ~/.Trash. Requires ffmpeg/ffprobe.

emulate -L zsh

DECANT="${0:A:h}/../bin/decant"
typeset -i pass=0 fail=0

probe() { ffprobe -v error "$@" 2>/dev/null }
duration_s() { probe -show_entries format=duration -of default=nw=1:nk=1 -- "$1" }
decode_errors() { ffmpeg -nostdin -hide_banner -v error -i "$1" -f null - 2>&1 }

# Decoded-audio fingerprint, normalised to one PCM layout so a 24-bit FLAC and
# the AIFF made from it hash identically iff every sample is identical. Proves
# bit-exactness, which a matching codec_name alone does not.
pcm_md5() {
  ffmpeg -nostdin -hide_banner -v error -i "$1" -map 0:a -c:a pcm_s32le -f md5 - 2>/dev/null
}

# Mean spectral centroid in Hz. A test tone that came through a rate conversion
# intact keeps its pitch; a botched one shifts it, however right the header says
# the sample rate is.
centroid_hz() {
  ffmpeg -nostdin -hide_banner -v error -i "$1" \
    -af "aspectralstats=win_size=2048,ametadata=print:key=lavfi.aspectralstats.1.centroid:file=-" \
    -f null - 2>/dev/null |
    awk -F= '/centroid/{s+=$2; n++} END{if (n) printf "%d", s/n}'
}

peak_db() {
  ffmpeg -nostdin -hide_banner -nostats -i "$1" -af volumedetect -f null - 2>&1 |
    awk -F'max_volume: ' '/max_volume/{print $2+0; exit}'
}

# Fails on an empty value too, so a silently missing measurement can't pass.
in_range() { awk -v v="$1" -v lo="$2" -v hi="$3" 'BEGIN{exit !(v != "" && v+0 >= lo && v+0 <= hi)}' }

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

# #given a sandbox with one representative file per scenario. :A resolves /tmp's
# symlink so the sandbox path is the canonical one hdiutil and mount(8) report,
# rather than two spellings of the same directory.
WORK=$(mktemp -d /tmp/decant-tests.XXXXXX) || {
  print -u2 -- "tests: could not create a work directory under /tmp"
  exit 1
}
WORK="${WORK:A}"
LOG="$WORK/decant.log"
mkdir -p "$WORK/sub"

# True when PATH sits on a different filesystem from the sandbox — which is the
# question that actually matters, both for "did the disk image really mount
# here" and for "is it still mounted". Comparing devices beats matching mount(8)
# output: no path spelling to get wrong, and a wrong answer either strands a
# mounted volume or sends a trash test at the operator's real Trash.
own_volume() {
  local here there
  here="$(df -Pk "$1" 2>/dev/null | awk 'NR==2{print $1}')"
  there="$(df -Pk "$WORK" 2>/dev/null | awk 'NR==2{print $1}')"
  [[ -n "$here" && "$here" != "$there" ]]
}

# Teardown runs on every way out, not just the happy one: an aborted run used to
# leave its /tmp sandbox behind, and once a disk image is involved a leak is a
# volume that stays mounted after the shell is gone. zsh does not run an EXIT
# trap for an untrapped signal, so the signals are wired up explicitly.
typeset -g TRASH_VOL=""
typeset -i CLEANED=0
cleanup() {
  (( CLEANED )) && return 0
  CLEANED=1
  # Detached unconditionally rather than only when it looks mounted: a leaked
  # volume outlives the shell, so a pointless detach is the cheaper mistake.
  if [[ -n "$TRASH_VOL" ]]; then
    hdiutil detach "$TRASH_VOL" -quiet 2>/dev/null ||
      hdiutil detach "$TRASH_VOL" -force -quiet 2>/dev/null
    # Deleting the sandbox around a volume that is still mounted would delete
    # through the mount point, so say what was left behind instead.
    if own_volume "$TRASH_VOL"; then
      print -u2 -- "tests: WARNING could not detach $TRASH_VOL — leaving $WORK for you to clean up"
      return 0
    fi
  fi
  # Several sections chmod a directory read-only and restore it afterwards; an
  # interrupt in between would leave rm(1) unable to unlink what is inside it.
  if [[ -n "$WORK" && -d "$WORK" ]]; then
    chmod -R u+w "$WORK" 2>/dev/null
    rm -rf "$WORK"
  fi
  return 0
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

gen_flac24_with_art() {
  ffmpeg -nostdin -hide_banner -loglevel error \
    -f lavfi -i "sine=frequency=440:duration=1" -sample_fmt s32 -bits_per_raw_sample 24 -c:a flac "$WORK/_t.flac"
  ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "color=c=red:s=64x64:d=1" -frames:v 1 "$WORK/_a.png"
  ffmpeg -nostdin -hide_banner -loglevel error -i "$WORK/_t.flac" -i "$WORK/_a.png" \
    -map 0:a -map 1:v -c copy -disposition:v attached_pic \
    -metadata title="Test Tone" -metadata artist="decant" "$WORK/album24.flac"
  rm -f "$WORK/_t.flac" "$WORK/_a.png"
}

gen_lofi_m4a_with_art() {
  ffmpeg -nostdin -hide_banner -loglevel error \
    -f lavfi -i "sine=frequency=630:duration=2" -ar 22050 -c:a aac -b:a 64k "$WORK/_l.m4a"
  ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "color=c=red:s=40x40:d=1" -frames:v 1 "$WORK/_l.png"
  ffmpeg -nostdin -hide_banner -loglevel error -i "$WORK/_l.m4a" -i "$WORK/_l.png" \
    -map 0:a -map 1:v -c copy -disposition:v attached_pic "$WORK/artlofi.m4a"
  rm -f "$WORK/_l.m4a" "$WORK/_l.png"
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
# Above MPEG-1 Layer III's ceiling — must land on 48kHz, not 44.1.
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=640:duration=2" -ar 96000 -c:a aac -b:a 160k \
  "$WORK/hires.m4a"
# Already on a Layer III rate — must not be resampled at all.
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=650:duration=2" -ar 32000 -c:a aac -b:a 96k \
  "$WORK/std32.m4a"
# Off-spec rate AND embedded art — the resampling filter must not disturb the
# attached picture riding alongside the audio.
gen_lofi_m4a_with_art
# 96kHz lossless: the AIFF path never resamples, whatever the source rate.
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=660:duration=1" -ar 96000 \
  -sample_fmt s32 -bits_per_raw_sample 24 -c:a flac "$WORK/hires96.flac"
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
assert_eq   "96kHz m4a is resampled down to 48kHz, not 44.1kHz" "48000" \
            "$(probe -select_streams a:0 -show_entries stream=sample_rate -of default=nw=1:nk=1 -- "$WORK/hires.mp3")"
assert_eq   "32kHz m4a keeps its native rate (32k is CDJ-supported)" "32000" \
            "$(probe -select_streams a:0 -show_entries stream=sample_rate -of default=nw=1:nk=1 -- "$WORK/std32.mp3")"

print -r -- "resampler selection (soxr when the ffmpeg build has it, default otherwise)"
assert_eq   "44.1kHz source asks for no resampling options at all" "" \
            "$("$DECANT" --resample-args 44100)"
assert_eq   "48kHz source asks for none either" "" "$("$DECANT" --resample-args 48000)"
assert_eq   "32kHz source asks for none either" "" "$("$DECANT" --resample-args 32000)"
# libsoxr is an optional ffmpeg build dependency (Homebrew's bottle ships
# without it), and `-h filter=aresample` advertises soxr either way — so assert
# whichever branch THIS build genuinely takes. Both must be exactly right: a
# wrong -af here fails every off-spec conversion outright.
RS22="$("$DECANT" --resample-args 22050)"
RS96="$("$DECANT" --resample-args 96000)"
if [[ "$RS22" == *soxr* ]]; then
  assert_eq "off-spec rate uses soxr at precision 28 (this build has libsoxr)" \
            "-ar 44100 -af aresample=resampler=soxr:precision=28" "$RS22"
  assert_eq "above-48k rate uses soxr too" \
            "-ar 48000 -af aresample=resampler=soxr:precision=28" "$RS96"
else
  assert_eq "off-spec rate falls back to the default resampler (no libsoxr here)" \
            "-ar 44100" "$RS22"
  assert_eq "above-48k rate falls back the same way" "-ar 48000" "$RS96"
fi
assert_eq   "a soxr-less ffmpeg still gets a plain -ar (never a broken filter)" \
            "-ar 44100" "$(DECANT_NO_SOXR=1 "$DECANT" --resample-args 22050)"

print -r -- "resampled output is real audio, not just a retagged header"
assert_eq   "22.05->44.1kHz MP3 decodes with no errors" "" \
            "$(decode_errors "$WORK/lofi.mp3")"
assert_true "22.05->44.1kHz MP3 keeps the 2s source duration (no speed change)" \
            in_range "$(duration_s "$WORK/lofi.mp3")" 1.95 2.15
assert_true "the 630Hz test tone survives the resample (pitch unchanged)" \
            in_range "$(centroid_hz "$WORK/lofi.mp3")" 540 720
assert_true "resampled output is audible, not silence" \
            in_range "$(peak_db "$WORK/lofi.mp3")" -40 0
assert_eq   "96->48kHz MP3 decodes with no errors" "" \
            "$(decode_errors "$WORK/hires.mp3")"
assert_true "96->48kHz MP3 keeps the 2s source duration" \
            in_range "$(duration_s "$WORK/hires.mp3")" 1.95 2.15
assert_true "the 640Hz test tone survives the downsample" \
            in_range "$(centroid_hz "$WORK/hires.mp3")" 550 730
assert_eq   "an off-spec source with embedded art still resamples" "44100" \
            "$(probe -select_streams a:0 -show_entries stream=sample_rate -of default=nw=1:nk=1 -- "$WORK/artlofi.mp3")"
assert_eq   "...and keeps its cover art through the filter graph" "mjpeg" \
            "$(probe -select_streams v -show_entries stream=codec_name -of default=nw=1:nk=1 -- "$WORK/artlofi.mp3")"

print -r -- "graceful fallback when libsoxr is unavailable"
NS="$WORK/nosoxr"; mkdir -p "$NS"
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=630:duration=2" -ar 22050 -c:a aac -b:a 48k \
  "$NS/lofi.m4a"
DECANT_NO_SOXR=1 DECANT_KEEP_ORIGINALS=1 DECANT_LOG="$LOG" "$DECANT" "$NS" >/dev/null 2>&1
assert_true "the conversion still happens without soxr" \
            test -f "$NS/lofi.mp3"
assert_eq   "...still lands on exactly 44.1kHz" "44100" \
            "$(probe -select_streams a:0 -show_entries stream=sample_rate -of default=nw=1:nk=1 -- "$NS/lofi.mp3")"
assert_eq   "...and is still valid audio" "" "$(decode_errors "$NS/lofi.mp3")"
assert_true "...of the right duration" \
            in_range "$(duration_s "$NS/lofi.mp3")" 1.95 2.15

print -r -- "AIFF path stays bit-exact (decoded samples, not just codec names)"
assert_true "the PCM fingerprint is a real measurement, not an empty string" \
            test -n "$(pcm_md5 "$WORK/album24.aiff")"
assert_eq   "24-bit FLAC -> AIFF decodes to byte-identical PCM" \
            "$(pcm_md5 "$WORK/album24.flac")" "$(pcm_md5 "$WORK/album24.aiff")"
assert_eq   "16-bit WAV -> AIFF decodes to byte-identical PCM" \
            "$(pcm_md5 "$WORK/sub/tone16.wav")" "$(pcm_md5 "$WORK/sub/tone16.aiff")"
assert_eq   "96kHz FLAC keeps its rate (the AIFF path never resamples)" "96000" \
            "$(probe -select_streams a:0 -show_entries stream=sample_rate -of default=nw=1:nk=1 -- "$WORK/hires96.aiff")"
assert_eq   "96kHz FLAC -> AIFF is bit-exact as well" \
            "$(pcm_md5 "$WORK/hires96.flac")" "$(pcm_md5 "$WORK/hires96.aiff")"
assert_eq   "44.1kHz FLAC -> AIFF keeps its rate too" "44100" \
            "$(probe -select_streams a:0 -show_entries stream=sample_rate -of default=nw=1:nk=1 -- "$WORK/album24.aiff")"

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

# #given fixtures for the folder-art lookup. art_img's size is interpolated, so
# every reference is braced: "$2:s=..." would parse as a zsh :s modifier.
art_img() {
  ffmpeg -nostdin -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=${2}:s=${3}x${3}:d=1" -frames:v 1 "$1"
}
tone_flac() {
  ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=440:duration=1" -c:a flac "$1"
}
art_width() { probe -select_streams v:0 -show_entries stream=width -of default=nw=1:nk=1 -- "$1" }
art_codec() { probe -select_streams v -show_entries stream=codec_name -of default=nw=1:nk=1 -- "$1" }

print -r -- "folder art: preference order is explicit, not alphabetical luck"
AU="$WORK/artunit"
mkdir -p "$AU/pref" "$AU/ext" "$AU/case" "$AU/zero" "$AU/zeroonly" "$AU/empty"
art_img "$AU/pref/front.png" red 32
art_img "$AU/pref/folder.jpg" red 48
art_img "$AU/pref/cover.jpg" red 64
assert_eq   "cover wins over folder and front" "cover.jpg" \
            "${$("$DECANT" --folder-art "$AU/pref"):t}"
rm -f "$AU/pref/cover.jpg"
assert_eq   "folder wins once cover is gone" "folder.jpg" \
            "${$("$DECANT" --folder-art "$AU/pref"):t}"
rm -f "$AU/pref/folder.jpg"
assert_eq   "front is the last resort" "front.png" \
            "${$("$DECANT" --folder-art "$AU/pref"):t}"
art_img "$AU/ext/cover.png" red 32
art_img "$AU/ext/cover.jpg" red 64
assert_eq   "jpg beats png for the same name" "cover.jpg" \
            "${$("$DECANT" --folder-art "$AU/ext"):t}"
art_img "$AU/case/COVER.JPG" red 64
assert_eq   "the lookup stays case-insensitive" "COVER.JPG" \
            "${$("$DECANT" --folder-art "$AU/case"):t}"
: > "$AU/zero/cover.jpg"
art_img "$AU/zero/folder.jpg" red 48
assert_eq   "a 0-byte cover.jpg never displaces a real folder.jpg" "folder.jpg" \
            "${$("$DECANT" --folder-art "$AU/zero"):t}"
: > "$AU/zeroonly/cover.jpg"
assert_eq   "a 0-byte cover.jpg on its own yields no art" "" \
            "$("$DECANT" --folder-art "$AU/zeroonly")"
assert_eq   "a folder with no art yields nothing" "" \
            "$("$DECANT" --folder-art "$AU/empty")"

print -r -- "folder art: multi-disc walk-up, bounded and guarded"
mkdir -p "$AU/Album/CD1" "$AU/Album/Disc 2" "$AU/Album/disk3" "$AU/Album/cd" "$AU/Album/Bonus Tracks"
art_img "$AU/Album/cover.jpg" red 64
assert_eq   "CD1 borrows the album root's cover" "$AU/Album/cover.jpg" \
            "$("$DECANT" --folder-art "$AU/Album/CD1")"
assert_eq   "'Disc 2' (separator + number) borrows it too" "$AU/Album/cover.jpg" \
            "$("$DECANT" --folder-art "$AU/Album/Disc 2")"
assert_eq   "'disk3' borrows it too" "$AU/Album/cover.jpg" \
            "$("$DECANT" --folder-art "$AU/Album/disk3")"
assert_eq   "a folder named 'cd' with no number does NOT walk up" "" \
            "$("$DECANT" --folder-art "$AU/Album/cd")"
assert_eq   "an ordinary subfolder does NOT walk up" "" \
            "$("$DECANT" --folder-art "$AU/Album/Bonus Tracks")"
art_img "$AU/Album/CD1/folder.jpg" blue 48
assert_eq   "the disc's own art wins over the album root's" "$AU/Album/CD1/folder.jpg" \
            "$("$DECANT" --folder-art "$AU/Album/CD1")"
# #then the walk must stop after one level: a library root's stray cover.jpg is
# never an album cover, however many disc folders sit below it.
mkdir -p "$AU/Library/Some Album" "$AU/Library/Artless Album/CD1"
art_img "$AU/Library/cover.jpg" green 64
assert_eq   "a stray cover in a shared parent is NOT pulled into an album" "" \
            "$("$DECANT" --folder-art "$AU/Library/Some Album")"
assert_eq   "...and a disc folder cannot reach past its album to find it" "" \
            "$("$DECANT" --folder-art "$AU/Library/Artless Album/CD1")"

print -r -- "folder art: end-to-end embedding (fill-gaps-only)"
FA="$WORK/folderart"
mkdir -p "$FA/Multi/CD1" "$FA/Own/CD2" "$FA/Embedded/CD1" "$FA/Library/Some Album" \
         "$FA/Ålbum ✧ (2026)/Disc 2" "$FA/Bogus/CD1"
art_img "$FA/Multi/cover.jpg" red 64
tone_flac "$FA/Multi/CD1/01 - Track.flac"
art_img "$FA/Own/cover.jpg" red 64
art_img "$FA/Own/CD2/cover.jpg" blue 48
tone_flac "$FA/Own/CD2/01 - Track.flac"
art_img "$FA/Embedded/cover.jpg" red 64
art_img "$WORK/_ea.png" green 32
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=441:duration=1" -c:a flac "$WORK/_ea.flac"
ffmpeg -nostdin -hide_banner -loglevel error -i "$WORK/_ea.flac" -i "$WORK/_ea.png" \
  -map 0:a -map 1:v -c copy -disposition:v attached_pic "$FA/Embedded/CD1/01 - Track.flac"
rm -f "$WORK/_ea.png" "$WORK/_ea.flac"
art_img "$FA/Library/cover.jpg" green 64
tone_flac "$FA/Library/Some Album/01 - Track.flac"
art_img "$FA/Ålbum ✧ (2026)/cover.jpg" red 64
tone_flac "$FA/Ålbum ✧ (2026)/Disc 2/01 - Trâck ✧.flac"
print -r -- "definitely not a jpeg" > "$FA/Bogus/cover.jpg"
tone_flac "$FA/Bogus/CD1/01 - Track.flac"
DECANT_KEEP_ORIGINALS=1 DECANT_LOG="$LOG" "$DECANT" "$FA" >/dev/null 2>&1
assert_eq   "a multi-disc track embeds the album root's cover" "64" \
            "$(art_width "$FA/Multi/CD1/01 - Track.aiff")"
assert_eq   "art in the track's own folder wins over the parent's" "48" \
            "$(art_width "$FA/Own/CD2/01 - Track.aiff")"
assert_eq   "a track with its own embedded art keeps it untouched" "32" \
            "$(art_width "$FA/Embedded/CD1/01 - Track.aiff")"
assert_eq   "a stray cover above a normal album folder is never embedded" "" \
            "$(art_codec "$FA/Library/Some Album/01 - Track.aiff")"
assert_eq   "spaces and unicode in the path don't break the walk-up" "64" \
            "$(art_width "$FA/Ålbum ✧ (2026)/Disc 2/01 - Trâck ✧.aiff")"
assert_true "a cover.jpg that isn't an image still converts the audio" \
            test -f "$FA/Bogus/CD1/01 - Track.aiff"
assert_eq   "...as valid PCM" "pcm_s16be" \
            "$(probe -select_streams a:0 -show_entries stream=codec_name -of default=nw=1:nk=1 -- "$FA/Bogus/CD1/01 - Track.aiff")"
assert_eq   "...with no bogus image stream attached" "" \
            "$(art_codec "$FA/Bogus/CD1/01 - Track.aiff")"
NF="$WORK/folderart-noenrich"
mkdir -p "$NF/Multi/CD1"
art_img "$NF/Multi/cover.jpg" red 64
tone_flac "$NF/Multi/CD1/01 - Track.flac"
DECANT_KEEP_ORIGINALS=1 DECANT_LOG="$LOG" "$DECANT" --no-enrich "$NF" >/dev/null 2>&1
assert_eq   "--no-enrich embeds no folder art, parent or otherwise" "" \
            "$(art_codec "$NF/Multi/CD1/01 - Track.aiff")"

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
for FLAG in --notify --debug --dry-run --keep --no-enrich --version '-h, --help'; do
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
for HD in --detect-catalog --derive-track-disc --normalize-feat --mp3-bitrate --folder-art --resample-args; do
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
mkflac() { ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=$2:duration=1" -c:a flac "$1" }

print -r -- "--keep: the flag form of DECANT_KEEP_ORIGINALS"
KP="$WORK/keep"; mkdir -p "$KP"
for N in flag env both order dry; do mkflac "$KP/$N.flac" 490; done
DECANT_LOG="$LOG" "$DECANT" --keep "$KP/flag.flac" >/dev/null 2>&1
assert_eq   "--keep is a real option, not an unknown one" "0" "$?"
assert_true "--keep preserves the original" \
            test -f "$KP/flag.flac"
assert_true "...and still writes the conversion" \
            test -f "$KP/flag.aiff"
DECANT_KEEP_ORIGINALS=1 DECANT_LOG="$LOG" "$DECANT" "$KP/env.flac" >/dev/null 2>&1
assert_true "DECANT_KEEP_ORIGINALS preserves the original exactly as --keep does" \
            test -f "$KP/env.flac"
DECANT_KEEP_ORIGINALS=1 DECANT_LOG="$LOG" "$DECANT" --keep "$KP/both.flac" >/dev/null 2>&1
assert_eq   "flag and env var together exit 0" "0" "$?"
assert_true "...and the original survives both being set" \
            test -f "$KP/both.flac"
DECANT_LOG="$LOG" "$DECANT" "$KP/order.flac" --keep >/dev/null 2>&1
assert_true "--keep works after the path, like every other flag" \
            test -f "$KP/order.flac"
DECANT_LOG="$LOG" "$DECANT" --keep --dry-run "$KP/dry.flac" >/dev/null 2>&1
assert_eq   "--keep combined with --dry-run exits 0" "0" "$?"
# Proving --keep is what preserves an original needs a run WITHOUT it, which is
# the one thing this sandbox cannot contain — see "trashing" near the foot of
# this file, which does it on a disk image of its own.

print -r -- "log rotation: the log cannot grow forever"
RL="$WORK/rotate"; mkdir -p "$RL"
for N in 1 2 3 4 5 6 7; do mkflac "$RL/t$N.flac" $(( 492 + N )); done
# #given a log of an exact byte size whose first line identifies the generation
make_log() {
  local f="$1"; local -i bytes="$2"
  print -r -- "PREVIOUS GENERATION" > "$f"          # exactly 20 bytes
  head -c $(( bytes - 20 )) /dev/zero | tr '\0' 'x' >> "$f"
}
ROT="$RL/rot.log"; make_log "$ROT" 2097152
DECANT_KEEP_ORIGINALS=1 DECANT_DEBUG=1 DECANT_LOG="$ROT" "$DECANT" "$RL/t1.flac" >/dev/null 2>&1
assert_eq   "a run over an oversized log still exits 0" "0" "$?"
assert_true "a log at the 2MB threshold is rotated to <log>.1" \
            grep -q "PREVIOUS GENERATION" "$ROT.1"
assert_true "the live log is a fresh, small file" \
            test "$(wc -c < "$ROT")" -lt 2097152
assert_true "this run's own lines land in the new file" \
            grep -q "CONVERTED" "$ROT"
assert_eq   "...and none of the rotated content came with them" "0" \
            "$(grep -c 'PREVIOUS GENERATION' "$ROT")"
make_log "$ROT" 2097152
print -r -- "SECOND GENERATION" >> "$ROT"
DECANT_KEEP_ORIGINALS=1 DECANT_DEBUG=1 DECANT_LOG="$ROT" "$DECANT" "$RL/t2.flac" >/dev/null 2>&1
assert_true "a second rotation replaces <log>.1 rather than stacking up" \
            grep -q "SECOND GENERATION" "$ROT.1"
assert_true "...so only one previous generation is ever kept" \
            test ! -e "$ROT.2"
UNDER="$RL/under.log"; make_log "$UNDER" 2097151
DECANT_KEEP_ORIGINALS=1 DECANT_DEBUG=1 DECANT_LOG="$UNDER" "$DECANT" "$RL/t3.flac" >/dev/null 2>&1
assert_true "one byte under the threshold is not rotated" \
            test ! -e "$UNDER.1"
SMALL="$RL/small.log"; make_log "$SMALL" 4096
DECANT_KEEP_ORIGINALS=1 DECANT_DEBUG=1 DECANT_LOG="$SMALL" "$DECANT" "$RL/t4.flac" >/dev/null 2>&1
assert_true "a small log is left alone (no <log>.1)" \
            test ! -e "$SMALL.1"
assert_true "...and is appended to, not replaced" \
            grep -q "PREVIOUS GENERATION" "$SMALL"
assert_true "...with this run's lines added" \
            grep -q "CONVERTED" "$SMALL"

print -r -- "log rotation: a log that cannot be rotated never fails the run"
# An unwritable directory blocks the rename but not the append, so the run has
# to finish normally with an oversized log rather than fall over.
ROD="$WORK/rotate-ro"; mkdir -p "$ROD"
RODLOG="$ROD/stuck.log"; make_log "$RODLOG" 2097152
chmod a-w "$ROD"
DECANT_KEEP_ORIGINALS=1 DECANT_DEBUG=1 DECANT_LOG="$RODLOG" "$DECANT" "$RL/t5.flac" >/dev/null 2>&1
assert_eq   "a rotation that cannot happen does not fail the run" "0" "$?"
assert_true "...no half-rotated generation is left behind" \
            test ! -e "$RODLOG.1"
assert_true "...and this run's lines are still logged" \
            grep -q "CONVERTED" "$RODLOG"
assert_true "...and the file it could not rotate is intact" \
            grep -q "PREVIOUS GENERATION" "$RODLOG"
chmod u+w "$ROD"
ROF="$RL/readonly.log"; print -r -- "PREVIOUS GENERATION" > "$ROF"; chmod a-w "$ROF"
DECANT_KEEP_ORIGINALS=1 DECANT_DEBUG=1 DECANT_LOG="$ROF" "$DECANT" "$RL/t6.flac" >/dev/null 2>&1
assert_eq   "an unwritable log file does not fail the run either" "0" "$?"
assert_true "...and the conversion still happens" \
            test -f "$RL/t6.aiff"
chmod u+w "$ROF"
NEWLOG="$RL/deep/nested/new.log"
DECANT_KEEP_ORIGINALS=1 DECANT_DEBUG=1 DECANT_LOG="$NEWLOG" "$DECANT" "$RL/t7.flac" >/dev/null 2>&1
assert_eq   "a DECANT_LOG under a directory that does not exist exits 0" "0" "$?"
assert_true "...and the directory is created with the log inside it" \
            grep -q "CONVERTED" "$NEWLOG"

print -r -- "log format: timestamps unchanged by dropping the date(1) fork"
TS="$RL/ts.log"; : > "$TS"
for N in 1 2 3; do mkflac "$RL/ts$N.flac" $(( 500 + N )); done
T_BEFORE="$(date '+%Y-%m-%d %H:%M')"
DECANT_KEEP_ORIGINALS=1 DECANT_DEBUG=1 DECANT_LOG="$TS" "$DECANT" "$RL/ts1.flac" >/dev/null 2>&1
T_AFTER="$(date '+%Y-%m-%d %H:%M')"
assert_eq   "no logged line deviates from 'YYYY-MM-DD HH:MM:SS '" "0" \
            "$(grep -cvE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} ' "$TS")"
assert_true "the RUN marker keeps its exact shape" \
            grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} RUN start: ' "$TS"
TS_HEAD="$(head -1 "$TS" | cut -c1-16)"
if [[ "$TS_HEAD" == "$T_BEFORE" || "$TS_HEAD" == "$T_AFTER" ]]; then TS_MATCH=yes; else TS_MATCH=no; fi
assert_eq   "the timestamp still reads exactly as date(1) writes it" "yes" "$TS_MATCH"

print -r -- "log: concurrent runs append without losing or mangling lines"
CC="$RL/concurrent.log"; : > "$CC"
for N in 1 2 3 4 5 6; do mkflac "$RL/cc$N.flac" $(( 510 + N )); done
for N in 1 2 3 4 5 6; do
  DECANT_KEEP_ORIGINALS=1 DECANT_DEBUG=1 DECANT_LOG="$CC" "$DECANT" "$RL/cc$N.flac" >/dev/null 2>&1 &
done
wait
assert_eq   "every concurrent run logged its conversion" "6" \
            "$(grep -c 'CONVERTED' "$CC")"
assert_eq   "no line was interleaved or truncated" "0" \
            "$(grep -cvE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} ' "$CC")"

print -r -- "ffmpeg bootstrap: never installs hundreds of MB behind your back"
# decant adds the Homebrew bin directories to its own PATH, so no PATH the
# caller sets can hide a real ffmpeg from it. Exercise the missing-ffmpeg branch
# on a copy with every such assignment replaced by the inherited PATH — the only
# way to reach it without touching the machine's actual installation.
NT="$WORK/notools"; mkdir -p "$NT"
mkflac "$NT/t.flac" 520
awk '/\/opt\/homebrew\/bin/ && /path[+]?=\(/ {
       match($0, /^[[:blank:]]*/)
       print substr($0, 1, RLENGTH) "path=(${(s.:.)PATH})"
       next
     }
     { print }' "$DECANT" > "$NT/decant"
chmod +x "$NT/decant"
assert_true "the fixture really does neutralise the Homebrew PATH additions" \
            grep -qF 'path=(${(s.:.)PATH})' "$NT/decant"
assert_eq   "...leaving no assignment that could still reach a real ffmpeg" "0" \
            "$(grep -cE '^[[:blank:]]*path[+]?=.*/opt/homebrew/bin' "$NT/decant")"
# A brew that records being run instead of installing anything: if decant ever
# calls it unasked, the marker file proves it.
print -rl -- '#!/bin/sh' 'echo called >> "$BREW_MARKER"' > "$NT/brew"
chmod +x "$NT/brew"
NT_PATH="$NT:/usr/bin:/bin"
assert_eq   "the fixture PATH really has no ffmpeg on it" "" \
            "$(PATH="$NT_PATH" /usr/bin/which ffmpeg)"
NTLOG="$WORK/notools.log"; : > "$NTLOG"
NT_ERR="$(BREW_MARKER="$NT/called" PATH="$NT_PATH" DECANT_LOG="$NTLOG" \
          "$NT/decant" "$NT/t.flac" 2>&1 >/dev/null </dev/null)"
assert_eq   "no ffmpeg and no TTY exits 69 instead of installing" "69" "$?"
assert_true "brew is never invoked when there is no terminal to ask" \
            test ! -e "$NT/called"
assert_true "the error names the command to run" \
            grep -qF -- "brew install ffmpeg" <<< "$NT_ERR"
assert_true "the failure is logged like every other error" \
            grep -q "NO FFMPEG" "$NTLOG"
assert_true "nothing is converted when the tools are missing" \
            test ! -f "$NT/t.aiff"
# --notify silences stdout/stderr for the Quick Action, so a tool-missing
# message has to reach the user before that redirect — and via the notification.
: > "$NTLOG"
NTN_ERR="$(BREW_MARKER="$NT/called-notify" PATH="$NT_PATH" DECANT_NO_NOTIFY=1 DECANT_LOG="$NTLOG" \
           "$NT/decant" --notify "$NT/t.flac" 2>&1 >/dev/null </dev/null)"
assert_eq   "--notify with no ffmpeg still exits 69" "69" "$?"
assert_true "the message is not swallowed by --notify's output redirect" \
            grep -qF -- "brew install ffmpeg" <<< "$NTN_ERR"
assert_true "...and it reaches the log, the channel a Quick Action user can read" \
            grep -q "NO FFMPEG" "$NTLOG"
assert_true "--notify does not make brew run unasked either" \
            test ! -e "$NT/called-notify"
assert_eq   "the no-brew fixture PATH has no brew on it" "" \
            "$(PATH="/usr/bin:/bin" /usr/bin/which brew)"
NB_ERR="$(PATH="/usr/bin:/bin" DECANT_LOG="$NTLOG" "$NT/decant" "$NT/t.flac" 2>&1 >/dev/null </dev/null)"
assert_eq   "no ffmpeg and no Homebrew exits 69" "69" "$?"
assert_true "...and points at Homebrew's install page" \
            grep -qF -- "https://brew.sh" <<< "$NB_ERR"

print -r -- "ffmpeg bootstrap: with a terminal, it asks first"
# script(1) hands decant a real pty — the only way to reach the interactive
# branch. The pauses keep the answer ahead of the EOF that follows it.
{ sleep 0.5; print -r -- n; sleep 0.5 } | \
  BREW_MARKER="$NT/called-tty-n" PATH="$NT_PATH" DECANT_LOG="$NTLOG" \
  script -q /dev/null "$NT/decant" "$NT/t.flac" > "$NT/tty-n.out" 2>&1
assert_eq   "declining the install exits 69" "69" "$?"
assert_true "a terminal gets asked before anything is downloaded" \
            grep -qF -- "Install ffmpeg via Homebrew now" "$NT/tty-n.out"
assert_true "answering no leaves brew unrun" \
            test ! -e "$NT/called-tty-n"
assert_true "...and says what to run instead" \
            grep -qF -- "brew install ffmpeg" "$NT/tty-n.out"
{ sleep 0.5; print -r -- y; sleep 0.5 } | \
  BREW_MARKER="$NT/called-tty-y" PATH="$NT_PATH" DECANT_LOG="$NTLOG" \
  script -q /dev/null "$NT/decant" "$NT/t.flac" > "$NT/tty-y.out" 2>&1
assert_true "answering yes is what actually runs brew install" \
            test -e "$NT/called-tty-y"

print -r -- "interrupt: a killed run leaves no debris at the destination"
# #given a source long enough that ffmpeg is still encoding when the signal
# lands — LAME at -compression_level 0 needs ~10s for this one, and the poll
# below fires within ~50ms of the destination appearing.
KI="$WORK/interrupt"; mkdir -p "$KI"
KLOG="$WORK/kill.log"
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=440:duration=300" \
  -c:a libopus -b:a 96k "$KI/long.opus"
# Bystanders in the same folder: the handler must only ever touch the file
# ffmpeg is writing right now.
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=470:duration=1" \
  -c:a pcm_s16be "$KI/bystander.aiff"
print -r -- "keep me" > "$KI/bystander.txt"

# #when the run is signalled the way Ctrl-C does it — the script AND the ffmpeg
# it is blocked on, because zsh defers a trap until its foreground child returns.
kill_mid_encode() {
  local sig="$1" pid i
  local -a kids
  : > "$KLOG"
  rm -f "$KI/long.mp3"
  DECANT_KEEP_ORIGINALS=1 DECANT_LOG="$KLOG" "$DECANT" "$KI/long.opus" >/dev/null 2>&1 &
  pid=$!
  for i in {1..600}; do [[ -e "$KI/long.mp3" ]] && break; sleep 0.05; done
  kill -$sig $pid 2>/dev/null
  kids=($(pgrep -P $pid 2>/dev/null))
  (( ${#kids} )) && kill -$sig $kids 2>/dev/null
  wait $pid
}

kill_mid_encode TERM
KRC=$?
assert_true "SIGTERM mid-encode removes the half-written output" \
            test ! -e "$KI/long.mp3"
assert_eq   "…and exits 128+SIGTERM" "143" "$KRC"
assert_true "…leaving the source untouched" \
            test -f "$KI/long.opus"
assert_true "…and recording the interruption in the log (error tier)" \
            grep -q "INTERRUPTED (TERM)" "$KLOG"
assert_true "…without touching an unrelated sibling AIFF" \
            test -f "$KI/bystander.aiff"
assert_true "…or an unrelated non-audio sibling" \
            test -f "$KI/bystander.txt"

kill_mid_encode INT
KRC=$?
assert_true "SIGINT mid-encode removes the half-written output too" \
            test ! -e "$KI/long.mp3"
assert_eq   "…and exits 128+SIGINT" "130" "$KRC"
assert_true "…and logs the interruption" \
            grep -q "INTERRUPTED (INT)" "$KLOG"

print -r -- "recovery: an unusable pre-existing destination is re-converted"
# #given every shape of leftover a killed run can leave behind, plus a valid
# destination that must keep today's skip behaviour
RE="$WORK/recover"; mkdir -p "$RE/dirdest.aiff"
RLOG="$WORK/recover.log"
gen_flac() {
  ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=$2:duration=1" \
    -c:a flac "$1"
}
RWEIRD="-odd 'quo\"ted Ünïcode ᴥ"
gen_flac "$RE/stub.flac" 440
print -r -- "this is not audio" > "$RE/stub.aiff"
gen_flac "$RE/empty.flac" 450
: > "$RE/empty.aiff"
gen_flac "$RE/good.flac" 460
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=470:duration=1" \
  -c:a pcm_s16be "$RE/good.aiff"
gen_flac "$RE/dirdest.flac" 480
gen_flac "$RE/$RWEIRD.flac" 490
print -r -- "debris" > "$RE/$RWEIRD.aiff"
GOODSUM="$(shasum -a 256 "$RE/good.aiff" | cut -d' ' -f1)"

ROUT="$(DECANT_KEEP_ORIGINALS=1 DECANT_LOG="$RLOG" "$DECANT" "$RE" 2>&1)"
RRC=$?
assert_eq   "an invalid leftover is replaced with real audio" "pcm_s16be" \
            "$(probe -select_streams a:0 -show_entries stream=codec_name -of default=nw=1:nk=1 -- "$RE/stub.aiff")"
assert_true "…and says why, instead of skipping silently forever" \
            grep -q "stub.aiff exists but is not valid audio" <<< "$ROUT"
assert_true "…and logs it without --debug (error tier)" \
            grep -q "RECOVER (unusable target).*stub.flac" "$RLOG"
assert_eq   "a zero-length leftover is recovered the same way" "pcm_s16be" \
            "$(probe -select_streams a:0 -show_entries stream=codec_name -of default=nw=1:nk=1 -- "$RE/empty.aiff")"
assert_eq   "spaces/quotes/unicode/leading-dash names recover too" "pcm_s16be" \
            "$(probe -select_streams a:0 -show_entries stream=codec_name -of default=nw=1:nk=1 -- "$RE/$RWEIRD.aiff")"
assert_eq   "a VALID destination is still skipped, byte-for-byte" "$GOODSUM" \
            "$(shasum -a 256 "$RE/good.aiff" | cut -d' ' -f1)"
assert_true "…and still reports the plain 'already exists' skip" \
            grep -q "skip good.flac — good.aiff already exists" <<< "$ROUT"
assert_true "a destination that is a directory is never discarded" \
            test -d "$RE/dirdest.aiff"
assert_true "…and its source is left in place" \
            test -f "$RE/dirdest.flac"
assert_true "…reported as a failure rather than debris" \
            grep -q "dirdest.aiff exists and is a directory" <<< "$ROUT"
assert_true "…and logged" \
            grep -q "target exists as a directory" "$RLOG"
assert_eq   "the run exits non-zero because of that one failure" "1" "$RRC"

print -r -- "trash fallback: uniquifies instead of overwriting an earlier entry"
# #given same-named tracks from different albums, all trashed via the fallback
# (DECANT_TRASH_DIR keeps the real ~/.Trash out of it)
TB="$WORK/trash-src"; TBIN="$WORK/trash-bin"
mkdir -p "$TB/Album A" "$TB/Album B" "$TB/Album C" "$TBIN"
TWEIRD="-lead 'quo\"ted Ünïcode ᴥ"
for a in A B C; do
  ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=440:duration=1" \
    -c:a flac "$TB/Album $a/01 - Intro.flac"
done
for a in A B; do
  ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=450:duration=1" \
    -c:a flac "$TB/Album $a/$TWEIRD.flac"
done
DECANT_FORCE_TRASH_FALLBACK=1 DECANT_TRASH_DIR="$TBIN" DECANT_LOG="$LOG" \
  "$DECANT" "$TB" >/dev/null 2>&1
assert_true "the first original keeps its own name in the Trash" \
            test -f "$TBIN/01 - Intro.flac"
assert_true "the second is uniquified Finder-style (' 2')" \
            test -f "$TBIN/01 - Intro 2.flac"
assert_true "the third gets ' 3' — still nothing overwritten" \
            test -f "$TBIN/01 - Intro 3.flac"
assert_eq   "all three same-named originals survive in the Trash" "3" \
            "$(ls "$TBIN" | grep -c '^01 - Intro')"
assert_true "a spaces/quotes/unicode/leading-dash name trashes intact" \
            test -f "$TBIN/$TWEIRD.flac"
assert_true "…and its same-named twin is uniquified, not clobbered" \
            test -f "$TBIN/$TWEIRD 2.flac"
assert_eq   "every original left its album folder" "0" \
            "$(find "$TB" -name '*.flac' | wc -l | tr -d ' ')"
assert_eq   "…and every one produced an AIFF" "5" \
            "$(find "$TB" -name '*.aiff' | wc -l | tr -d ' ')"

print -r -- "trash failure: warns, logs, and leaves the original in place"
# #given a Trash directory that does not exist, so the fallback cannot move
TF="$WORK/trash-fail"; mkdir -p "$TF"
FLOG="$WORK/trashfail.log"
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=460:duration=1" \
  -c:a flac "$TF/01 - Keep.flac"
FOUT="$(DECANT_FORCE_TRASH_FALLBACK=1 DECANT_TRASH_DIR="$WORK/no-such-trash" \
        DECANT_LOG="$FLOG" "$DECANT" "$TF" 2>&1)"
FRC=$?
assert_true "the conversion is still reported as converted" \
            grep -q "converted 01 - Keep.flac" <<< "$FOUT"
assert_true "a warning says the original was left behind" \
            grep -q "could not move 01 - Keep.flac to the Trash" <<< "$FOUT"
assert_true "the original really is still there" \
            test -f "$TF/01 - Keep.flac"
assert_eq   "the output is valid audio all the same" "pcm_s16be" \
            "$(probe -select_streams a:0 -show_entries stream=codec_name -of default=nw=1:nk=1 -- "$TF/01 - Keep.aiff")"
assert_true "the failure is logged without --debug (error tier)" \
            grep -q "TRASH FAILED" "$FLOG"
assert_eq   "the run still exits 0 — the conversion succeeded" "0" "$FRC"
assert_eq   "…and the summary still counts it as converted" "decant: 1 converted" \
            "$(tail -1 <<< "$FOUT")"

# #given one source and one valid destination, alone. "recovery" above proves
# the existing file survives byte-for-byte and that the skip is announced; what
# a run over a folder of mixed outcomes cannot show is the reason reaching the
# log, or the skip landing in the summary as a skip rather than a failure.
print -r -- "destination already exists: logged under its own reason, counted as a skip"
DE="$WORK/destexists"; mkdir -p "$DE"
mkflac "$DE/t.flac" 540
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=541:duration=1" \
  -c:a pcm_s16be "$DE/t.aiff"
DELOG="$WORK/destexists.log"; : > "$DELOG"
DEOUT="$(DECANT_KEEP_ORIGINALS=1 DECANT_DEBUG=1 DECANT_LOG="$DELOG" "$DECANT" "$DE/t.flac" 2>&1 >/dev/null)"
assert_eq   "a source whose target already exists exits 0" "0" "$?"
assert_eq   "...and counts as a skip, not a conversion or a failure" "decant: 1 skipped" \
            "$(tail -1 <<< "$DEOUT")"
assert_true "the log gives 'target exists' as the reason" \
            grep -q "SKIP (target exists)" "$DELOG"

# #given artwork the target muxer refuses outright: a PPM wearing a .png name,
# which find_folder_art picks up (it matches on the name) and ffmpeg reads
# happily, but for which the ID3v2 APIC writer knows no MIME type. The audio has
# to survive the rejection, and the caller has to be told what was lost.
print -r -- "art the muxer rejects: the audio still converts, minus the art"
AD="$WORK/artdrop"; mkdir -p "$AD"
ffmpeg -nostdin -hide_banner -loglevel error -y -f lavfi -i "color=c=red:s=32x32:d=1" \
  -frames:v 1 -c:v ppm -f image2 "$AD/cover.png"
mkflac "$AD/01 - Track.flac" 545
assert_eq   "the fixture really is art the AIFF muxer cannot embed" "ppm" \
            "$(probe -select_streams v:0 -show_entries stream=codec_name -of default=nw=1:nk=1 -- "$AD/cover.png")"
ADLOG="$WORK/artdrop.log"; : > "$ADLOG"
ADOUT="$(DECANT_KEEP_ORIGINALS=1 DECANT_DEBUG=1 DECANT_LOG="$ADLOG" "$DECANT" "$AD" 2>&1 >/dev/null)"
assert_eq   "dropping unembeddable art is not a failure" "0" "$?"
assert_true "the conversion happens anyway" \
            test -f "$AD/01 - Track.aiff"
assert_true "the note says which file lost its artwork" \
            grep -qF -- "note: dropped unembeddable artwork for 01 - Track.flac" <<< "$ADOUT"
assert_eq   "...and the run still reports a conversion" "decant: 1 converted" \
            "$(tail -1 <<< "$ADOUT")"
assert_true "the log records the fallback, not a plain conversion" \
            grep -q "CONVERTED (artwork dropped)" "$ADLOG"
assert_eq   "no art stream is left on the output" "" \
            "$(probe -select_streams v -show_entries stream=codec_name -of default=nw=1:nk=1 -- "$AD/01 - Track.aiff")"
assert_eq   "the audio is still bit-exact after the second pass" \
            "$(pcm_md5 "$AD/01 - Track.flac")" "$(pcm_md5 "$AD/01 - Track.aiff")"

print -r -- "a failed conversion: output discarded, failure logged, nothing lost"
FL="$WORK/failpath"; mkdir -p "$FL"
mkflac "$FL/t.flac" 550
# An unwritable folder is the cheapest genuine ffmpeg failure: both the
# art-preserving pass and the audio-only fallback fail to create the output.
chmod a-w "$FL"
FLLOG="$WORK/failpath.log"; : > "$FLLOG"
FLOUT="$(DECANT_KEEP_ORIGINALS=1 DECANT_LOG="$FLLOG" "$DECANT" "$FL/t.flac" 2>&1 >/dev/null)"
assert_eq   "a conversion failure exits 1" "1" "$?"
assert_true "the failure is named on stderr" \
            grep -qF -- "decant: FAILED t.flac" <<< "$FLOUT"
assert_eq   "...and counted in the summary" "decant: 1 failed" \
            "$(tail -1 <<< "$FLOUT")"
assert_true "FAILED is logged without --debug, like every other error" \
            grep -q "FAILED .*t\.flac" "$FLLOG"
assert_true "...carrying ffmpeg's own reason, not just 'unknown error'" \
            grep -qE "FAILED .*t\.flac \[pcm_s16be\] :: .+" "$FLLOG"
assert_eq   "a failed run logs no CONVERTED line" "0" \
            "$(grep -c 'CONVERTED' "$FLLOG")"
assert_true "no half-written output is left behind" \
            test ! -e "$FL/t.aiff"
chmod u+w "$FL"

# #given a scratch volume of the suite's own. macOS trashes a file from a
# non-boot volume into that volume's own .Trashes/<uid>, so a disk image is the
# only way to exercise the real NSFileManager path with the side effect
# contained — a temporary $HOME cannot do it, because trashItemAtURL resolves
# the Trash from the process owner and ignores the environment.
mount_trash_volume() {
  local img="$WORK/trashvol.sparseimage" mnt="$WORK/trashvol"
  mkdir -p "$mnt" || return 1
  hdiutil create -size 24m -fs HFS+ -volname decant-tests -type SPARSE -quiet "$img" 2>/dev/null || return 1
  hdiutil attach "$img" -nobrowse -noverify -mountpoint "$mnt" -quiet 2>/dev/null || return 1
  # Recorded before the check below: anything attached has to reach the teardown,
  # even an attach that landed somewhere this run then declines to use.
  TRASH_VOL="$mnt"
  # An attach that reported success but did not put a filesystem here would
  # leave the tests writing to the boot volume — and trashing into the real
  # Trash, the exact thing this whole apparatus exists to avoid.
  own_volume "$mnt" || return 1
  return 0
}

print -r -- "trashing: the original is really moved to the Trash, and only on success"
if mount_trash_volume; then
  VT="$TRASH_VOL/album"; mkdir -p "$VT"
  VTRASH="$TRASH_VOL/.Trashes/$(id -u)"
  mkflac "$VT/keepme.flac" 560
  mkflac "$VT/trashme.flac" 561
  DECANT_LOG="$LOG" "$DECANT" --keep "$VT/keepme.flac" >/dev/null 2>&1
  assert_true "--keep leaves the original at its path" \
              test -f "$VT/keepme.flac"
  assert_true "...and puts nothing in the Trash" \
              test ! -e "$VTRASH/keepme.flac"
  DECANT_LOG="$LOG" "$DECANT" "$VT/trashme.flac" >/dev/null 2>&1
  assert_eq   "a run with neither --keep nor the env var exits 0" "0" "$?"
  assert_true "...writes the conversion" \
              test -f "$VT/trashme.aiff"
  assert_true "...and really does move the original out of its folder" \
              test ! -e "$VT/trashme.flac"
  assert_true "...into the Trash, recoverable, never deleted" \
              test -f "$VTRASH/trashme.flac"
  assert_eq   "...intact, byte for byte" "$(pcm_md5 "$VT/trashme.aiff")" \
              "$(pcm_md5 "$VTRASH/trashme.flac")"

  # #when the volume fills up mid-write, ffmpeg fails on a file decant would
  # otherwise have trashed — the assertion that matters is on a volume where
  # trashing demonstrably works, two assertions above.
  FV="$TRASH_VOL/full"; mkdir -p "$FV"
  ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=562:duration=20" \
    -sample_fmt s32 -bits_per_raw_sample 24 -c:a flac "$FV/big.flac"
  FREE_K="$(df -Pk "$TRASH_VOL" | awk 'NR==2{print $4}')"
  dd if=/dev/zero of="$TRASH_VOL/filler" bs=1024 count=$(( FREE_K - 256 )) 2>/dev/null
  FVLOG="$WORK/diskfull.log"; : > "$FVLOG"
  DECANT_LOG="$FVLOG" "$DECANT" "$FV/big.flac" >/dev/null 2>&1
  assert_eq   "a conversion that runs out of room exits 1" "1" "$?"
  assert_true "...logs the failure with ffmpeg's reason" \
              grep -q "FAILED .*big\.flac" "$FVLOG"
  assert_true "...discards the partial output" \
              test ! -e "$FV/big.aiff"
  assert_true "...leaves the original exactly where it was" \
              test -f "$FV/big.flac"
  assert_true "...and does NOT trash it" \
              test ! -e "$VTRASH/big.flac"
  rm -f "$TRASH_VOL/filler"
else
  print -r -- "  – skipped trashing tests: could not create and attach a scratch disk image here"
  print -r -- "    (hdiutil is unavailable or not permitted; the real Trash is never used instead)"
fi

# #given three sources of one version number. The Homebrew tap holds a fourth
# and lives in another repository, so it can only be checked at release time.
print -r -- "version: the script, its --version output, and the README agree"
README="${0:A:h}/../README.md"
SCRIPT_VERSION="$(sed -n 's/^DECANT_VERSION="\(.*\)"$/\1/p' "$DECANT")"
README_VERSION="$(sed -n 's|.*img\.shields\.io/badge/version-\([0-9][0-9.]*\)-.*|\1|p' "$README" | head -1)"
assert_true "the script defines a version" \
            test -n "$SCRIPT_VERSION"
assert_true "the README documents one" \
            test -n "$README_VERSION"
assert_eq   "the README's version is the script's" "$SCRIPT_VERSION" "$README_VERSION"
assert_eq   "--version prints exactly that" "decant $SCRIPT_VERSION" \
            "$("$DECANT" --version)"

# #given a throwaway HOME. install.sh writes only under $HOME, so pointing it at
# a scratch directory exercises the whole installer without going near the
# operator's own ~/.local/bin.
print -r -- "install.sh: installs under HOME, and nowhere else"
INSTALLER="${0:A:h}/../install.sh"
IH="$WORK/installhome"; mkdir -p "$IH"
IBIN="$IH/.local/bin/decant"
IOUT="$(HOME="$IH" zsh "$INSTALLER" 2>&1)"
assert_eq   "a fresh install exits 0" "0" "$?"
assert_true "the CLI lands in ~/.local/bin" \
            test -f "$IBIN"
assert_true "...executable" \
            test -x "$IBIN"
assert_eq   "...mode 0755, not whatever the source happened to be" "755" \
            "$(stat -f '%Lp' "$IBIN")"
assert_true "...byte-identical to the repo's copy" \
            cmp -s "$DECANT" "$IBIN"
assert_eq   "...and the installed copy runs" "$("$DECANT" --version)" \
            "$("$IBIN" --version)"
assert_true "the installer says where it put it" \
            grep -qF -- "installed: $IBIN" <<< "$IOUT"
assert_true "...and points at the Quick Action recipe it cannot install for you" \
            grep -qF -- "Finder Quick Action" <<< "$IOUT"
assert_true "a bin dir that is not on PATH gets the PATH tip" \
            grep -qF -- "add $IH/.local/bin to your PATH" <<< "$IOUT"
IOUT_PATH="$(HOME="$IH" PATH="$IH/.local/bin:$PATH" zsh "$INSTALLER" 2>&1)"
assert_eq   "...and no tip once it is on PATH" "0" \
            "$(grep -c 'to your PATH' <<< "$IOUT_PATH")"
HOME="$IH" zsh "$INSTALLER" >/dev/null 2>&1
assert_eq   "re-running the installer is harmless" "0" "$?"
assert_true "...and leaves the same binary in place" \
            cmp -s "$DECANT" "$IBIN"
# #then the two leftovers from the toaiff era must be cleaned up, loudly enough
# that nobody is left with a Quick Action that silently no longer works.
LEGACY_SVC="$IH/Library/Services/→ aiff.workflow"
mkdir -p "$LEGACY_SVC"
print -r -- "old binary" > "$IH/.local/bin/toaiff"
IOUT_LEGACY="$(HOME="$IH" zsh "$INSTALLER" 2>&1)"
assert_eq   "an upgrade over a toaiff install exits 0" "0" "$?"
assert_true "the obsolete Service bundle is removed" \
            test ! -e "$LEGACY_SVC"
assert_true "...and said so" \
            grep -qF -- "removed obsolete Service" <<< "$IOUT_LEGACY"
assert_true "the retired toaiff binary is removed" \
            test ! -e "$IH/.local/bin/toaiff"
assert_true "...and the broken Quick Action is called out, not left to fail silently" \
            grep -qF -- "ACTION NEEDED" <<< "$IOUT_LEGACY"
assert_true "...naming the shortcut to re-import" \
            grep -qF -- "Decant.shortcut" <<< "$IOUT_LEGACY"
assert_true "a fresh install says nothing about a toaiff that was never there" \
            test -z "$(grep 'ACTION NEEDED' <<< "$IOUT")"

# ── source probe ────────────────────────────────────────────────────────────
# Everything decant knows about a source comes out of one ffprobe call that is
# parsed in the shell. These pin both halves of that: the spawn count (so the
# probes cannot creep back in one at a time) and the parse (so a tag value can
# never be mistaken for the structure it sits inside).

# #given a shim that counts ffprobe invocations and then hands off to the real
# one. decant *appends* the Homebrew directories to its own PATH rather than
# prepending them whenever ffmpeg and ffprobe already resolve, which is what
# lets a shim placed first stay first.
print -r -- "source probe: one ffprobe per source, plus the output check"
CB="$WORK/countbin"; mkdir -p "$CB"
CLOG="$WORK/probecount.log"
count_shim() {
  print -rl -- '#!/bin/sh' \
    "printf '%s\\n' $1 >> \"\$DECANT_PROBE_COUNT\"" \
    "exec \"$2\" \"\$@\"" > "$CB/$1"
  chmod +x "$CB/$1"
}
count_shim ffprobe "$(command -v ffprobe)"
count_shim ffmpeg "$(command -v ffmpeg)"
probe_count() {
  : > "$CLOG"
  DECANT_PROBE_COUNT="$CLOG" PATH="$CB:$PATH" DECANT_KEEP_ORIGINALS=1 \
    DECANT_LOG="$LOG" "$DECANT" "$@" >/dev/null 2>&1
  grep -c '^ffprobe$' "$CLOG"
}
PC="$WORK/probes"; mkdir -p "$PC"
mkflac "$PC/a.flac" 530
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=531:duration=2" \
  -c:a libopus -b:a 96k "$PC/b.opus"
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=532:duration=2" \
  -c:a aac -b:a 160k "$PC/c.m4a"
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=533:duration=1" \
  -c:a libmp3lame -q:a 4 "$PC/d.mp3"
assert_eq   "the shim really is the ffprobe decant reaches" "1" \
            "$(probe_count "$PC/d.mp3")"
assert_eq   "a lossless source costs one probe, plus one to verify the output" "2" \
            "$(probe_count "$PC/a.flac")"
assert_eq   "an m4a carrying its own bit_rate costs no more than that" "2" \
            "$(probe_count "$PC/c.m4a")"
# Ogg/Opus stores no stream bit_rate, so the packet-summing fallback is the one
# extra probe decant still pays — and only these files pay it.
assert_eq   "an opus pays exactly one extra for the packet-sum fallback" "3" \
            "$(probe_count "$PC/b.opus")"
rm -f "$PC/a.aiff" "$PC/b.mp3" "$PC/c.mp3"
assert_eq   "a dry run over a lossless source is a single probe" "1" \
            "$(probe_count --dry-run "$PC/a.flac")"
assert_eq   "…and over an opus, the probe plus its packet sum" "2" \
            "$(probe_count --dry-run "$PC/b.opus")"
assert_eq   "…and reading no tags at all does not save a probe or cost one" "1" \
            "$(probe_count --dry-run --no-enrich "$PC/a.flac")"

print -r -- "source probe: a hostile tag value cannot forge the parse"
# #given a title that impersonates every marker a line-oriented ffprobe dump
# has — section wrappers, key=value lines, a flat-writer key path — and breaks
# the line with newlines, on top of quotes, backslashes, unicode and a tab
HT="$WORK/hostile"; mkdir -p "$HT"
HOSTILE=$'Lion Soul (feat. Someone) has=equals "quoted" \\back\\\\slash\n[STREAM]\ncodec_name=EVIL\nTAG:title=FORGED\n[/STREAM]\nstreams.stream.0.tags.title="FORGED"\nünïcødé ✧ $VAR `cmd`\ttab'
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=540:duration=1" \
  -c:a flac -metadata title="$HOSTILE" "$HT/01 - Hostile.flac"
DECANT_KEEP_ORIGINALS=1 DECANT_LOG="$LOG" "$DECANT" "$HT" >/dev/null 2>&1
HTOUT="$(probe -show_entries format_tags=title -of default=nw=1:nk=1 -- "$HT/01 - Hostile.aiff")"
# feat.→ft. is only written back when the parser found the real title, so an
# exact match here proves it was neither forged, truncated nor mis-unescaped.
assert_eq   "=, quotes, backslashes, newlines and unicode all survive the parse" \
            "${HOSTILE//feat./ft.}" "$HTOUT"
assert_eq   "…the forged 'TAG:title=FORGED' line never becomes the title" "0" \
            "$(grep -cx 'FORGED' <<< "$HTOUT")"
assert_eq   "…and the value is not truncated at its first newline" \
            "$(grep -c '' <<< "$HOSTILE")" "$(grep -c '' <<< "$HTOUT")"

# #given a tag far larger than any line-oriented reader would expect
BG="$WORK/bigtag"; mkdir -p "$BG"
BIGT="Lion (feat. X) ${(l:131072::y:)}"
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=541:duration=1" \
  -c:a flac -metadata title="$BIGT" "$BG/01 - Big.flac"
DECANT_KEEP_ORIGINALS=1 DECANT_LOG="$LOG" "$DECANT" "$BG" >/dev/null 2>&1
assert_eq   "a 128 KB title comes back whole, two chars shorter for feat.→ft." \
            "$(( ${#BIGT} - 2 ))" \
            "${#$(probe -show_entries format_tags=title -of default=nw=1:nk=1 -- "$BG/01 - Big.aiff")}"

print -r -- "source probe: where the tags live"
# #given an .opus, whose Vorbis comments hang off the stream and whose
# format-level dictionary is empty
SO="$WORK/streamtags"; mkdir -p "$SO"
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=542:duration=2" \
  -c:a libopus -b:a 96k -metadata title="Stream Only (feat. Y)" "$SO/07 - Stream.opus"
# #given an .mka with a track tag on the stream and none on the format: the
# gap is already filled, so nothing may be derived from the "03 - " prefix
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=543:duration=1" \
  -c:a flac -metadata:s:a:0 track=4 "$SO/03 - StreamTrack.mka"
# #given a second audio stream that is the only one carrying a title
ffmpeg -nostdin -hide_banner -loglevel error \
  -f lavfi -i "sine=frequency=544:duration=1" -f lavfi -i "sine=frequency=545:duration=1" \
  -map 0:a -map 1:a -c:a flac -metadata:s:a:1 title="Second (feat. Z)" "$SO/09 - TwoAudio.mka"
# #given a source with no tags whatsoever
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=546:duration=1" \
  -c:a flac -map_metadata -1 "$SO/06 - Bare.flac"
DECANT_KEEP_ORIGINALS=1 DECANT_LOG="$LOG" "$DECANT" "$SO" >/dev/null 2>&1
assert_eq   "an opus title is read off the stream, not the empty format tags" \
            "Stream Only (ft. Y)" \
            "$(probe -show_entries format_tags=title -of default=nw=1:nk=1 -- "$SO/07 - Stream.mp3")"
assert_eq   "…and the filename still fills the track gap beside it" "7" \
            "$(probe -show_entries format_tags=track -of default=nw=1:nk=1 -- "$SO/07 - Stream.mp3")"
assert_eq   "a stream-level track counts as present, so none is derived" "" \
            "$(probe -show_entries format_tags=track -of default=nw=1:nk=1 -- "$SO/03 - StreamTrack.aiff")"
assert_eq   "a title on the second audio stream is found like any other" \
            "Second (ft. Z)" \
            "$(probe -show_entries format_tags=title -of default=nw=1:nk=1 -- "$SO/09 - TwoAudio.aiff")"
assert_eq   "a file with no tags at all still gets its track backfilled" "6" \
            "$(probe -show_entries format_tags=track -of default=nw=1:nk=1 -- "$SO/06 - Bare.aiff")"
assert_eq   "…and no title is invented for it" "" \
            "$(probe -show_entries format_tags=title -of default=nw=1:nk=1 -- "$SO/06 - Bare.aiff")"

print -r -- "source probe: any video stream counts as art, attached picture or not"
# #given two sources sitting beside a folder cover: one whose video stream is a
# real picture-carrying attached_pic, one whose video stream is actual video.
# Both already "have art", so neither may pick up the folder's cover.
VS="$WORK/videostream"; mkdir -p "$VS/pic" "$VS/vid"
art_img "$VS/pic/cover.png" red 64
art_img "$VS/vid/cover.png" red 64
art_img "$WORK/_vs.png" green 32
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=547:duration=1" -c:a flac "$WORK/_vs.flac"
ffmpeg -nostdin -hide_banner -loglevel error -i "$WORK/_vs.flac" -i "$WORK/_vs.png" \
  -map 0:a -map 1:v -c copy -disposition:v attached_pic "$VS/pic/01 - Pic.flac"
ffmpeg -nostdin -hide_banner -loglevel error \
  -f lavfi -i "testsrc=size=64x64:rate=10:duration=1" -f lavfi -i "sine=frequency=548:duration=1" \
  -map 0:v -map 1:a -c:v libx264 -c:a flac "$VS/vid/02 - Vid.mka"
# A sibling with no video stream at all, to show the folder's cover really was
# there to be found — the one beside it is passed over for having art already.
tone_flac "$VS/vid/03 - Plain.flac"
rm -f "$WORK/_vs.png" "$WORK/_vs.flac"
VSOUT="$(DECANT_KEEP_ORIGINALS=1 DECANT_LOG="$LOG" "$DECANT" "$VS" 2>&1 >/dev/null)"
assert_eq   "an attached picture is kept, and the folder cover not pasted over it" "32" \
            "$(art_width "$VS/pic/01 - Pic.aiff")"
assert_true "a real video stream still converts its audio" \
            test -f "$VS/vid/02 - Vid.aiff"
assert_eq   "…as valid PCM" "pcm_s16be" \
            "$(probe -select_streams a:0 -show_entries stream=codec_name -of default=nw=1:nk=1 -- "$VS/vid/02 - Vid.aiff")"
assert_eq   "…with the video dropped rather than muxed into the AIFF" "" \
            "$(art_codec "$VS/vid/02 - Vid.aiff")"
assert_true "…and said so" \
            grep -q "dropped unembeddable artwork for 02 - Vid.mka" <<< "$VSOUT"
assert_eq   "the sibling with no video stream does take the folder cover" "64" \
            "$(art_width "$VS/vid/03 - Plain.aiff")"

print -r -- "source probe: partial and unreadable probe output"
# #given the two shapes a broken file takes: one ffprobe cannot open at all
# (it prints nothing), and one it guesses a codec for from the extension and
# then cannot describe (codec_name=flac, sample_fmt=unknown, duration=N/A)
PA="$WORK/partial"; mkdir -p "$PA"
PALOG="$WORK/partial.log"; : > "$PALOG"
print -r -- "not audio at all, just words" > "$PA/07 - Words.flac"
mkflac "$WORK/_pa.flac" 549
head -c 3000 "$WORK/_pa.flac" > "$PA/08 - Cut.flac"
rm -f "$WORK/_pa.flac"
PAOUT="$(DECANT_KEEP_ORIGINALS=1 DECANT_DEBUG=1 DECANT_LOG="$PALOG" "$DECANT" "$PA" 2>&1 >/dev/null)"
PARC=$?
assert_eq   "a partially-probeable file is skipped, not failed" "decant: 1 skipped" \
            "$(tail -1 <<< "$PAOUT")"
assert_true "…and says the audio was unreadable" \
            grep -q "SKIP (unreadable audio).*07 - Words.flac" "$PALOG"
assert_true "a file ffprobe cannot open at all is passed over silently" \
            test ! -f "$PA/08 - Cut.aiff"
assert_true "…leaving no AIFF for the unreadable one either" \
            test ! -f "$PA/07 - Words.aiff"
assert_eq   "…and neither one fails the run" "0" "$PARC"

print -r -- ""
print -r -- "Results: ${pass} passed, ${fail} failed"
(( fail == 0 ))
