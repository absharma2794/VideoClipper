import SwiftUI
import AppKit

/// Everything needed to reopen `EditorView` on an already-loaded file with a
/// past export's settings pre-filled, for "Export Another Version of This
/// File" reached from the Queue screen -- a fresh `EditorView` instance has
/// no state of its own to carry those settings, unlike the in-place version
/// of this same action reached directly from the completed page (see
/// `EditorView.exportAnotherVersion()`), which just leaves its own `@State`
/// untouched instead. Always lands in Single Clip mode -- the queue only
/// ever runs single-clip exports (Bulk Clip is excluded from it entirely).
struct EditorPrefill {
    var startDigits: String
    var endDigits: String
    var format: Clipper.OutputFormat
    var precise: Bool
    var qualityTier: Clipper.QualityTier
    var resolution: Clipper.Resolution
    var selectedAudioTracks: Set<Int>
    var selectedSubtitleTracks: Set<Int>
    var useSoftwareEncoder: Bool

    init(job: ExportJob) {
        startDigits = Self.digits(from: job.request.start)
        endDigits = Self.digits(from: job.request.end)
        format = job.request.format
        precise = job.request.precise
        qualityTier = job.request.qualityTier
        resolution = job.request.resolution
        selectedAudioTracks = job.request.selectedAudioTracks
        selectedSubtitleTracks = job.request.selectedSubtitleTracks
        useSoftwareEncoder = job.request.useSoftwareEncoder
    }

    private static func digits(from seconds: Double) -> String {
        Timecode.format(seconds).replacingOccurrences(of: ":", with: "")
    }
}

/// A paged wizard, not a single scrolling form: each step is its own page,
/// navigated with Back/Next like pushing and popping a stack, always
/// sliding a whole new page in rather than reflowing the current one in
/// place. Every page (and the drop zone / ffmpeg setup screens outside this
/// view) renders in the same fixed square window.
struct EditorView: View {
    let sourceURL: URL
    let info: VideoProbe.Info
    let tools: FFmpegLocator.Tools
    let onChooseDifferentFile: () -> Void
    let onQueueRequested: () -> Void

    private enum EditMode { case single, split }
    private enum IntervalUnit { case seconds, minutes }
    private enum Page { case modeSelect, rangeSettings, advancedSettings }

    @State private var page: Page = .modeSelect
    @State private var navigatingForward = true

    @State private var mode: EditMode = .single

    @State private var startDigits = "000000"
    @State private var endDigits: String
    @State private var format: Clipper.OutputFormat = .mkv
    // "Precise cut" is checked by default: the exact-frame re-encode is the
    // behavior most users expect from a clipper, so it's opt-out rather
    // than opt-in. (TASKS-lossless.md T0 had briefly flipped this to Fast-
    // by-default; reverted per user request.)
    @State private var precise = true
    @State private var qualityTier: Clipper.QualityTier = .same
    @State private var resolution: Clipper.Resolution = .native
    // Off by default -> hardware `hevc_videotoolbox` (fast, low power). On
    // -> `libx265 -preset slow` (much slower, better compression). See
    // Clipper.Request.useSoftwareEncoder.
    @State private var useSoftwareEncoder = false

    // Tier 3: which audio/subtitle tracks a Precise export maps, editable
    // via the checklist in the export summary popover. Seeded in `init`
    // below to `Clipper.defaultTrackSelection`'s "one track matching
    // system language, subtitles off" -- or, when reopened via "Export
    // Another Version of This File", to that job's own exact selection.
    @State private var selectedAudioTracks: Set<Int>
    @State private var selectedSubtitleTracks: Set<Int>

    @State private var intervalDigits = "30"
    @State private var intervalUnit: IntervalUnit = .seconds
    @State private var bufferDigits = "0"

    @State private var isExporting = false
    @State private var progress: Double = 0
    @State private var exportResult: Clipper.Result?
    @State private var errorMessage: String?
    @State private var exportTask: Task<Void, Never>?

    @State private var batchCompletedClips = 0
    @State private var batchTotalClips = 0
    @State private var batchResultURLs: [URL]?

    @ObservedObject private var queue = ExportQueue.shared

    // T2.1/T2.2/T2.3: the pre-export summary popover shown from Advanced
    // Settings. `fastSnapPreview` is guarded by matching `.requested`
    // against the live start time when displayed, since it's computed
    // asynchronously and could otherwise show a stale snap point after the
    // user edits Start again while the popover is still open.
    @State private var showExportSummary = false
    @State private var fastSnapPreview: (requested: Double, actual: Double)?
    @State private var copiedCommandFeedback = false

    // T2.4: live Start/End frame previews on the Range Settings page.
    @State private var startThumbnailState: ThumbnailState = .loading
    @State private var endThumbnailState: ThumbnailState = .loading

    init(sourceURL: URL, info: VideoProbe.Info, tools: FFmpegLocator.Tools, onChooseDifferentFile: @escaping () -> Void, onQueueRequested: @escaping () -> Void, prefill: EditorPrefill? = nil) {
        self.sourceURL = sourceURL
        self.info = info
        self.tools = tools
        self.onChooseDifferentFile = onChooseDifferentFile
        self.onQueueRequested = onQueueRequested
        if let prefill {
            _mode = State(initialValue: .single)
            _startDigits = State(initialValue: prefill.startDigits)
            _endDigits = State(initialValue: prefill.endDigits)
            _format = State(initialValue: prefill.format)
            _precise = State(initialValue: prefill.precise)
            _qualityTier = State(initialValue: prefill.qualityTier)
            _resolution = State(initialValue: prefill.resolution)
            _selectedAudioTracks = State(initialValue: prefill.selectedAudioTracks)
            _selectedSubtitleTracks = State(initialValue: prefill.selectedSubtitleTracks)
            _useSoftwareEncoder = State(initialValue: prefill.useSoftwareEncoder)
            _page = State(initialValue: .rangeSettings)
        } else {
            _endDigits = State(initialValue: Timecode.format(info.durationSeconds).replacingOccurrences(of: ":", with: ""))
            let defaults = Clipper.defaultTrackSelection(sourceInfo: info)
            _selectedAudioTracks = State(initialValue: defaults.audio)
            _selectedSubtitleTracks = State(initialValue: defaults.subtitles)
        }
    }

    private var fullDurationDigits: String {
        Timecode.format(info.durationSeconds).replacingOccurrences(of: ":", with: "")
    }

    private var parsedStart: Double? { Self.seconds(fromDigits: startDigits) }
    private var parsedEnd: Double? { Self.seconds(fromDigits: endDigits) }

    private static func seconds(fromDigits digits: String) -> Double? {
        guard digits.count == 6 else { return nil }
        let hh = digits.prefix(2)
        let mm = digits.dropFirst(2).prefix(2)
        let ss = digits.suffix(2)
        return Timecode.parse("\(hh):\(mm):\(ss)")
    }

    private var intervalSeconds: Double? {
        guard let count = Int(intervalDigits), count > 0 else { return nil }
        return Double(count) * (intervalUnit == .minutes ? 60 : 1)
    }

    private var bufferSeconds: Double { Double(bufferDigits) ?? 0 }

    private var plannedIntervals: [(start: Double, end: Double)] {
        guard mode == .split, let start = parsedStart, let end = parsedEnd, end > start,
              let interval = intervalSeconds else { return [] }
        return Clipper.splitIntoIntervals(rangeStart: start, rangeEnd: end, intervalSeconds: interval, bufferSeconds: bufferSeconds)
    }

    private var splitPreviewText: String? {
        let intervals = plannedIntervals
        guard !intervals.isEmpty, let interval = intervalSeconds else { return nil }
        let count = intervals.count
        var text = "\(count) clip\(count == 1 ? "" : "s")"
        var notes: [String] = []
        if bufferSeconds > 0 && count > 1 {
            notes.append("clip 2 onward include a \(Int(bufferSeconds.rounded()))s buffer")
        }
        if let last = intervals.last, (last.end - last.start) < interval - 0.001 {
            notes.append("last clip: \(Int((last.end - last.start).rounded()))s")
        }
        if !notes.isEmpty { text += " (\(notes.joined(separator: ", ")))" }
        return text
    }

    private var validationMessage: String? {
        if startDigits.count < 6 { return "Start time is incomplete." }
        guard let start = parsedStart else { return "Start time isn't a valid HH:MM:SS value." }
        if endDigits.count < 6 { return "End time is incomplete." }
        guard let end = parsedEnd else { return "End time isn't a valid HH:MM:SS value." }
        if start >= end { return "End time must be after start time." }
        if end > info.durationSeconds + 0.5 { return "End time is beyond the video's duration." }
        if mode == .split {
            guard intervalSeconds != nil else { return "Enter an interval greater than 0." }
        }
        return nil
    }

    // `queue.activeCount == 0` closes a real concurrency hole: without it, a
    // running/queued job wouldn't stop the direct Export path from starting
    // a *second*, fully independent ffmpeg process at the same time -- two
    // exports genuinely running at once, which is exactly what routing
    // everything through one sequential queue was supposed to prevent. This
    // also means the direct progress/completed pages below can never appear
    // while the queue is active, since Export is the only way to reach them.
    private var canExport: Bool { validationMessage == nil && !isExporting && queue.activeCount == 0 }
    // Deliberately independent of `isExporting`/`queue.activeCount` --
    // queueing more work is exactly what you're meant to keep doing while
    // something else is already running.
    private var canAddToQueue: Bool { validationMessage == nil && queue.canEnqueue }

    private var exportButtonLabel: String {
        guard mode == .split else { return "Export" }
        let count = plannedIntervals.count
        return count > 0 ? "Split into \(count) Clip\(count == 1 ? "" : "s")" : "Split into Clips"
    }

    private var availableResolutions: [Clipper.Resolution] { Clipper.Resolution.availableOptions(sourceHeight: info.height) }

    private var overallProgress: Double {
        switch mode {
        case .single: return progress
        case .split:
            guard batchTotalClips > 0 else { return 0 }
            return (Double(batchCompletedClips) + progress) / Double(batchTotalClips)
        }
    }

    private var hasCompletedResult: Bool {
        (mode == .single && exportResult != nil) || (mode == .split && batchResultURLs != nil)
    }

    private var completedText: String {
        switch mode {
        case .single:
            return "Saved to \(exportResult?.outputURL.lastPathComponent ?? "")"
        case .split:
            guard let urls = batchResultURLs else { return "" }
            let folderName = urls.first?.deletingLastPathComponent().lastPathComponent
            return "\(urls.count) clip\(urls.count == 1 ? "" : "s") saved" + (folderName.map { " to \"\($0)\"" } ?? "")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if isExporting {
                progressPage
            } else if hasCompletedResult {
                completedPage
            } else if errorMessage != nil {
                stoppedPage
            } else {
                Group {
                    switch page {
                    case .modeSelect: modeSelectPage
                    case .rangeSettings: rangeSettingsPage
                    case .advancedSettings: advancedSettingsPage
                    }
                }
                .id(page)
                .transition(wizardPageTransition(navigatingForward: navigatingForward))
            }
        }
        .frame(width: 480, height: 480)
        // Same top-leading spot on all three configuration pages (Mode
        // Select, Range Settings, Advanced Settings) -- not shown during
        // progress/completed/stopped, where Force Stop/Done/Go Back already
        // own the navigation and a surprise jump back to the drop zone
        // would be an odd thing to expose mid-export. Advanced Settings'
        // own title had to move to center to make room for this (see
        // advancedSettingsPage's header) -- it used to sit exactly here.
        .overlay(alignment: .topLeading) {
            if !isExporting && !hasCompletedResult && errorMessage == nil {
                homeButton.padding(16)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: page)
        .animation(.easeInOut(duration: 0.3), value: isExporting)
        .animation(.easeInOut(duration: 0.3), value: hasCompletedResult)
        .animation(.easeInOut(duration: 0.3), value: errorMessage != nil)
        .onChange(of: mode) { _ in
            errorMessage = nil
            exportResult = nil
            batchResultURLs = nil
            // Start/End are shared state across both modes -- without this,
            // a range narrowed for a quick Single Clip test silently carried
            // into Bulk Clip, splitting only that leftover range instead of
            // the whole file with no indication anything was wrong.
            startDigits = "000000"
            endDigits = fullDurationDigits
        }
    }

    // MARK: - Navigation

    private func goNext() {
        navigatingForward = true
        switch page {
        case .modeSelect: page = .rangeSettings
        case .rangeSettings: page = .advancedSettings
        case .advancedSettings: break
        }
    }

    private func goBack() {
        navigatingForward = false
        switch page {
        case .modeSelect: break
        case .rangeSettings: page = .modeSelect
        case .advancedSettings: page = .rangeSettings
        }
    }

    private func resetAdvancedSettings() {
        format = .mkv
        precise = true
        qualityTier = .same
        resolution = .native
        useSoftwareEncoder = false
        bufferDigits = "0"
        // Reset also sends the user back to the Range page rather than
        // leaving them on Advanced Settings -- Range already has its own
        // "← Back" if they need to go further than that.
        navigatingForward = false
        page = .rangeSettings
    }

    // MARK: - Page 2: Mode select

    private var modeSelectPage: some View {
        VStack(spacing: 24) {
            fileHeader
            Spacer(minLength: 0)
            VStack(spacing: 14) {
                Text("Choose a mode").font(.headline)
                HStack(spacing: 16) {
                    modeCard(.single, title: "Single Clip", subtitle: "Cut one range from the file", icon: "film")
                    modeCard(.split, title: "Bulk Clip", subtitle: "Split into many equal clips", icon: "square.stack.3d.up.fill")
                }
            }
            Spacer(minLength: 0)
            HStack {
                Button(action: onChooseDifferentFile) {
                    Text("Choose a Different File").underline()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                QueueBubble(count: queue.jobs.count, isRunning: queue.isRunning, onTap: onQueueRequested)
                Button("Next →") { goNext() }
                    .buttonStyle(.capsuleProminent)
                    .controlSize(.large)
            }
        }
        .padding(28)
    }

    private func modeCard(_ target: EditMode, title: String, subtitle: String, icon: String) -> some View {
        let selected = mode == target
        return Button {
            mode = target
            goNext()
        } label: {
            VStack(spacing: 10) {
                Image(systemName: icon).font(.title)
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(width: 170, height: 130)
            .background(selected ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(selected ? Color.accentColor : Color.gray.opacity(0.25), lineWidth: selected ? 2 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Page 3: Range settings

    private var rangeSettingsPage: some View {
        VStack(spacing: 24) {
            Text(mode == .split ? "Range to Split" : "Clip Range").font(.headline)
            Spacer(minLength: 0)
            VStack(spacing: 24) {
                VStack(spacing: 10) {
                    HStack(spacing: 36) {
                        LabeledWizardControl("Start", labelFont: .subheadline) { TimecodeFieldFocused(digits: $startDigits) }
                        LabeledWizardControl("End", labelFont: .subheadline) { TimecodeFieldFocused(digits: $endDigits) }
                    }
                    Text("of \(Timecode.format(info.durationSeconds)) total")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // Single Clip only -- Bulk Clip's page is already full with
                // its own interval/preview controls, and "Start/End" there
                // describes the whole range being split, not one clip's
                // boundaries, so a frame preview reads less usefully there.
                if mode == .single {
                    rangeThumbnails
                }

                if mode == .split {
                    VStack(spacing: 10) {
                        Text("SPLIT EVERY").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).tracking(0.6)
                        HStack(spacing: 10) {
                            IntervalFieldFocused(digits: $intervalDigits, large: true)
                            Picker("Unit", selection: $intervalUnit) {
                                Text("Sec").tag(IntervalUnit.seconds)
                                Text("Min").tag(IntervalUnit.minutes)
                            }
                            .labelsHidden().pickerStyle(.segmented).controlSize(.large).frame(width: 145)
                        }
                        if let splitPreviewText {
                            Text("→ \(splitPreviewText)")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.tint)
                        }
                    }
                }

                if let validationMessage {
                    Text(validationMessage)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
            }
            Spacer(minLength: 0)
            HStack {
                Button("← Back") { goBack() }.buttonStyle(.capsule)
                Spacer()
                QueueBubble(count: queue.jobs.count, isRunning: queue.isRunning, onTap: onQueueRequested)
                Button("Next →") { goNext() }
                    .buttonStyle(.capsuleProminent)
                    .controlSize(.large)
                    .disabled(validationMessage != nil)
            }
        }
        .padding(28)
    }

    // MARK: - Range thumbnails (T2.4)

    private enum ThumbnailState {
        case loading, image(NSImage), unavailable
    }

    /// The two live Start/End frame previews -- previously the app gave no
    /// visual feedback at all about what a chosen range actually contained,
    /// so every trim was picked blind and only checked after a full export.
    /// Debounced via the `.task(id:)` below rather than firing an ffmpeg
    /// decode on every keystroke.
    private var rangeThumbnails: some View {
        HStack(spacing: 20) {
            thumbnailBox(startThumbnailState, label: "Start")
            thumbnailBox(endThumbnailState, label: "End")
        }
        .task(id: "\(startDigits)|\(endDigits)") {
            // `.task(id:)` cancels the previous instance of this task the
            // moment `id` changes, so a short sleep here acts as a debounce
            // "for free" -- typing further just keeps re-cancelling this
            // before it ever reaches the actual (slower, process-spawning)
            // decode below, rather than piling up an ffmpeg launch per keystroke.
            startThumbnailState = .loading
            endThumbnailState = .loading
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            async let start = loadThumbnail(at: parsedStart)
            // A hair before the requested end -- `end` itself is the
            // exclusive boundary of the clip, so decoding exactly at it can
            // land one frame past what the export will actually contain.
            // Also clamped below the video stream's own known duration:
            // the Start/End fields round to whole seconds, so a range's
            // "End" digits can name a time a fraction of a second past the
            // last real frame (e.g. a 242.6s stream showing "00:04:03" =
            // 243s) -- seeking there gets zero bytes back from ffmpeg, not
            // an error, which used to read as a stuck spinner forever
            // rather than the "nothing to show here" it actually is.
            async let end = loadThumbnail(at: parsedEnd.map { min(max($0 - 0.1, 0), info.durationSeconds - 0.1) })
            let (startResult, endResult) = await (start, end)
            guard !Task.isCancelled else { return }
            startThumbnailState = startResult
            endThumbnailState = endResult
        }
    }

    private func loadThumbnail(at timestamp: Double?) async -> ThumbnailState {
        guard let timestamp, timestamp >= 0 else { return .unavailable }
        guard let data = try? await FrameThumbnailer.frame(from: sourceURL, atSeconds: timestamp, ffmpegPath: tools.ffmpeg),
              let image = NSImage(data: data) else { return .unavailable }
        return .image(image)
    }

    private func thumbnailBox(_ state: ThumbnailState, label: String) -> some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.25))
                switch state {
                case .loading:
                    ProgressView().controlSize(.small)
                case .image(let image):
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                case .unavailable:
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                        .opacity(0.5)
                }
            }
            .frame(width: 150, height: 84)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Page 4: Advanced settings + Export

    private var advancedSettingsPage: some View {
        VStack(spacing: 12) {
            // Centered rather than leading -- this is the one page whose
            // title used to sit exactly where `homeButton` (an overlay on
            // the whole EditorView, not part of this page) now lives, so it
            // moved out of that corner instead of overlapping it.
            ZStack {
                Text("Advanced Settings").font(.headline)
                HStack {
                    Spacer()
                    Button("Reset") { resetAdvancedSettings() }
                        .buttonStyle(.capsule)
                        .controlSize(.small)
                }
            }

            // Every page centers its content on the exact midpoint of the
            // fixed square window -- equal `Spacer`s above and below a
            // naturally-sized content block, the same technique the Mode
            // Select and Range Settings pages already use. That's a precise,
            // symmetric center by construction, unlike the earlier
            // ScrollView + measured-height attempt here, which produced
            // uneven gaps. Spacing is kept tight enough that even Bulk
            // mode's longer field list (Buffer, two notes, Format, Quality,
            // Resolution) fits without needing to scroll at all.
            Spacer(minLength: 0)
            // Bulk mode has twice the rows (Buffer, two notes, Format,
            // Quality, Resolution) as Single mode, so the same spacing that
            // looks right on one overflows the fixed window on the other --
            // 40pt of gap here pushed the Export button off-screen entirely
            // in Bulk mode. Kept tighter there, full 40pt on Single.
            VStack(spacing: mode == .split ? 20 : 40) {
                if mode == .single {
                    Toggle("Precise cut (re-encodes, slower)", isOn: $precise)
                        .toggleStyle(.checkbox)
                        .tint(.blue)
                        .font(.system(size: 14))
                }

                if mode == .split {
                    LabeledWizardControl("Buffer (seconds)", labelFont: .system(size: 13)) {
                        HStack(spacing: 6) {
                            IntervalFieldFocused(digits: $bufferDigits)
                            Text("sec").font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                    }
                    noteRow("Overlaps each clip with the end of the one before it, so nothing gets cut off mid-moment. Clip 1 is unaffected.")
                }

                LabeledWizardControl("Format", labelFont: .system(size: 13)) {
                    Picker("Format", selection: $format) {
                        ForEach(Clipper.OutputFormat.allCases) { f in Text(f.displayName).tag(f) }
                    }
                    .labelsHidden().pickerStyle(.segmented).controlSize(.large).frame(width: 155)
                }

                if mode == .split {
                    noteRow("Bulk clips are always precisely cut, so every clip starts exactly on time.")
                }

                LabeledWizardControl("Quality", labelFont: .system(size: 13)) {
                    Picker("Quality", selection: $qualityTier) {
                        ForEach(Clipper.QualityTier.allCases) { tier in Text(tier.displayName).tag(tier) }
                    }
                    .labelsHidden().pickerStyle(.segmented).controlSize(.large).frame(width: 330)
                }
                LabeledWizardControl("Resolution", labelFont: .system(size: 13)) {
                    HStack(spacing: 8) {
                        Picker("Resolution", selection: $resolution) {
                            ForEach(availableResolutions) { option in Text(option.displayName).tag(option) }
                        }
                        .labelsHidden().controlSize(.large).frame(width: 145)
                        Text("(\(info.width)×\(info.height) native)").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }

                // Only meaningful when something actually re-encodes: a
                // Single Clip with Precise on, or any Bulk Clip run (always
                // re-encodes). Off = hardware `hevc_videotoolbox` (fast, low
                // power); on = `libx265 -preset slow` (much slower, all
                // cores, better compression).
                if mode == .split || precise {
                    VStack(spacing: 2) {
                        Toggle("Use software encoder (much slower, best compression)", isOn: $useSoftwareEncoder)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 12))
                        Text(useSoftwareEncoder
                             ? "libx265 · minutes per clip, pins every CPU core"
                             : "Apple hardware HEVC · near-instant, low power")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)

            HStack {
                Button("← Back") { goBack() }.buttonStyle(.capsule)
                exportSummaryButton
                Spacer()
                QueueBubble(count: queue.jobs.count, isRunning: queue.isRunning, onTap: onQueueRequested)
                // Single Clip only -- Bulk Clip already runs as its own
                // sequential batch within one wizard action, so it's
                // excluded from the queue entirely rather than mixing two
                // different kinds of multi-export operation into it.
                if mode == .single {
                    Button("Add to Queue") { addToQueue() }
                        .buttonStyle(.capsule)
                        .controlSize(.large)
                        .disabled(!canAddToQueue)
                }
                Button(exportButtonLabel) { startExport() }
                    .buttonStyle(.capsuleProminent)
                    .controlSize(.large)
                    .disabled(!canExport)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    // MARK: - Pre-export summary (T2.1/T2.2/T2.3)

    /// A request built from the current settings purely to describe what
    /// exporting would do -- never passed to `Clipper.export` itself. Bulk
    /// Clip always runs Precise (see `Clipper.exportBatch`), so the preview
    /// mirrors that even though the on-page toggle only exists in Single mode.
    private var previewRequest: Clipper.Request {
        let start = parsedStart ?? 0
        let end = max(parsedEnd ?? (start + 1), start + 0.001)
        return Clipper.Request(
            sourceURL: sourceURL, sourceInfo: info, start: start, end: end, format: format,
            precise: mode == .split ? true : precise, qualityTier: qualityTier, resolution: resolution,
            useSoftwareEncoder: useSoftwareEncoder,
            selectedAudioTracks: mode == .split ? Clipper.defaultTrackSelection(sourceInfo: info).audio : selectedAudioTracks,
            selectedSubtitleTracks: mode == .split ? [] : selectedSubtitleTracks
        )
    }

    private var exportSummaryButton: some View {
        Button {
            showExportSummary = true
        } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("What will this export do?")
        .popover(isPresented: $showExportSummary, arrowEdge: .top) {
            exportSummaryPopover
        }
    }

    private var exportSummaryPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("This export will:").font(.subheadline.weight(.semibold))
            ForEach(Clipper.summaryLines(for: previewRequest), id: \.self) { line in
                Text(line).font(.caption).foregroundStyle(.secondary)
            }
            // T2.3: Fast mode can only start on an actual keyframe, so the
            // real start point can land a little before the requested one --
            // shown here instead of as a surprise after export.
            if !previewRequest.precise, let fastSnapPreview, fastSnapPreview.requested == previewRequest.start {
                Text("Lossless-mode start: \(Timecode.format(fastSnapPreview.actual)) (requested \(Timecode.format(fastSnapPreview.requested)))")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            // Tier 3: only meaningful for a Single Clip Precise export --
            // Fast keeps its own fixed, untouched map (see the Fast-path
            // guardrail in TASKS-lossless.md), and Bulk Clip has no picker
            // at all, always using `Clipper.defaultTrackSelection`.
            if mode == .single, precise, !info.audioStreams.isEmpty || !info.subtitleStreams.isEmpty {
                Divider()
                Text("Tracks to include:").font(.subheadline.weight(.semibold))
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(info.audioStreams) { track in
                            trackToggle(track.displayName, isOn: selectedAudioTracks.contains(track.typeIndex)) { isOn in
                                if isOn { selectedAudioTracks.insert(track.typeIndex) } else { selectedAudioTracks.remove(track.typeIndex) }
                            }
                        }
                        if !info.subtitleStreams.isEmpty {
                            if !info.audioStreams.isEmpty { Divider() }
                            ForEach(info.subtitleStreams) { track in
                                trackToggle(track.displayName, isOn: selectedSubtitleTracks.contains(track.typeIndex)) { isOn in
                                    if isOn { selectedSubtitleTracks.insert(track.typeIndex) } else { selectedSubtitleTracks.remove(track.typeIndex) }
                                }
                            }
                        }
                    }
                }
                // Bounded rather than left to grow with the source -- a
                // file like the audit's own F1 source (42 subtitle tracks)
                // would otherwise turn this popover into most of the screen.
                .frame(maxHeight: 140)
            }
            Divider()
            Button {
                copyFFmpegCommand()
            } label: {
                Label(copiedCommandFeedback ? "Copied!" : "Copy ffmpeg Command", systemImage: copiedCommandFeedback ? "checkmark" : "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.capsule)
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 280)
        .task(id: showExportSummary) {
            guard showExportSummary, !previewRequest.precise else { return }
            let start = previewRequest.start
            let actual = await Clipper.nearestKeyframeTimestamp(atOrBefore: start, sourceURL: sourceURL, tools: tools)
            fastSnapPreview = (requested: start, actual: actual)
        }
    }

    /// One row of the Tier 3 track checklist -- a plain checkbox toggle
    /// bound to whichever `Set<Int>` (`selectedAudioTracks` or
    /// `selectedSubtitleTracks`) the caller closes over.
    private func trackToggle(_ label: String, isOn: Bool, set: @escaping (Bool) -> Void) -> some View {
        Toggle(label, isOn: Binding(get: { isOn }, set: set))
            .toggleStyle(.checkbox)
            .font(.caption)
    }

    private func copyFFmpegCommand() {
        let request = previewRequest
        Task {
            let text = await Clipper.previewCommandLine(for: request, tools: tools)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            copiedCommandFeedback = true
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copiedCommandFeedback = false
        }
    }

    private func noteRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.circle")
            Text(text)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .frame(maxWidth: 360)
    }

    // MARK: - Page 5: Progress

    private var progressPage: some View {
        WizardProgressPage(
            counter: {
                if mode == .split {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(min(batchCompletedClips + 1, max(batchTotalClips, 1)))")
                            .font(.system(size: 46, weight: .thin, design: .rounded))
                        Text("/\(batchTotalClips)")
                            .font(.system(size: 22, weight: .thin, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    .monospacedDigit()
                } else {
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 46, weight: .thin, design: .rounded))
                        .monospacedDigit()
                }
            },
            statusText: mode == .split ? "Re-encoding this clip… \(Int(progress * 100))%" : (precise ? "Re-encoding…" : "Exporting…"),
            progress: overallProgress,
            onForceStop: { exportTask?.cancel() }
        )
    }

    // MARK: - Page 6/7: Completed

    private var completedPage: some View {
        WizardCompletedPage(
            message: completedText,
            note: completedNote,
            onReveal: revealCompletedResult,
            // Done now means "I'm finished with this file" -- straight back
            // to the drop zone, the same as "Choose a Different File" used
            // to be a separate link for. With Export Another Version below
            // covering "keep working on this file", that second link was
            // just a redundant middle option between the two.
            onDone: onChooseDifferentFile,
            secondaryActionLabel: "Export Another Version of This File",
            onSecondaryAction: exportAnotherVersion
        )
    }

    /// Single Clip only -- Bulk Clip always runs Precise with a fixed
    /// request shape (see `Clipper.exportBatch`) that doesn't hit either of
    /// these fallback paths on the timescale a user would wait around for.
    private var completedNote: String? {
        guard mode == .single, let exportResult else { return nil }
        var notes: [String] = []
        if exportResult.usedAudioReencodeFallback {
            notes.append("Note: the audio track was re-encoded to AAC because it couldn't be copied directly into an MP4 container.")
        }
        notes.append(contentsOf: exportResult.warnings)
        return notes.isEmpty ? nil : notes.joined(separator: "\n")
    }

    private func revealCompletedResult() {
        switch mode {
        case .single:
            if let url = exportResult?.outputURL {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        case .split:
            if let folder = batchResultURLs?.first?.deletingLastPathComponent() {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
            }
        }
    }

    /// Deliberately leaves every setting untouched (range, format, quality,
    /// resolution) -- the whole point is tweaking just one thing (a
    /// different resolution, a different range) without re-entering
    /// everything else, per the user's own "trim a different interval on
    /// the 2nd export" use case. Lands on Range Settings specifically, one
    /// step ahead of Advanced Settings, matching that same use case. Unlike
    /// Done, which now leaves the file behind entirely, this stays on it.
    private func exportAnotherVersion() {
        exportResult = nil
        batchResultURLs = nil
        navigatingForward = true
        page = .rangeSettings
    }

    // MARK: - Page 8: Stopped mid-way

    private var stoppedPage: some View {
        WizardStoppedPage(message: errorMessage ?? "Export stopped.") {
            errorMessage = nil
            navigatingForward = false
            page = .rangeSettings
        }
    }

    // MARK: - homeButton

    /// Same action as "Choose a Different File" (below, on Mode Select
    /// only) -- this is that same escape hatch, just reachable from every
    /// configuration page instead of only the first one.
    private var homeButton: some View {
        Button(action: onChooseDifferentFile) {
            Image(systemName: "house.fill")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.bordered)
        .tint(.blue)
        .clipShape(Circle())
        .help("Back to Home")
    }

    // MARK: - fileHeader

    private var fileHeader: some View {
        VStack(spacing: 3) {
            Text(sourceURL.lastPathComponent)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 400)
            Text("\(info.width)×\(info.height) · \(info.videoCodec.uppercased())")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Add to Queue

    /// Builds the same request `startSingleExport` below already builds, but
    /// hands it to `ExportQueue` instead of running a local blocking `Task`
    /// -- this touches none of `isExporting`/`progress`/`exportTask`, which
    /// remain exclusively the direct-Export path's state. Single Clip only;
    /// the button that calls this is hidden entirely in Bulk Clip mode.
    private func addToQueue() {
        guard let start = parsedStart, let end = parsedEnd else { return }
        let request = Clipper.Request(
            sourceURL: sourceURL, sourceInfo: info, start: start, end: end, format: format,
            precise: precise, qualityTier: qualityTier, resolution: resolution,
            useSoftwareEncoder: useSoftwareEncoder,
            selectedAudioTracks: selectedAudioTracks, selectedSubtitleTracks: selectedSubtitleTracks
        )
        let summary = "\(resolution.displayName) · \(Timecode.format(start))–\(Timecode.format(end))"
        let job = ExportJob(request: request, tools: tools, settingsSummary: summary)
        queue.enqueue(job)
    }

    // MARK: - Export

    private func startExport() {
        switch mode {
        case .single: startSingleExport()
        case .split: startBatchExport()
        }
    }

    private func startSingleExport() {
        guard let start = parsedStart, let end = parsedEnd else { return }
        errorMessage = nil
        exportResult = nil
        progress = 0
        isExporting = true

        let request = Clipper.Request(
            sourceURL: sourceURL, sourceInfo: info, start: start, end: end, format: format,
            precise: precise, qualityTier: qualityTier, resolution: resolution,
            useSoftwareEncoder: useSoftwareEncoder,
            selectedAudioTracks: selectedAudioTracks, selectedSubtitleTracks: selectedSubtitleTracks
        )

        exportTask = Task {
            do {
                let result = try await Clipper.export(request, tools: tools) { fraction in
                    Task { @MainActor in progress = fraction }
                }
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        self.exportResult = result
                        self.isExporting = false
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isExporting = false
                }
            }
        }
    }

    private func startBatchExport() {
        let intervals = plannedIntervals
        guard !intervals.isEmpty else { return }
        errorMessage = nil
        batchResultURLs = nil
        batchCompletedClips = 0
        batchTotalClips = intervals.count
        progress = 0
        isExporting = true

        exportTask = Task {
            do {
                let urls = try await Clipper.exportBatch(
                    sourceURL: sourceURL, sourceInfo: info, intervals: intervals,
                    format: format, qualityTier: qualityTier, resolution: resolution, tools: tools
                ) { completed, total, fraction in
                    Task { @MainActor in
                        batchCompletedClips = completed
                        batchTotalClips = total
                        progress = fraction
                    }
                }
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        self.batchResultURLs = urls
                        self.isExporting = false
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isExporting = false
                }
            }
        }
    }
}


private struct TimecodeFieldFocused: View {
    @Binding var digits: String

    private var displayText: String {
        var result = ""
        for (index, character) in digits.enumerated() {
            if index == 2 || index == 4 { result.append(":") }
            result.append(character)
        }
        return result
    }

    var body: some View {
        TextField("HH:MM:SS", text: Binding(
            get: { displayText },
            set: { newValue in digits = String(newValue.filter(\.isNumber).prefix(6)) }
        ))
        .textFieldStyle(.roundedBorder)
        .font(.system(.title2, design: .monospaced))
        .multilineTextAlignment(.center)
        .frame(width: 150)
    }
}

private struct IntervalFieldFocused: View {
    @Binding var digits: String
    var large: Bool = false

    var body: some View {
        TextField("0", text: Binding(
            get: { digits },
            set: { newValue in digits = String(newValue.filter(\.isNumber).prefix(2)) }
        ))
        .textFieldStyle(.roundedBorder)
        .font(large ? .system(size: 22, design: .monospaced) : .system(.body, design: .monospaced))
        .multilineTextAlignment(.center)
        .frame(width: large ? 70 : 60)
    }
}
