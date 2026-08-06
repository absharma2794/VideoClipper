# MKV Clipper

A tiny, single-purpose macOS app: drag in an `.mkv` (or `.mp4`) file, type a
start and end time, hit **Export**, get a clipped file in `~/Downloads`. No
timeline, no filters, no re-encoding unless you ask for it.

Built for personal use and distributed only via this GitHub repo — it is
not notarized or App Store–signed.

## Why it needs ffmpeg

macOS's own media framework (AVFoundation) has no Matroska (`.mkv`) demuxer
— it simply can't open these files. This app shells out to
[ffmpeg](https://ffmpeg.org) to read and cut them instead. There's no way
around this requirement on macOS.

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
2. The total duration appears automatically.
3. Type a **Start** and **End** time as `HH:MM:SS`.
4. Pick an output format — MKV or MP4.
5. Hit **Export**. The clip lands in `~/Downloads` and Finder can reveal it
   for you.

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
- Clips land in `~/Downloads`, named with their own time range (same scheme
  as single-clip exports), so **Reveal in Finder** opens the folder rather
  than one file.
- **Force Stop** stops the whole batch — the clip in progress is killed and
  its partial file removed; clips already finished are left in place.

## Notes

- Apple Silicon only by default (`./build.sh`). Pass `--universal` to also
  build for Intel.
- ffmpeg is GPL-licensed; this app does not bundle or redistribute it — it
  only locates and shells out to whatever copy you've installed via
  Homebrew.
- No sandboxing/entitlements: the app is unsandboxed so it can read your
  chosen file and write to `~/Downloads` without extra ceremony. That's a
  reasonable tradeoff for a personal, GitHub-only tool — don't repackage
  this for the App Store as-is.
