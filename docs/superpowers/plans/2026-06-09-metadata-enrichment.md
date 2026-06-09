# Metadata Enrichment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `toaiff` enrich ID3 metadata during conversion — catalog number → grouping, track/disc backfill, `feat.`→`ft.`, folder-art embedding — default-on, fill-gaps-only.

**Architecture:** A pure-function enrichment stage runs inside `process_file` between probe and convert. Each deriver is an isolated zsh function exposed to tests via hidden dispatch flags. `build_meta_args` reads existing tags, enforces fill-gaps-only, and emits an ffmpeg `-metadata`/art arg array consumed by an extended `convert_file`.

**Tech Stack:** zsh, ffmpeg/ffprobe. Tests via existing `tests/run.sh` assertion harness (non-destructive).

---

## File structure

| File | Responsibility | Change |
|------|----------------|--------|
| `bin/toaiff` | CLI + conversion + (new) enrichment functions | Modify |
| `tests/run.sh` | assertion suite | Modify (add enrichment fixtures + assertions) |
| `README.md` | user docs | Modify (enrichment + `--dry-run` sections) |

All enrichment functions live in `bin/toaiff` alongside the existing helpers,
following the established single-file pattern. Hidden test-dispatch flags
(`--detect-catalog`, `--derive-track-disc`, `--normalize-feat`) mirror the
existing `--check-root` pattern so pure functions are unit-tested without ffmpeg.

---

### Task 1: `normalize_feat` (pure string transform)

**Files:** Modify `bin/toaiff` (add function + hidden `--normalize-feat` dispatch); Test `tests/run.sh`.

- [ ] **Step 1 — Implement.** Add near the other helpers:

```zsh
# Replace the word "feat." (any case) with "ft." in a title. Word-anchored so
# "FEISTY" / "feature" are untouched. Idempotent. Echoes the (possibly) changed string.
normalize_feat() {
  print -r -- "${1//(#bi)(feat)\./ft.}"
}
```

Note: zsh `(#bi)` = case-insensitive backreference glob; `(feat)\.` matches `feat.`
case-insensitively. Verify the spaceless edge: only `feat.` (with the dot) is replaced.

- [ ] **Step 2 — Hidden dispatch.** Beside the `--check-root` block:

```zsh
if [[ "${1:-}" == "--normalize-feat" ]]; then
  normalize_feat "${2:-}"; exit 0
fi
```

- [ ] **Step 3 — Tests.** In `tests/run.sh`:

```zsh
print -r -- "enrichment: feat -> ft normalization"
assert_eq "lowercase feat. -> ft." "Lights Out (ft. Romy)" \
  "$("$TOAIFF" --normalize-feat 'Lights Out (feat. Romy)')"
assert_eq "capital Feat. -> ft." "Track (ft. X)" \
  "$("$TOAIFF" --normalize-feat 'Track (Feat. X)')"
assert_eq "FEISTY is untouched (word-anchored)" "..FEISTY (ft. Bia)" \
  "$("$TOAIFF" --normalize-feat '..FEISTY (feat. Bia)')"
assert_eq "idempotent on already-ft." "A (ft. B)" \
  "$("$TOAIFF" --normalize-feat 'A (ft. B)')"
```

- [ ] **Step 4 — Run** `./tests/run.sh`; expect all pass. **Commit.**

---

### Task 2: `detect_catalog` (folder-name → uppercase catalog token)

**Files:** Modify `bin/toaiff` (function + `--detect-catalog` dispatch); Test `tests/run.sh`.

- [ ] **Step 1 — Implement.** Tokenize bracket groups and bare scene tokens, apply the
letters-then-digits regex, reject blocklist + years + pure digits, pick winner
(bracketed > bare; last bracketed on ties), uppercase.

```zsh
_cat_blocklist=(FLAC WAV WAVE W64 RF64 BWF MP3 AAC ALAC APE WV WEB WEBFLAC \
  CD VINYL EP LP VA OST MIXTAPE REMIX REMIXES MP4 M4A)

_is_catalog_token() {
  local t="${1:u}"
  [[ "$t" == (#i)[a-z](#c2,)([-_ ]|)[0-9](#c2,)[a-z]# ]] || return 1   # letters>=2 then digits>=2 (+opt trailing letters)
  (( ${_cat_blocklist[(I)$t]} )) && return 1
  [[ "$t" == (19|20)[0-9][0-9] ]] && return 1                          # year
  [[ "$t" == [0-9]## ]] && return 1                                    # pure digits
  [[ "$t" == *(KHZ|BIT|KBPS|HZ)* ]] && return 1                        # rate/depth
  return 0
}

detect_catalog() {
  local name="$1" bracketed=() bare=() tok winner=""
  # bracketed groups: [...] (...) {...}
  local groups; groups=("${(@f)$(print -r -- "$name" | grep -oE '\[[^]]+\]|\([^)]+\)|\{[^}]+\}')}")
  for g in $groups; do
    for tok in ${(s: :)${g//[][(){}]/ }}; do
      _is_catalog_token "$tok" && bracketed+=("${tok:u}")
    done
  done
  # bare scene tokens split on - and _
  for tok in ${(s: :)${name//[-_]/ }}; do
    _is_catalog_token "$tok" && bare+=("${tok:u}")
  done
  if (( ${#bracketed} )); then winner="${bracketed[-1]}"
  elif (( ${#bare} )); then winner="${bare[-1]}"; fi
  [[ -n "$winner" ]] && print -r -- "$winner"
}
```

- [ ] **Step 2 — Hidden dispatch** `--detect-catalog NAME` → prints token or nothing.

- [ ] **Step 3 — Tests** (folder names from the real library):

```zsh
print -r -- "enrichment: catalog detection"
assert_eq "[SHA300] -> SHA300" "SHA300" "$("$TOAIFF" --detect-catalog '[SHA300] VA - 20 Years Of Shogun Audio [2024]')"
assert_eq "(snf137) -> SNF137 (uppercased)" "SNF137" "$("$TOAIFF" --detect-catalog 'baile, nuage - back 2 earth (snf137) (2026) [flac] [24b-44.1khz]')"
assert_eq "scene bare (FXPLY025)" "FXPLY025" "$("$TOAIFF" --detect-catalog 'Kassian-Grain__Shell_Dub-(FXPLY025)-WEB-2026-PTC')"
assert_eq "bare USB002 scene token" "USB002" "$("$TOAIFF" --detect-catalog 'Fred again.. - USB002 - [2025]')"
assert_eq "{LLR004} curly" "LLR004" "$("$TOAIFF" --detect-catalog 'a.s.o. - a.s.o. remixed (2023) [FLAC] {LLR004}')"
assert_eq "NB011EP trailing letters" "NB011EP" "$("$TOAIFF" --detect-catalog 'VA - Various Artists, Vol. 2 [NB011EP]')"
assert_eq "decoy [FLAC 24] -> none" "" "$("$TOAIFF" --detect-catalog 'CHASING LIGHT (2026) [FLAC 24]')"
assert_eq "decoy year/format only -> none" "" "$("$TOAIFF" --detect-catalog 'Gallows ep (2022) [WEB FLAC]')"
assert_eq "barcode {label, 5056818805226} -> none" "" "$("$TOAIFF" --detect-catalog 'OPN - Tranquilizer (2025) [FLAC] {Warp Records, 5056818805226}')"
```

- [ ] **Step 4 — Run, iterate on the glob until green. Commit.**

---

### Task 3: `derive_track_disc` (filename → track/disc)

**Files:** Modify `bin/toaiff` (function + `--derive-track-disc` dispatch); Test `tests/run.sh`.

- [ ] **Step 1 — Implement.** Match the leading token only.

```zsh
# Echoes "track=N" and/or "disc=N" (space-separated) or nothing.
derive_track_disc() {
  local base="${1:t:r}" out=()
  if [[ "$base" == (#b)[[:space:]]#\(([[:space:]]#<1-99>)[[:space:]]#-[[:space:]]#([[:space:]]#<1-999>)[[:space:]]#\)* ]]; then
    out+=("disc=$((match[1]))" "track=$((match[2]))")
  elif [[ "$base" == (#b)[[:space:]]#(<1-999>)([-._\)]*) ]]; then
    out+=("track=$((match[1]))")
  fi
  (( ${#out} )) && print -r -- "${out}"
}
```

(Leading `<1-999>` numeric guard rejects 4-digit years automatically. Verify
`01 - 1983` yields only `track=1`, and `(01 - 02)` yields `disc=1 track=2`.)

- [ ] **Step 2 — Hidden dispatch** `--derive-track-disc FILENAME`.

- [ ] **Step 3 — Tests:**

```zsh
print -r -- "enrichment: track/disc derivation"
assert_eq "NN - Title -> track" "track=1" "$("$TOAIFF" --derive-track-disc '01 - Adrift.flac')"
assert_eq "NNN - Artist - Title -> track" "track=3" "$("$TOAIFF" --derive-track-disc '003 - DJ Q - I Couldn'\''t See.flac')"
assert_eq "(disc - track) form" "disc=1 track=2" "$("$TOAIFF" --derive-track-disc '(01 - 02) Bangarang.aiff')"
assert_eq "trailing year ignored" "track=1" "$("$TOAIFF" --derive-track-disc '01 - 1983.aiff')"
assert_eq "trailing number ignored" "track=1" "$("$TOAIFF" --derive-track-disc '01 - 200 Press.flac')"
assert_eq "no leading number -> nothing" "" "$("$TOAIFF" --derive-track-disc '# Dr. Derg - Depression.flac')"
```

- [ ] **Step 4 — Run, iterate, commit.**

---

### Task 4: `find_folder_art`

**Files:** Modify `bin/toaiff` (function); Test `tests/run.sh` (integration via convert in Task 6).

- [ ] **Step 1 — Implement.**

```zsh
# Echoes path to a cover image in DIR (cover/folder/front .jpg/.jpeg/.png), case-insensitive.
find_folder_art() {
  local dir="$1" f
  for f in "$dir"/(#i)(cover|folder|front).(jpg|jpeg|png)(N); do
    [[ -f "$f" ]] && { print -r -- "$f"; return; }
  done
}
```

- [ ] **Step 2 — Commit** (covered end-to-end in Task 6).

---

### Task 5: `build_meta_args` (fill-gaps-only orchestrator)

**Files:** Modify `bin/toaiff`.

- [ ] **Step 1 — Probe existing tags.** Extend the `process_file` ffprobe to also read
`format_tags=track,disc,grouping,title` and whether a video (art) stream exists.

- [ ] **Step 2 — Implement.** Populate globals `META_ARGS` (ffmpeg args) and `META_PLAN`
(parseable summary for dry-run). Enforce fill-gaps-only: only add a `-metadata`
for a derived field when the existing tag is empty. `title` feat-normalization
overrides only when the normalized value differs.

```zsh
build_meta_args() {
  local src="$1" cur_track="$2" cur_disc="$3" cur_grouping="$4" cur_title="$5" has_art="$6"
  META_ARGS=(); META_PLAN=()
  local dir="${src:h}" folder="${src:h:t}" base="${src:t}"
  # catalog -> grouping (gap-only)
  if [[ -z "$cur_grouping" ]]; then
    local cat; cat=$(detect_catalog "$folder")
    [[ -n "$cat" ]] && { META_ARGS+=(-metadata "grouping=$cat"); META_PLAN+=("grouping=$cat"); }
  fi
  # track/disc (gap-only)
  local td; td=$(derive_track_disc "$base")
  local kv k v
  for kv in ${(s: :)td}; do
    k="${kv%%=*}"; v="${kv#*=}"
    [[ "$k" == track && -n "$cur_track" ]] && continue
    [[ "$k" == disc  && -n "$cur_disc"  ]] && continue
    META_ARGS+=(-metadata "$kv"); META_PLAN+=("$kv")
  done
  # feat -> ft on title (transform, not gap-fill)
  if [[ -n "$cur_title" ]]; then
    local nt; nt=$(normalize_feat "$cur_title")
    [[ "$nt" != "$cur_title" ]] && { META_ARGS+=(-metadata "title=$nt"); META_PLAN+=("title=$nt"); }
  fi
  # folder art (only if no embedded art)
  ART_INPUT=""
  if [[ "$has_art" != 1 ]]; then
    local art; art=$(find_folder_art "$dir")
    [[ -n "$art" ]] && { ART_INPUT="$art"; META_PLAN+=("art=${art:t}"); }
  fi
}
```

- [ ] **Step 2b — Commit.**

---

### Task 6: Wire enrichment into conversion (default-on)

**Files:** Modify `bin/toaiff` (`convert_file`, `process_file`).

- [ ] **Step 1 — Extend `convert_file`** to accept `META_ARGS`/`ART_INPUT`. First attempt
maps source + (optional) art input + metadata; fallback drops art (sets `ART_DROPPED`)
but keeps `-metadata` args:

```zsh
convert_file() {
  local src="$1" tgt="$2" out="$3"
  CONVERT_ERR=""; ART_DROPPED=0
  local artmap=() inputs=(-i "$src")
  if [[ -n "$ART_INPUT" ]]; then inputs+=(-i "$ART_INPUT"); artmap=(-map 1:v -disposition:v attached_pic); fi
  if ffmpeg -nostdin -hide_banner -loglevel error -y $inputs \
       -map 0 ${ART_INPUT:+$artmap} -map_metadata 0 $META_ARGS \
       -c:a "$tgt" -c:v copy -write_id3v2 1 -f aiff "$out" 2>/dev/null; then
    return 0
  fi
  local err
  err=$(ffmpeg -nostdin -hide_banner -loglevel error -y -i "$src" -map 0:a -map_metadata 0 $META_ARGS \
        -c:a "$tgt" -write_id3v2 1 -f aiff "$out" 2>&1) && { ART_DROPPED=1; return 0; }
  CONVERT_ERR="${err//$'\n'/ | }"; return 1
}
```

- [ ] **Step 2 — In `process_file`,** after the gap probe, call `build_meta_args` before
`convert_file`. Add fixtures + assertions in `tests/run.sh`:

```zsh
print -r -- "enrichment: end-to-end tagging"
EN="$WORK/[ARTKL081] Cadik - Lion Soul (2025)"; mkdir -p "$EN"
ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "sine=frequency=440:duration=1" \
  -sample_fmt s32 -bits_per_raw_sample 24 -c:a flac \
  -metadata title="Lion Soul (feat. Someone)" "$EN/02 - Lion Soul (feat. Someone).flac"
TOAIFF_KEEP_ORIGINALS=1 TOAIFF_LOG="$LOG" "$TOAIFF" "$EN" >/dev/null 2>&1
A="$EN/02 - Lion Soul (feat. Someone).aiff"
assert_eq "catalog -> grouping (uppercased)" "ARTKL081" "$(probe -show_entries format_tags=grouping -of default=nw=1:nk=1 -- "$A")"
assert_eq "track backfilled from filename" "2" "$(probe -show_entries format_tags=track -of default=nw=1:nk=1 -- "$A")"
assert_eq "feat normalized in title" "Lion Soul (ft. Someone)" "$(probe -show_entries format_tags=title -of default=nw=1:nk=1 -- "$A")"
```

Add a fill-gaps test: a FLAC with an existing `track=7` in a `[SHA300]` folder
keeps `track=7` (not overwritten).

Add a folder-art test: a no-art FLAC beside `cover.png` → output AIFF has a
video stream; a FLAC that already embeds art is unchanged.

- [ ] **Step 3 — Run full suite, iterate, commit.**

---

### Task 7: `--dry-run`

**Files:** Modify `bin/toaiff` (flag parsing + `process_file` short-circuit); Test `tests/run.sh`.

- [ ] **Step 1 — Parse `--dry-run`** in the flag loop (`DRYRUN=1`).

- [ ] **Step 2 — In `process_file`,** when `DRYRUN`, after `build_meta_args` print
`toaiff: would convert <name> [${(j: :)META_PLAN}]` to stderr and `return` before
`convert_file`/trash. Count as `converted` for the summary? No — print a distinct
line; do not trash, do not write.

- [ ] **Step 3 — Tests:** dry-run on a fixture writes **no** `.aiff` and trashes nothing,
and the printed plan contains the expected `grouping=`/`track=`. **Commit.**

---

### Task 8: Docs

**Files:** Modify `README.md`.

- [ ] Add an **Enrichment** section (catalog→grouping, track/disc backfill, feat→ft,
folder art; fill-gaps-only; default-on) and document `--dry-run`. Update the
feature summary at the top. **Commit.**

---

## Plan review

After all tasks: run `./tests/run.sh` (expect all green, including the original 25),
then proceed to finishing-a-development-branch.
