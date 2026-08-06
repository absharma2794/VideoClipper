# MKV Clipper — Proposed Design Templates

**Date:** 6 August 2026
**Status:** Under review — 3 candidates implemented and live-testable, none finalized yet.
**Trigger:** The Bulk Clip screen had grown cluttered as features accumulated (mode picker, range, interval, buffer, format, quality, resolution, progress) with no visual grouping — flagged as "not user friendly at all" against this screenshot:

| Before |
|---|
| Flat single-screen layout: every control (Mode, Range, Interval, Buffer, Format, Quality, Resolution) visible simultaneously with no sectioning, even while a 218-clip export was actively running (`Clip 196 of 218`) alongside all the still-interactive-looking settings controls. |

This document records the three redesign directions proposed, their rationale, and where to find the working implementations — kept for future reference regardless of which ones get discarded.

---

## How to compare them yourself

All three are fully working (not just mockups) on the `design-variants-toggle` branch, sharing the exact same export logic — only layout differs. Check out that branch, run `./build.sh`, open the app, load a file, and use the yellow **"Design preview"** switcher at the top of the editor screen to flip between them live, including running real exports through each.

A static, non-interactive visual comparison (all 3 side by side, settings state + export state) is also available as a Claude Artifact from the same session this document was written in — search the conversation for "MKV Clipper — Redesign Options" if it's still accessible.

---

## The shared problem

1. **No visual hierarchy.** Every control reads at the same weight — nothing distinguishes "this is a section" from "this is a field."
2. **Everything shown at once, always.** Advanced/occasional settings (Quality, Resolution, Buffer) compete for attention with the two or three things actually needed for a typical export.
3. **No focus state while exporting.** A 200+ clip batch export left every settings control visible (if disabled), fighting the progress bar for attention.

All three candidates fix (3) the same way: **settings are fully replaced by a single focused progress view while exporting** — not just dimmed. They differ in how they organize the *settings* state.

---

## Option 1 — Grouped Cards

*File: `Sources/EditorViewCards.swift`*

Related controls are boxed into labeled, icon-headed sections — **Range**, **Splitting** (Bulk Clip only), **Output**, **Quality** — each in its own subtly-bordered card. Everything stays on one screen and one scroll, but the eye can chunk the form into four groups instead of reading it as one long list.

```
┌─────────────────────────────────────┐
│ 🎬 filename.mkv · duration · codec   │
├─────────────────────────────────────┤
│  [ Single Clip | Bulk Clip ]         │
│                                       │
│  ┌─ ⏱ RANGE TO SPLIT ─────────────┐  │
│  │  Start   End   Total Duration  │  │
│  └─────────────────────────────────┘  │
│  ┌─ ▦ SPLITTING ──────────────────┐  │
│  │  Interval        Buffer        │  │
│  │  → 218 clips (…)                │  │
│  └─────────────────────────────────┘  │
│  ┌─ ⇧ OUTPUT & QUALITY ───────────┐  │
│  │  Format  Quality  Resolution   │  │
│  └─────────────────────────────────┘  │
│                                       │
│  [Choose a Different File] [Split →] │
└─────────────────────────────────────┘
```

**Strengths**
- Lowest risk / most familiar — closest to today's structure, just organized.
- Nothing hidden: every setting is visible before you commit, which matters for a batch export you can't easily undo mid-way.
- Smallest implementation diff from the current app.

**Tradeoffs**
- Still a fair amount on screen at once, even if grouped.
- Doesn't reduce the *number* of decisions before exporting, just their legibility.

**Best if:** the fix should feel like a polish pass, not a different app.

---

## Option 2 — Sidebar Navigator

*File: `Sources/EditorViewSidebar.swift`*

Settings move into categories in a left sidebar (**Range**, **Splitting**, **Output**, **Quality**), System Settings / Xcode-preferences style. The detail pane shows exactly one category's controls at a time; Mode picker and the Export bar stay persistent across category switches.

```
┌───────────┬───────────────────────┐
│ filename  │ [ Single | Bulk Clip ] │
│ duration  │                       │
│           │  Splitting             │
│ ⏱ Range   │  How the range gets    │
│ ▦ Split.. │  divided into clips.   │
│ ⇧ Output  │                       │
│ ⚙ Quality │  Interval: [30] [Sec]  │
│           │  Buffer:   [2] sec     │
│           │  → 218 clips           │
│           │                       │
│           │ [Choose File] [Split →]│
└───────────┴───────────────────────┘
```

**Strengths**
- Most native-feeling on macOS — mirrors a pattern users already know how to scan.
- Scales best if more settings get added later (this app already grew from 1 mode to 2, gaining quality tiers and a buffer field along the way — likely not the last addition).
- Never more than one group of controls visible → least visual noise at any instant.

**Tradeoffs**
- Costs a click to move between categories — can't eyeball Range and Quality simultaneously.
- Slower for "just tweak one number and go" than the other two.

**Best if:** stepping through settings deliberately beats scanning a full form.

---

## Option 3 — Focused Flow

*File: `Sources/EditorViewFocused.swift`*

No card chrome at all. Just Range and Interval are on screen by default; **Buffer, Quality, and Resolution live behind one "Advanced" disclosure**. The bet: most exports don't touch those three, so don't make everyone pay for them visually every time.

```
┌─────────────────────────────────────┐
│           filename.mkv               │
│         1920×1080 · H264             │
│                                       │
│       [ Single Clip | Bulk Clip ]    │
│                                       │
│         Start        End             │
│       00:00:00     01:48:53          │
│         of 01:48:53 total            │
│                                       │
│           SPLIT EVERY                │
│         [30] [Sec|Min]               │
│           → 218 clips                │
│                                       │
│         ▸ Advanced                   │
│                                       │
│      [ Split into 218 Clips ]        │
│      Choose a Different File         │
└─────────────────────────────────────┘
```

Export/progress state leans into the minimalism further — a large `196/218` clip counter as the focal point rather than a labeled progress bar.

**Strengths**
- Fastest for the common case: two decisions (range, interval) instead of seven.
- Biggest visual departure — reads as a deliberately redesigned, not just reorganized, app.

**Tradeoffs**
- Buffer/Quality/Resolution require an extra click+expand to reach — a real cost for anyone who *does* tune those often.
- Furthest from today's layout, so re-learning cost is highest of the three.

**Best if:** default quality/buffer settings are used most of the time, and the common path (range + interval) should be as fast as possible.

---

## Decision log

*(fill in once a direction is chosen)*

- **Chosen:** —
- **Why:** —
- **What changed from the chosen candidate before finalizing:** —
- **Cleanup performed:** delete `Sources/EditorView{Cards,Sidebar,Focused}.swift` except the winner (renamed back to `Sources/EditorView.swift`), remove the "Design preview" switcher from `Sources/ContentView.swift`, delete the `design-variants-toggle` branch.
