# MKV Clipper

A tiny, single-purpose macOS app for cutting and merging `.mkv`/`.mp4` files.
Drop in a file, pick a range, hit **Export** — or merge many whole files into
one, with chapter markers, in a separate flow. No timeline, no filters, no
re-encoding unless you ask for it.

Built for personal use and distributed only via this GitHub repo — it is
not notarized or App Store–signed. The whole app lives in a fixed,
non-resizable 480×480 window.

## Why it needs ffmpeg

macOS's own media framework (AVFoundation) has no Matroska (`.mkv`) demuxer
— it simply can't open these files. This app shells out to
[ffmpeg](https://ffmpeg.org) (and `ffprobe`) to read, cut, and merge them
instead. There's no way around this requirement on macOS.

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

## Using it: clipping a single file

1. Drag an `.mkv` or `.mp4` onto the window (or click **Choose File…**, or
   the **I know you have a .mp4 file** link if that's what you've got).
2. A short wizard walks you through three steps:
   - **Mode** — choose **Single Clip** (one clip) or **Bulk Clip** (many
     equal-length clips, see below).
   - **Clip Range** (or **Range to Split** in Bulk Clip) — type a **Start**
     and **End** time as `HH:MM:SS`; the total duration is shown automatically.
   - **Advanced Settings** — output format (MKV/MP4), Fast vs. Precise (or
     Quality/Resolution in Bulk Clip — see below).
3. Hit **Export**. The clip lands in `~/Downloads/MKV Clipper Exports` and
   Finder can reveal it for you when it's done.

### Fast vs. Precise cuts

| Mode | Speed | How it cuts |
|---|---|---|
| **Fast** (default) | Near-instant | Copies the original video/audio streams without re-encoding. Lossless, but the actual start point snaps to the nearest keyframe — on typical recordings (e.g. OBS) that can be up to a few seconds off from what you typed. |
| **Precise** (checkbox) | Slower | Re-encodes so the start and end land exactly where you typed them. Takes noticeably longer on long clips. |

Turn on **Precise cut** when the exact frame matters; leave it off for
quick, lossless trims.

### Precise mode: Quality and Resolution

Turning on **Precise cut** reveals two more choices:

| Quality | What it does |
|---|---|
| **Smaller** | Re-encodes with hardware-accelerated HEVC (H.265). Dramatically smaller files (often ~5–7x smaller than H.264) at comparable visual quality, same resolution, similar speed — thanks to your Mac's dedicated video encoder. |
| **Same Quality** | Matches the source's own codec family and bitrate as closely as possible, so a shorter clip comes out proportionally smaller — the way you'd expect "clipping" to behave. |
| **Highest Quality** | Always re-encodes to H.264 at a fixed high-quality setting. Prioritizes precision/quality over file size — expect the largest files here, sometimes larger than the source. |

**Resolution** lets you optionally downscale (never upscale — that only wastes space, it doesn't add real detail) to 540p/720p/1080p/1440p/4K, shown alongside the source's actual resolution. Leave it on **Native** to keep the original pixel dimensions.

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
  clips tile the source with zero gaps or duplicated frames. (Fast/Precise
  isn't a choice here: Fast mode's keyframe-snapped start, fine for one clip,
  would misalign every clip boundary in a batch.) Quality and Resolution
  work the same as in Precise mode above.
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

## Using it: merging many files into one

Click **Merge Multiple Files into One…** on the drop-zone screen (a separate
flow from clipping — it doesn't need a file loaded first). Use case: you've
downloaded a whole tutorial playlist as 100+ separate lesson files and want
one file on disk, with each lesson reachable as a chapter marker your media
player can jump between.

1. **Select Files** — drag in or **Add Files…** to pick many `.mkv`/`.mp4`
   files at once. They're automatically ordered by any number in their
   filename (natural sort — `[1] Intro.mp4`, `[2] Setup.mp4`, …), so name
   your files sequentially before adding them if they aren't already; you can
   also drag rows to reorder manually and edit each one's chapter title
   inline. At least 2 files are required to continue.
2. The app probes every file (video/audio codec, resolution, frame rate,
   sample rate) and checks they're compatible for a lossless merge. If any
   file doesn't match the others, a page lists exactly which files and which
   property differ — merging only works when every file agrees, since this
   is a pure stream-copy (no re-encode fallback in this version).
3. **Output Settings** — name the merged file and choose MKV or MP4.
   MKV chapters work in VLC (macOS & Android) but not in QuickTime Player;
   MP4 works in both, so it's the default.
4. Hit **Merge**. The combined file, with a chapter marker at every original
   file's boundary (titled from that file's chapter title), lands in
   `~/Downloads/MKV Clipper Exports`.

This is a fast-path-only merge (ffmpeg's concat demuxer, stream copy) — it's
lossless and fast, but it's why mismatched source files are rejected up front
rather than silently producing a broken or re-encoded result.

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
                           the drop zone, the clip wizard, and the merge flow
  DropZoneView.swift       The initial "drop a file" / "merge files" screen
  EditorView.swift          Single Clip / Bulk Clip paged wizard
  MergeClipsView.swift      Merge-many-files-into-one paged wizard
  WizardComponents.swift    Page transition + progress/completed/stopped page
                           views shared by both wizards
  Clipper.swift            Single-file clip/split export logic, ffmpeg process
                           orchestration, output-path/folder naming
  ClipMerger.swift          Merge business logic: bounded-concurrency probing,
                           compatibility checking, concat + chapter generation
  VideoProbe.swift          ffprobe-based metadata probing (duration, codecs,
                           resolution, frame rate, sample rate, …)
  FFmpegLocator.swift       Finds the user's ffmpeg/ffprobe install
  FFmpegSetupView.swift     "Install ffmpeg" screen shown when it's missing
  Timecode.swift            HH:MM:SS formatting/parsing helpers
build.sh                   Compiles Sources/*.swift into MKVClipper.app
```
