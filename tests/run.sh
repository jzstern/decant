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

# #when the whole tree is converted (recursively, keeping originals)
TOAIFF_KEEP_ORIGINALS=1 TOAIFF_LOG="$LOG" "$TOAIFF" "$WORK" >/dev/null
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
assert_eq   "the run exits 0 even with a corrupt file present" \
            "0" "$run_rc"

print -r -- "originals + logging"
assert_true "originals are preserved when TOAIFF_KEEP_ORIGINALS is set" \
            test -f "$WORK/album24.flac"
assert_true "a CONVERTED entry is written to the log" \
            grep -q "CONVERTED .*album24.flac" "$LOG"
assert_true "a lossy SKIP reason is written to the log" \
            grep -q "SKIP (lossy/unsupported: mp3)" "$LOG"

print -r -- "stdin path input (Shortcuts 'to stdin' fallback)"
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=480:duration=1" \
  -sample_fmt s32 -bits_per_raw_sample 24 -c:a flac "$WORK/stdintest.flac"
print -r -- "$WORK/stdintest.flac" | TOAIFF_KEEP_ORIGINALS=1 TOAIFF_LOG="$LOG" "$TOAIFF" >/dev/null
assert_true "converts a path piped on stdin (no arguments)" \
            test -f "$WORK/stdintest.aiff"

rm -rf "$WORK"

print -r -- ""
print -r -- "Results: ${pass} passed, ${fail} failed"
(( fail == 0 ))
