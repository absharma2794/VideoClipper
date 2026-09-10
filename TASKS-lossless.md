# TASKS — lossless/smaller export rework (branch: `lossless`)

**Basis:** `[09-09-2026]SESSIONTRANSCRIPTmkvclipperaudit.md` (a prior, code-untouched audit
session — two measurement rounds, `suggestedTASKS01.md`, `suggestedTASKS02.md`, and that
session's own critiques of both). This document is v3: v2's plan with its five known problems
corrected, and re-verified line-for-line against the code as it exists on this branch today
(confirmed identical in substance to what v2 analyzed; only line numbers drifted by single
digits). Superseds `suggestedTASKS01.md`/`suggestedTASKS02.md` — don't work from those.

**Target files:** `Sources/Clipper.swift`, `Sources/VideoProbe.swift`, `Sources/EditorView.swift`
unless stated otherwise. Line numbers below are current as of this branch's creation — locate
by symbol if they've drifted further.

## What "lossless" means for this branch

Two different things, and this plan is about the second one:

- **Bit-exact lossless** — the app already has this: the **Fast** path (`-map 0 -c copy`,
  `Clipper.swift`'s `fastCopyArguments`). It cannot shrink the video stream at all; it can only
  save space by omitting tracks. Nothing in this plan touches it except where noted (never
  "improve" it — see *Do not do*).
- **Perceptually lossless, smaller** — re-encoding with a genuinely good, correctly-configured
  encoder so the output is smaller than the source while staying visually indistinguishable
  (VMAF ~95+). This is what "Precise" is supposed to be and currently isn't. Every tier below
  is in service of this.

---

## Guardrails

- Never touch the user's media folders. No moving, renaming, overwriting, or deleting source
  files or exports. Test artifacts go in a scratch directory.
- One task, one commit, on `lossless`. Do not commit or push without being asked.
- Do not start Tier 4 (smart rendering) or Tier 5 (AV1 pipeline) — both blocked, see bottom.
- If a fix needs a decision not specified here, stop and ask. Do not guess a default.
- Re-verify with the `video-loss-audit.md` runbook (track inventory → bit-exactness →
  VMAF) at every gate below — this is the same methodology the original audits used, so
  results are directly comparable to the numbers already on record.

---

## T0 — Flip the default to Fast, completely

`EditorView.swift:58`: `@State private var precise = true` → `false`.

**Also fix `EditorView.swift:272`** (`resetAdvancedSettings()`, which sets `precise = true`
unconditionally) → `false`. This is the detail v1/v2 both missed: without this second edit,
clicking **Reset** on the Advanced Settings page silently reintroduces the lossy default even
after the first edit ships.

This is a real, high-impact bug — the README already documents Fast as the default and the
code doesn't ship it — but it is **not** "the root cause behind every audit finding." The
track-dropping, audio-transcode, and bitrate defects in Tier 1 are independent bugs in
`preciseArguments()`/`VideoProbe` that exist regardless of which mode opens by default. Fix
this first because it's cheap and stops most users from hitting the other bugs by accident —
not because fixing it fixes them.

Verify both edits agree with the README's claimed default before moving on.

---

## Tier 1 — Defect fixes (mechanical, no design decisions)

### T1.1 — Stop dropping tracks, container-aware

`preciseArguments()` (`Clipper.swift:373`) hard-codes `-map 0:v:0 -map 0:a:0?`, dropping every
extra audio track and all subtitles (42 lost on the F1 audit source, 29 on the round-1 anime
source).

Change to `-map 0`, by container:
- **MKV output:** `-map 0 -c:s copy` — subrip and most subtitle formats pass through natively.
- **MP4 output:** `-map 0 -c:s mov_text` for convertible subtitle streams; for a stream that
  can't convert, drop **only that stream** with a visible warning surfaced in the export
  result — never fail the whole export silently, never drop without saying so.

`fastCopyArguments` (`Clipper.swift:342-365`) already has the pattern to copy here: it tries a
full copy first, and on MP4 specifically retries once with a narrower map/transcode only when
the container rejects the first attempt (see its `catch` block, `Clipper.swift:150-166`, and
`Result.usedAudioReencodeFallback`). Reuse that same "try native, fall back and say so" shape
for subtitles here instead of inventing new fallback logic.

Test against a source with many subtitle tracks (the audit's F1 source had 42), exported to
both containers, before calling this done.

### T1.2 — Stop transcoding audio unconditionally

`preciseArguments()` (`Clipper.swift:380`): `-c:a aac -b:a 192k`, unconditional.

Measured cost: one audit source's audio was halved (378→187 kbps); another's E-AC-3 256k
became a lossy AAC 192k generational transcode; a third case saved 0.3% of total file size for
the transcode. No case in the audit data justified this.

Change to `-c:a copy` for MKV output (carries all of these natively). For MP4, reuse the same
retry-on-failure shape as T1.1: try `-c:a copy` first, and only if ffmpeg rejects the audio
codec in that container (the existing Fast-path fallback already knows this happens with
E-AC-3/TrueHD/certain DTS variants), retry once with an AAC transcode and set
`usedAudioReencodeFallback` so the UI can say so — exactly the existing Fast-path contract,
just extended to Precise.

### T1.3 — Fix the bitrate source

`VideoProbe.swift:118-132`: when `stream.bit_rate` is absent (the normal case for MKV), the
fallback reads `format.bit_rate` — the **container's** bitrate (video + audio + subtitles
combined) — and that value is later passed to `-b:v` (`Clipper.swift:435,440`), a video-only
parameter. Measured effect: one source's video track was ordered to spend 14% more than the
source spent, because ~280 kbps of audio got folded into the video budget.

Fix: when the per-stream value is absent, compute the video stream's actual bitrate from
packet sizes over the probed range instead of falling back to the container total.

This is interim — Tier 6 deletes the code path that consumes `videoBitrate` entirely — but fix
it now so nothing reads a wrong value in the meantime, and so the Tier 1 gate below is
actually reachable on the current encoder.

### T1.4 — Relax the forced GOP, don't remove it

`preciseArguments()` (`Clipper.swift:392`): `-force_key_frames expr:gte(t,n_forced*2)` forces a
2-second keyframe interval on every Precise export.

**Both prior task lists got this wrong.** It is not "a streaming convention that buys nothing
in a local file" — the code's own adjacent comment (`Clipper.swift:383-391`) explains exactly
why it's there: GOP length controls how long seeking stalls in **any** player (VLC, QuickTime,
mpv, not just a hypothetical in-app preview) after a scrub, since decoding can only resume at a
keyframe. Removing it outright would reintroduce that stall on exports with sparse keyframes.

Correct fix: **relax** the interval rather than delete it — e.g. 5–10 seconds instead of 2 —
trading a small, bounded seek delay for real bitrate savings. This also matters more once T6.2
lands: forcing a keyframe every 2s fights a modern encoder's own scene-cut detection, which
already places keyframes intelligently. Pick the new interval empirically once Tier 6 is in
place; a hard number now would be a guess.

### T1.5 — Guard bit depth in two places

No explicit `-pix_fmt`/`-profile:v main10` anywhere in `Clipper.swift`. Two independent, silent
failure points:
- The main encoder path — a 10-bit source can silently become 8-bit output on hardware without
  10-bit HEVC encode support.
- The `-vf scale=-2:H` resize path (`Clipper.swift:389-391`, used when export resolution
  differs from source) — scaling can independently drop bit depth if the filter chain isn't
  told to preserve it.

Add a `pixFmt: String?` field to `VideoProbe.Info` (not currently probed at all — needs a new
`ffprobe` query, not just reading an existing field). Set `-pix_fmt` explicitly on both the
direct-encode and scale-filter paths, and fail loudly with a clear message if the selected
encoder can't support the source's bit depth — never degrade silently. Note reliable 10-bit
support detection for `hevc_videotoolbox` usually only surfaces at encode time (stderr), not
via a static capability query — plan to parse the failure rather than pre-detect it.

### T1.6 — Preserve chapters and metadata

Precise path currently drops chapters and global metadata (Fast keeps them via `-c copy`). Add
`-map_chapters 0 -map_metadata 0` to `preciseArguments()`.

### T1.7 — Fix video-stream selection in VideoProbe

`VideoProbe.swift:106` (`-select_streams v:0`) picks the first video-typed stream
unconditionally. A file whose first video stream is embedded cover art (`mjpeg`,
`disposition:attached_pic=1`) gets probed as a 0×0 "video," which misfires downstream
(resolution matching, the new T1.3 bitrate calc, the scale filter).

Filter stream selection to exclude `disposition:attached_pic=1` when picking the primary video
stream.

### Tier 1 verification gate

Re-run the `video-loss-audit.md` runbook against a 10-bit HEVC source's "Same Quality" tier
(same clip length as the prior audit rounds, for a direct before/after comparison), **plus**
an H.264 source with many subtitle tracks exported to MP4 (to test T1.1's `mov_text` path and
T1.2's MP4 audio-copy path).

Required before Tier 2:
- Subtitle tracks present in MKV export; present as `mov_text` (or explicitly logged as
  dropped) in MP4 export — no silent loss, no crash
- Chapters and metadata present in the export
- Audio bit-exact against the source span (MKV output)
- Video bitrate no longer exceeds the source span's actual video bitrate
- Export no longer larger than a lossless copy of the same span
- A source with embedded cover art probes its real video stream, not the artwork

Report the numbers in the same table shape as the prior audit reports. Do not proceed if any
check fails.

---

## Tier 2 — Trust and visibility (cheap, high impact, no encoder changes)

These don't change what gets encoded — they make the app show what it's doing, which both
audit rounds kept having to reverse-engineer from source code.

### T2.1 — "Copy ffmpeg command" button

Surface the exact invocation `Clipper` builds, copyable to clipboard.

### T2.2 — Pre-export summary panel

Before the export runs, show what `Clipper` already knows:

```
Video: H.265 10-bit → re-encoded (libx265, CRF 20)
Audio: E-AC-3 5.1 → copied
Subtitles: 2 tracks → copied
Chapters: copied
Fast-mode start: 00:04:58 (requested 00:05:00, snapped to nearest keyframe)
```

**Do not include an estimated output size.** Predicting CRF output size before encoding is
unreliable (routinely off 30%+), and a wrong number in a panel whose whole purpose is trust is
worse than no number.

### T2.3 — Show the actual Fast-mode snap point

`Clipper` already computes `nearestKeyframeTimestamp`. Display the requested time next to the
actual snapped time as the user edits, not as a surprise after export. Ship it even if T2.2
slips.

### T2.4 — Frame preview at Start/End (restored — this is the highest-leverage item in this whole plan)

**v2 dropped this without acknowledging it; put it back.** There is currently no visual
feedback anywhere in the app — you type six digits and export blind. For an app whose entire
job is "pick a range," that's the dominant gap; both audit rounds had to reverse-engineer clip
boundaries from filenames because nothing in the app shows them.

- **Minimum viable:** decode one frame at Start and one at End as the user edits —
  `ffmpeg -ss <t> -i <in> -frames:v 1 -f image2pipe -c:v png -`. No AVFoundation needed, works
  on MKV, ~50ms per frame.
- **Better, if minimum viable ships well:** a filmstrip across the range (one ffmpeg call using
  `fps=`+`tile`), click to set Start/End directly.
- This likely needs the fixed 480×480 window to grow, or become resizable — flag that as its
  own small decision when starting this task, don't guess it.

### T2.5 — Rename the tiers (ship together with Tier 6, not before)

"Same Quality" is a claim both audit rounds refute. Proposed:
- Fast path → **"Lossless (keyframe-aligned cut)"**
- Precise `.same` → **"High quality (re-encoded)"**
- Precise `.smaller` → **"Compact (re-encoded)"**

**Sequencing correction from v2:** do not ship the "High quality" rename until Tier 6 (the
actual encoder swap) has landed. Renaming the tier before the encode that makes the new label
true creates a window where the UI promises "High quality" and still delivers the current
VMAF-91-with-frames-at-41 ABR encode. Land this alongside T6.1/T6.2, not in Tier 2's own PR.

---

## Tier 3 — Track-selection checklist

Even after T1.1 stops silently dropping tracks, nobody wants all 42 subtitle tracks from a
source like the audit's F1 file by default. Add a stream picker:
- List every audio and subtitle stream with language tag and codec
- Sensible default selection (e.g. one audio track matching system language, subtitles off)
  rather than "all" or "first only"
- User's selection becomes the `-map` list, replacing T1.1's `-map 0` default

**Scope correction from v2:** this is a real usability win, but don't oversell it as a size
lever for the clip use case specifically — in the measured audits, subtitle tracks totaled
under 1 MB and extra audio tracks were single-digit MB per multi-minute clip. The actual byte
recovery here matters far more for the *arbitrary-batch*/library-remux use case than for a
single short clip. Frame it to the user as "control over what's kept," not "a way to shrink
your exports."

Depends on T1.1 shipping first.

---

## Tier 4 — Smart rendering (BLOCKED — do not start)

Re-encode only the two partial GOPs at cut boundaries, stream-copy everything between, concat.
Result: frame-accurate cuts with 99%+ of frames bit-exact.

Blocked on a short **technical spec**, not a PRD — the edge cases need nailing down before any
code: variable frame rate, open GOPs, B-pyramid reordering, concat-demuxer timestamp
continuity. Also blocked on need: the Fast path's keyframe-snapped cuts are already invisible
for trimming a movie's intro/outro. Don't build this until a real workflow shows up where a
few seconds of imprecision actually matters.

## Tier 5 — AV1 compression pipeline (SHELVED — deliberate)

Do not build this. Do not propose it. The audited library is already near the 1080p x265
efficiency frontier (~2,340–2,384 kbps on well-encoded sources); AV1 would recover perhaps
20–30% over a good x265 encode, not a multiple. Reopens only if the library also holds
true Blu-ray remuxes with real bitrate headroom — until confirmed, remaining wins are Tier 3
and Tier 6.

---

## Small items, do opportunistically (not gating any tier)

- **Persist settings.** No `UserDefaults` anywhere — every launch resets to MKV/Precise-or-
  Fast/Same/Native. Remember last-used Advanced settings and export folder.
- **Choose output folder.** Hard-coded `~/Downloads/MKV Clipper Exports`.
- **Looser time entry.** `Timecode.parse` already accepts `MM:SS`/`SS`/fractional seconds, but
  the UI field forces exactly 6 digits. Accept pasted formats like `5:00`. Consider
  frame-based entry using `VideoProbe`'s known frame rate.
- **Disk-space preflight.** Check available capacity against an estimated output size before a
  long Precise encode.
- **ETA / speed readout.** Once Tier 6's `libx265 -preset slow` is in play, exports go from
  seconds to many minutes. `-progress` already emits `speed=` — surface ETA and x-realtime,
  plus an overall ETA across a Bulk/queue batch.
- **Test target.** `build.sh` compiles only `Sources/`. `splitIntoIntervals` has float logic
  with a "must never disagree" comment and zero tests; `Timecode` is noted as "safe to unit
  test" and isn't.
- **Remux-only mode.** MKV↔MP4, `-c copy`, no trim.
- **Extract single track.** Pull one audio or subtitle stream out (`-map 0:a:1 -c copy`).
- **Arbitrary batch input.** The Export Queue already does most of a multi-file batch; missing
  piece is multi-file drop, or an EDL/CSV of `(file, in, out)` rows.

---

## Tier 6 — Replace the encoder and rate-control model (last, slowest to verify)

This is the actual size-without-quality-loss lever. Everything above it is cleanup and
visibility; this is the tier that changes what gets encoded.

### T6.1 — Delete the ABR path

Remove `-b:v` rate control from the `.same` tier (`videoEncodingArguments`,
`Clipper.swift:415-446`) entirely. Both remaining tiers become constant-quality at different
CRF/QP values.

Justification: on the 10-bit audit source, the `-q:v 60` export beat the `-b:v` export on
**both** size and VMAF simultaneously (94.6 vs 91.1 VMAF, 91.2 vs 95.6 MB). One variable
changed, constant-quality won outright. A whole-file average bitrate cannot be correct for an
arbitrary clip — this isn't a tuning problem, it's the wrong control variable.

### T6.2 — Switch from hardware to software HEVC

`hevc_videotoolbox` is a real-time hardware block, a generation behind software x265 in
rate-distortion — it structurally can't match a well-tuned x265 source at equal bitrate, which
is exactly why "Smaller" sometimes came out *bigger* than the source in the audits.

Switch to `libx265 -preset slow -crf <n>`. Expect roughly an order of magnitude slower —
acceptable for an archival operation with no latency constraint. Keep `hevc_videotoolbox`
available behind an explicit "fast preview" option if wanted; do not make it default.

### Tier 6 verification gate

Re-run the audit against the same sources used in the original two rounds, both tiers.
Required:
- No export larger than a lossless copy of the same span
- VMAF ≥ 95 on the high-quality tier for every source
- Compact tier is reliably both smaller and lower-VMAF than the high-quality tier (fixes the
  VMAF inversion the original audits found)

Report the full table in the same shape as the original audit reports for direct comparison.
Watch the 10-bit source's VMAF minimum specifically (it was 40.93 pre-fix) — it should rise
substantially.

Ship T2.5's tier rename together with this.

---

## Do not do

- Do not re-run the full audit before Tier 1 is complete — you'd be measuring known defects.
- Do not "improve" the Fast path. `-map 0 -c copy` is correct and the app's only genuinely
  lossless mode. Leave it alone.
- Do not add resolution downscaling as a size lever — worst quality-per-byte of any option.
- Do not add a target-file-size feature. Target a quality floor (CRF/CQ) instead.
- Do not put an estimated output size in the pre-export panel (T2.2).
