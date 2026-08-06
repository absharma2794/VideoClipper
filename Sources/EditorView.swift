import SwiftUI
import AppKit

/// The main editing screen: shows the loaded file's duration, and offers two
/// modes -- a single Start/End clip, or splitting a range into many
/// equal-length clips at a fixed interval. Related controls are grouped into
/// labeled cards (Range, Splitting, Output) rather than one flat list, and
/// the settings cards are fully replaced by a single focused progress card
/// while exporting.
struct EditorView: View {
    let sourceURL: URL
    let info: VideoProbe.Info
    let tools: FFmpegLocator.Tools
    let onChooseDifferentFile: () -> Void

    private enum EditMode { case single, split }
    private enum IntervalUnit { case seconds, minutes }

    @State private var mode: EditMode = .single

    @State private var startDigits = "000000"
    @State private var endDigits: String
    @State private var format: Clipper.OutputFormat = .mkv
    @State private var precise = false
    @State private var qualityTier: Clipper.QualityTier = .same
    @State private var resolution: Clipper.Resolution = .native

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

    init(sourceURL: URL, info: VideoProbe.Info, tools: FFmpegLocator.Tools, onChooseDifferentFile: @escaping () -> Void) {
        self.sourceURL = sourceURL
        self.info = info
        self.tools = tools
        self.onChooseDifferentFile = onChooseDifferentFile
        _endDigits = State(initialValue: Timecode.format(info.durationSeconds).replacingOccurrences(of: ":", with: ""))
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
        var text = "→ \(count) clip\(count == 1 ? "" : "s")"
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

    /// nil means valid; otherwise the reason Export is disabled.
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

    private var canExport: Bool { validationMessage == nil && !isExporting }

    private var exportButtonLabel: String {
        guard mode == .split else { return "Export" }
        let count = plannedIntervals.count
        return count > 0 ? "Split into \(count) Clip\(count == 1 ? "" : "s")" : "Split into Clips"
    }

    private var showQualitySection: Bool { (mode == .single && precise) || mode == .split }
    private var availableResolutions: [Clipper.Resolution] { Clipper.Resolution.availableOptions(sourceHeight: info.height) }

    private var overallProgress: Double {
        switch mode {
        case .single: return progress
        case .split:
            guard batchTotalClips > 0 else { return 0 }
            return (Double(batchCompletedClips) + progress) / Double(batchTotalClips)
        }
    }

    private var progressLabel: String {
        switch mode {
        case .single: return precise ? "Re-encoding… \(Int(progress * 100))%" : "Exporting… \(Int(progress * 100))%"
        case .split:
            let current = min(batchCompletedClips + 1, max(batchTotalClips, 1))
            return "Clip \(current) of \(batchTotalClips) — Re-encoding… \(Int(progress * 100))%"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.vertical, 16)

            Divider()

            // Plain VStack, not a ScrollView -- a ScrollView's ideal size doesn't
            // hug its content (it reports "give me whatever space is available"),
            // so when content got shorter after a mode switch, the window stayed
            // at its previous, taller size and just left dead space below the
            // cards. A plain VStack's ideal height tracks its children directly,
            // which is what `.windowResizability(.contentSize)` (set on the
            // window in MKVClipperApp.swift) needs to shrink the window back
            // down correctly. Content here is compact enough (at most 3 cards)
            // that this fits comfortably without needing to scroll.
            VStack(spacing: 20) {
                modePicker

                if isExporting {
                    progressCard
                } else {
                    rangeSection
                    if mode == .split { splittingSection }
                    outputSection
                    if let validationMessage {
                        InlineMessage(text: validationMessage, style: .warning)
                    }
                    if let errorMessage {
                        InlineMessage(text: errorMessage, style: .error, selectable: true)
                    }
                    if mode == .single, let exportResult {
                        resultBanner(exportResult)
                    }
                    if mode == .split, let batchResultURLs {
                        batchResultBanner(batchResultURLs)
                    }
                }
            }
            .padding(24)

            Divider()

            bottomBar
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
        }
        .frame(minWidth: 580)
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "film.fill").font(.title2).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(sourceURL.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
                Text("\(Timecode.format(info.durationSeconds)) total · \(info.width)×\(info.height) · \(info.videoCodec.uppercased())")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var modePicker: some View {
        Picker("Mode", selection: $mode) {
            Text("Single Clip").tag(EditMode.single)
            Text("Bulk Clip").tag(EditMode.split)
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 360)
        .disabled(isExporting)
        .onChange(of: mode) { _ in
            errorMessage = nil
            exportResult = nil
            batchResultURLs = nil
        }
    }

    private var rangeSection: some View {
        SectionCard(title: mode == .split ? "Range to Split" : "Clip Range", systemImage: "timer") {
            HStack(spacing: 28) {
                LabeledControl("Start") { TimecodeField(digits: $startDigits, disabled: isExporting) }
                LabeledControl("End") { TimecodeField(digits: $endDigits, disabled: isExporting) }
                LabeledControl("Total Duration") {
                    Text(Timecode.format(info.durationSeconds))
                        .font(.system(.body, design: .monospaced)).fontWeight(.medium).frame(height: 22)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var splittingSection: some View {
        SectionCard(title: "Splitting", systemImage: "square.stack.3d.up.fill") {
            VStack(spacing: 12) {
                HStack(spacing: 28) {
                    LabeledControl("Interval") {
                        HStack(spacing: 8) {
                            IntervalField(digits: $intervalDigits, disabled: isExporting)
                            Picker("Unit", selection: $intervalUnit) {
                                Text("Seconds").tag(IntervalUnit.seconds)
                                Text("Minutes").tag(IntervalUnit.minutes)
                            }
                            .labelsHidden().pickerStyle(.segmented).frame(width: 150)
                        }
                    }
                    LabeledControl("Buffer") {
                        HStack(spacing: 6) {
                            IntervalField(digits: $bufferDigits, disabled: isExporting)
                            Text("sec").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let splitPreviewText {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.turn.down.right").font(.caption2)
                        Text(splitPreviewText).font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .disabled(isExporting)
        }
    }

    /// Format + (Precise toggle, single-clip only) + Quality/Resolution
    /// (when relevant) all live in one card. Quality/Resolution rows
    /// appear/disappear inside it rather than the whole card appearing/
    /// disappearing, so there's always exactly one "Output" card, never a
    /// card that pops in and out.
    private var outputSection: some View {
        SectionCard(title: "Output", systemImage: "square.and.arrow.up") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 28) {
                    LabeledControl("Format") {
                        Picker("Format", selection: $format) {
                            ForEach(Clipper.OutputFormat.allCases) { f in Text(f.displayName).tag(f) }
                        }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 140)
                    }
                    if mode == .single {
                        Toggle("Precise cut (re-encodes, slower)", isOn: $precise).disabled(isExporting)
                    }
                    Spacer(minLength: 0)
                }

                if showQualitySection {
                    Divider()
                    LabeledControl("Quality Tier", alignment: .leading) {
                        Picker("Quality", selection: $qualityTier) {
                            ForEach(Clipper.QualityTier.allCases) { tier in Text(tier.displayName).tag(tier) }
                        }
                        .labelsHidden().pickerStyle(.segmented)
                    }
                    LabeledControl("Resolution", alignment: .leading) {
                        HStack(spacing: 10) {
                            Picker("Resolution", selection: $resolution) {
                                ForEach(availableResolutions) { option in Text(option.displayName).tag(option) }
                            }
                            .labelsHidden().frame(width: 140)
                            if info.width > 0, info.height > 0 {
                                Text("Current: \(info.width)×\(info.height)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .disabled(isExporting)
        }
    }

    private var progressCard: some View {
        VStack(spacing: 16) {
            Image(systemName: mode == .split ? "square.stack.3d.up.fill" : "film.fill")
                .font(.largeTitle).foregroundStyle(.tint)
            VStack(spacing: 6) {
                Text(progressLabel).font(.headline)
                if mode == .split {
                    Text("\(batchTotalClips) clips total").font(.caption).foregroundStyle(.secondary)
                }
            }
            ProgressView(value: overallProgress).frame(maxWidth: 360)
            Button("Force Stop", role: .destructive) { exportTask?.cancel() }
                .buttonStyle(.bordered).padding(.top, 4)
        }
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity)
    }

    private func resultBanner(_ result: Clipper.Result) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Saved to \(result.outputURL.lastPathComponent)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).lineLimit(2)
                Spacer(minLength: 12)
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([result.outputURL])
                }
                .buttonStyle(.bordered)
            }
            if result.usedAudioReencodeFallback {
                Text("Note: the audio track was re-encoded to AAC because it couldn't be copied directly into an MP4 container.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    private func batchResultBanner(_ urls: [URL]) -> some View {
        let sessionFolder = urls.first?.deletingLastPathComponent()
        let folderName = sessionFolder?.lastPathComponent
        return HStack {
            Label(
                "\(urls.count) clip\(urls.count == 1 ? "" : "s") saved" + (folderName.map { " to \"\($0)\"" } ?? ""),
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green).lineLimit(2)
            Spacer(minLength: 12)
            Button("Reveal in Finder") {
                if let sessionFolder {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: sessionFolder.path)
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    private var bottomBar: some View {
        HStack(spacing: 16) {
            Button("Choose a Different File", action: onChooseDifferentFile).disabled(isExporting)
            Spacer()
            Button(exportButtonLabel) { startExport() }
                .buttonStyle(.borderedProminent)
                .disabled(!canExport)
                .keyboardShortcut(.defaultAction)
        }
    }

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
            precise: precise, qualityTier: qualityTier, resolution: resolution
        )

        exportTask = Task {
            do {
                let result = try await Clipper.export(request, tools: tools) { fraction in
                    Task { @MainActor in progress = fraction }
                }
                await MainActor.run {
                    self.exportResult = result
                    self.isExporting = false
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
                    self.batchResultURLs = urls
                    self.isExporting = false
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

/// A titled card grouping related controls, with a subtle background so
/// sections read as distinct groups rather than one flat wall of controls.
private struct SectionCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary, lineWidth: 1))
    }
}

/// A small caption label stacked above its control -- the one label style
/// used everywhere in this screen instead of mixing inline Picker labels
/// with above-control captions.
private struct LabeledControl<Content: View>: View {
    let label: String
    var alignment: HorizontalAlignment = .center
    @ViewBuilder let content: Content

    init(_ label: String, alignment: HorizontalAlignment = .center, @ViewBuilder content: () -> Content) {
        self.label = label
        self.alignment = alignment
        self.content = content()
    }

    var body: some View {
        VStack(alignment: alignment, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            content
        }
    }
}

/// A validation warning or error message with a matching icon and tinted
/// background, so it reads as a message rather than blending into the form.
private struct InlineMessage: View {
    enum Style { case warning, error }
    let text: String
    let style: Style
    var selectable = false

    private var color: Color { style == .warning ? .orange : .red }
    private var icon: String { style == .warning ? "exclamationmark.triangle.fill" : "xmark.octagon.fill" }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            Group {
                if selectable {
                    Text(text).textSelection(.enabled)
                } else {
                    Text(text)
                }
            }
            .font(.callout)
            .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// A text field that only ever accepts digits, capped at 6 (HHMMSS), auto-inserting
/// the ":" separators as they're typed. Whitespace, letters, punctuation, and any
/// digit beyond the 6th are silently dropped rather than shown -- there is no
/// intermediate invalid state to correct.
private struct TimecodeField: View {
    @Binding var digits: String
    var disabled: Bool = false

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
        .font(.system(.body, design: .monospaced))
        .multilineTextAlignment(.center)
        .frame(width: 110)
        .disabled(disabled)
    }
}

/// A text field that only accepts digits, capped at 2 (1-99) -- used for the
/// bulk-split interval count and buffer. Same all-digits, no-invalid-state
/// approach as `TimecodeField`, just without colon insertion.
private struct IntervalField: View {
    @Binding var digits: String
    var disabled: Bool = false

    var body: some View {
        TextField("0", text: Binding(
            get: { digits },
            set: { newValue in digits = String(newValue.filter(\.isNumber).prefix(2)) }
        ))
        .textFieldStyle(.roundedBorder)
        .font(.system(.body, design: .monospaced))
        .multilineTextAlignment(.center)
        .frame(width: 60)
        .disabled(disabled)
    }
}
