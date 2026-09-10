# MKV Clipper

A tiny, single-purpose macOS app for cutting `.mkv`/`.mp4` files. Drop in a
file, pick a range, hit **Export** — or queue up several exports and let
them run one after another while you keep working. No timeline, no filters,
no re-encoding unless you ask for it.

Built for personal use and distributed only via this GitHub repo — it is
not notarized or App Store–signed. The whole app lives in a fixed,
non-resizable 480×480 window.

## Why it needs ffmpeg

macOS's own media framework (AVFoundation) has no Matroska (`.mkv`) demuxer
— it simply can't open these files. This app shells out to
[ffmpeg](https://ffmpeg.org) (and `ffprobe`) to read and cut them instead.
There's no way around this requirement on macOS.

### Install ffmpeg (one-time)

```bash
brew install ffmpeg
```

If you don't have Homebrew, install it first from [brew.sh](https://brew.sh).
The app will detect ffmpeg automatically; if it's missing, launch the app
anyway — it shows the exact command above and a **Re-check** button.

## Building

Requires Xcode Command Line Tools (a full Xcode install is *not* required):

```bash
xcode-select --install   # if you don't already have the CLT
```

Then:

```bash
./build.sh
```

This compiles straight from `Sources/*.swift` with `swiftc` and assembles
`MKVClipper.app` — there's no `.xcodeproj` to open. Double-click the app,
or:

```bash
open MKVClipper.app
```

If you built a universal binary (`./build.sh --universal`, covers both
Apple Silicon and Intel) or downloaded a pre-built copy from a GitHub
release, macOS Gatekeeper will flag it as being from an unidentified
developer since it's only ad-hoc signed. Clear the quarantine flag once:

```bash
xattr -dr com.apple.quarantine MKVClipper.app
```

## Using it

1. Drag an `.mkv` or `.mp4` onto the window (or click **Choose File…**, or
   the **I know you have a .mp4 file** link if that's what you've got).
2. A short wizard walks you through three steps:
   - **Mode** — choose **Single Clip** (one clip) or **Bulk Clip** (many
     equal-length clips, see below).
   - **Clip Range** (or **Range to Split** in Bulk Clip) — type a **Start**
     and **End** time as `HH:MM:SS`; the total duration is shown
     automatically, alongside a live preview frame at each of Start and End
     so you can see what you're actually cutting before you export.
   - **Advanced Settings** — output format (MKV/MP4), Lossless vs. Precise
     (or Quality/Resolution in Bulk Clip — see below), which audio/subtitle
     tracks to keep, and an **ⓘ** summary of exactly what the export will do
     — with a **Copy ffmpeg Command** button for the exact invocation.
3. Hit **Export**. The clip lands in `~/Downloads/MKV Clipper Exports` and
   Finder can reveal it for you when it's done.

### Lossless vs. Precise cuts

| Mode | Speed | How it cuts |
|---|---|---|
| **Lossless** | Near-instant | Copies the original video/audio/subtitle streams without re-encoding — bit-identical to the source. The actual start point snaps to the nearest keyframe, though — on typical recordings (e.g. OBS) that can be up to a few seconds off from what you typed. The Advanced Settings summary panel shows the real snapped start before you export. |
| **Precise** (default) | Slower | Re-encodes so the start and end land exactly where you typed them. Takes noticeably longer on long clips — see Quality below for the tradeoffs this involves. |

**Precise cut** is checked by default; uncheck it for quick, lossless trims
when the exact frame doesn't matter.

### Precise mode: Quality, Encoder, and Resolution

Turning on **Precise cut** reveals a few more choices. Every tier re-encodes
to HEVC (H.265) at a fixed constant-quality target, chosen so a shorter clip
just costs proportionally less — the same way a lossless copy already
behaves, rather than targeting a whole-file average bitrate (which doesn't
have a well-defined right answer for an arbitrary-length clip):

| Quality | What it does |
|---|---|
| **Compact** | Meaningfully smaller files, at the cost of some visible quality — the lowest-quality option of the three. |
| **High Quality** | The default balance of size and quality — visually near-indistinguishable from the source in testing, with real margin. |
| **Highest Quality** | Effectively transparent, largest files of the three. Can exceed the source's own size. |

**Encoder** (checkbox, default off):

| | Speed & power | Compression |
|---|---|---|
| **Hardware** (default) | Near-instant, negligible battery — runs on Apple Silicon's dedicated video-encoding chip | Good |
| **Software** (`Use software encoder`) | Roughly 10× slower, pins every CPU core for the whole run, heavy battery drain | Better — a re-encode is much more likely to come out smaller than the source |

Leave it on **Hardware** for everyday use, especially on battery or for
long clips. Turn on **Software** when the machine is plugged in, the clip is
worth the wait, and you want the smallest file — or when a 10-bit source
needs its bit depth preserved (the hardware encoder can't always do 10-bit).

Every Precise export also carries through the source's chapters and global
metadata, and (on the software encoder) preserves 10-bit color depth rather
than silently dropping to 8-bit — failing loudly instead if the hardware
encoder can't produce 10-bit output on your Mac.

**Resolution** lets you optionally downscale (never upscale — that only wastes space, it doesn't add real detail) to 540p/720p/1080p/1440p/4K, shown alongside the source's actual resolution. Leave it on **Native** to keep the original pixel dimensions.

### Choosing audio and subtitle tracks

For a Single Clip Precise export, the **ⓘ** summary on Advanced Settings
lists every audio and subtitle track the source has (language, codec, and
title where available) with a checkbox next to each. The default selection
is one audio track matching your Mac's system language (or the first track,
if none match) with subtitles off — not "every track," which would carry
along tracks nobody asked for on a source with many of them, and not "first
track only," which would silently miss the one a non-English speaker
actually wants.

Exporting to MP4 can only carry text-based subtitle formats (it converts
them to `mov_text`); an image-based subtitle track (e.g. PGS/VobSub, common
on Blu-ray rips) can't convert and is left out of an MP4 export specifically
— MKV output keeps it. Either way, a dropped track is always reported in
the completed-export note, never left out silently.

Lossless exports and Bulk Clip both keep their own fixed track behavior
(everything, and one default-language audio track respectively) — the
checklist only applies to a Single Clip Precise export.

### Bulk Clip: splitting into equal-length clips

Switch the **Mode** picker to **Bulk Clip** to turn a long recording into
many fixed-length clips automatically — e.g. a 1-hour video into
120×30-second clips — instead of exporting one clip at a time.

- **Start**/**End** define the range to split (defaults to the whole video).
- **Interval** is a number (1–99) plus a **Seconds**/**Minutes** unit picker.
  A live preview shows exactly how many clips that produces, e.g. `→ 120
  clips`, updating as you type. If the range doesn't divide evenly, the last
  clip is shorter and the preview says so (`→ 3 clips (last clip: 5s)`).
- Split mode always re-encodes with frame-exact boundaries — consecutive
  clips tile the source with zero gaps or duplicated frames. (Lossless/Precise
  isn't a choice here: Lossless mode's keyframe-snapped start, fine for one
  clip, would misalign every clip boundary in a batch.) Quality and
  Resolution work the same as in Precise mode above.
- **Buffer (seconds)** is optional and defaults to `0`. When set, every clip
  *except the first* starts that many seconds earlier than its exact
  boundary, so consecutive clips overlap slightly instead of cutting apart
  cleanly — useful if you don't want to lose context right at a cut. Example:
  a 1-minute video split into 6×10s clips with a 1s buffer gives clip 1 at
  10s, and clips 2–6 at 11s each (only the start moves back; the last clip
  still ends exactly at the end of your range, not past it).
- Each Bulk Clip run gets its own folder, named after the source file, inside
  the general exports folder — e.g. `~/Downloads/MKV Clipper
  Exports/vacation/` for a run on `vacation.mkv`, keeping one session's
  many same-named-but-different-timestamp clips together and out of the
  general folder. Running Bulk Clip again on the same file creates
  `vacation (2)/` rather than mixing with the first run. **Reveal in
  Finder** opens that session's actual folder.
- **Force Stop** stops the whole batch — the clip in progress is killed and
  its partial file removed; clips already finished are left in place.

### Queueing multiple exports

On the Advanced Settings page of a **Single Clip** export, **Add to Queue**
sits next to **Export**. Use it instead of Export to line up several exports
— e.g. the same file at 1080p and again at 720p, or a different range each
time — without waiting for one to finish before configuring the next.

- Up to 20 exports at a time (1 running + 19 waiting); they run strictly one
  after another, never in parallel, so quality and thermal behavior are
  identical to a direct Export.
- A small pill showing how many are queued appears on every page once
  there's anything in the queue — tap it to open the Export Queue screen.
  Tapping a running or finished job's row expands it in place for a closer
  look; the badge itself always gets you back to the full list.
- **Export Another Version of This File** (on a finished job's row, or on
  the completed page after a direct Export) reopens that file with the same
  range/format/quality/resolution already filled in, ready to tweak just one
  thing and export again.
- **Bulk Clip** isn't queueable — it already runs as its own batch within
  one export.

## Notes

- Apple Silicon only by default (`./build.sh`). Pass `--universal` to also
  build for Intel.
- ffmpeg is GPL-licensed; this app does not bundle or redistribute it — it
  only locates and shells out to whatever copy you've installed via
  Homebrew.
- No sandboxing/entitlements: the app is unsandboxed so it can read your
  chosen file(s) and write to `~/Downloads` without extra ceremony. That's a
  reasonable tradeoff for a personal, GitHub-only tool — don't repackage
  this for the App Store as-is.

## Project layout

```
Sources/
  MKVClipperApp.swift     App entry point
  AppDelegate.swift       App-quit cleanup (kills any running ffmpeg exports)
  AppState.swift          Shared app-level state
  ContentView.swift        Top-level view: fixed 480×480 window, routes between
                           the drop zone, the clip wizard, and the export queue
  DropZoneView.swift       The initial "drop a file here" screen
  EditorView.swift          Single Clip / Bulk Clip paged wizard
  ExportQueue.swift         The export queue: sequential job execution engine
  ExportQueueView.swift     The export queue's screen
  WizardComponents.swift    Page transition + progress/completed/stopped page
                           views, and the queue-count pill, shared across
                           the wizard and the queue screen
  Clipper.swift            Single-file clip/split export logic, ffmpeg process
                           orchestration, output-path/folder naming, and the
                           pre-export summary/ffmpeg-command preview
  VideoProbe.swift          ffprobe-based metadata probing (duration, codecs,
                           resolution, frame rate, sample rate, bit depth,
                           every audio/subtitle track, chapters, …)
  FrameThumbnailer.swift    Decodes a single preview frame at a given
                           timestamp, for the Range Settings page's live
                           Start/End thumbnails
  FFmpegLocator.swift       Finds the user's ffmpeg/ffprobe install
  FFmpegSetupView.swift     "Install ffmpeg" screen shown when it's missing
  Timecode.swift            HH:MM:SS formatting/parsing helpers
build.sh                   Compiles Sources/*.swift into MKVClipper.app
```
