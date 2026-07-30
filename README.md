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
| **Fast** (default) | Near-instant | Copies the original video/audio streams without re-encoding. Lossless, but the actual start point snaps to the nearest keyframe — on typical recordings (e.g. OBS) that can be up to ~2 seconds off from what you typed. |
| **Precise** (checkbox) | Slower | Re-encodes video (H.264) so the start and end land exactly where you typed them. Takes noticeably longer on long clips and involves a small quality re-encode. |

Turn on **Precise cut** when the exact frame matters; leave it off for
quick, lossless trims.

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
