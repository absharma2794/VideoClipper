import SwiftUI
import AppKit

/// The main editing screen: shows the loaded file's duration, and offers two
/// modes -- a single Start/End clip, or splitting a range into many
/// equal-length clips at a fixed interval.
struct EditorView: View {
    let sourceURL: URL
    let info: VideoProbe.Info
    let tools: FFmpegLocator.Tools
    let onChooseDifferentFile: () -> Void

    private enum EditMode { case single, split }
    private enum IntervalUnit { case seconds, minutes }

    @State private var mode: EditMode = .single

    /// Raw digits only (up to 6, "HHMMSS") -- TimecodeField is the only thing
    /// that writes to these, and it strips everything but digits. In Split
    /// mode these define the *range* to split, not a single clip.
    @State private var startDigits = "000000"
    @State private var endDigits: String
    @State private var format: Clipper.OutputFormat = .mkv
    @State private var precise = false
    @State private var qualityTier: Clipper.QualityTier = .same
    @State private var resolution: Clipper.Resolution = .native

    @State private var intervalDigits = "30"
    @State private var intervalUnit: IntervalUnit = .seconds
    /// Seconds only, per request -- no unit picker for this one. "0" (the
    /// default) means no buffer, identical to today's behavior.
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

    private var bufferSeconds: Double {
        Double(bufferDigits) ?? 0
    }

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
        if !notes.isEmpty {
            text += " (\(notes.joined(separator: ", ")))"
        }
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

    private var canExport: Bool {
        validationMessage == nil && !isExporting
    }

    private var exportButtonLabel: String {
        guard mode == .split else { return "Export" }
        let count = plannedIntervals.count
        return count > 0 ? "Split into \(count) Clip\(count == 1 ? "" : "s")" : "Split into Clips"
    }

    var body: some View {
        VStack(alignment: .center, spacing: 18) {
            header

            Picker("Mode", selection: $mode) {
                Text("Single Clip").tag(EditMode.single)
                Text("Bulk Clip").tag(EditMode.split)
            }
            .pickerStyle(.segmented)
            .frame(width: 340)
            .disabled(isExporting)
            .onChange(of: mode) { _ in
                errorMessage = nil
                exportResult = nil
                batchResultURLs = nil
            }

            HStack(spacing: 24) {
                TimecodeField(label: mode == .split ? "Range Start" : "Start", digits: $startDigits, disabled: isExporting)
                TimecodeField(label: mode == .split ? "Range End" : "End", digits: $endDigits, disabled: isExporting)
                VStack(alignment: .center, spacing: 4) {
                    Text("Total duration").font(.caption).foregroundStyle(.secondary)
                    Text(Timecode.format(info.durationSeconds)).font(.system(.body, design: .monospaced))
                }
            }

            HStack(spacing: 20) {
                Picker("Format", selection: $format) {
                    ForEach(Clipper.OutputFormat.allCases) { f in
                        Text(f.displayName).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 160)

                if mode == .single {
                    Toggle("Precise cut (re-encodes, slower)", isOn: $precise)
                }
            }

            if mode == .split {
                intervalRow
            }

            // Batch splitting always re-encodes to hit exact, gap-free boundaries
            // between clips -- so quality/resolution are always relevant there,
            // not gated behind a toggle the way single-clip Precise mode is.
            if (mode == .single && precise) || mode == .split {
                preciseOptionsView
            }

            if let validationMessage, !isExporting {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }

            if isExporting {
                VStack(alignment: .center, spacing: 8) {
                    ProgressView(value: overallProgress)
                        .frame(maxWidth: 320)
                    Text(progressLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Force Stop", role: .destructive) {
                        exportTask?.cancel()
                    }
                    .buttonStyle(.bordered)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }

            if mode == .single, let exportResult {
                resultBanner(exportResult)
            }
            if mode == .split, let batchResultURLs {
                batchResultBanner(batchResultURLs)
            }

            Spacer()

            HStack(spacing: 16) {
                Button("Choose a Different File", action: onChooseDifferentFile)
                    .disabled(isExporting)
                Button(exportButtonLabel) { startExport() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canExport)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 380)
        .frame(maxWidth: .infinity)
    }

    private var overallProgress: Double {
        switch mode {
        case .single:
            return progress
        case .split:
            guard batchTotalClips > 0 else { return 0 }
            return (Double(batchCompletedClips) + progress) / Double(batchTotalClips)
        }
    }

    private var progressLabel: String {
        switch mode {
        case .single:
            return precise ? "Re-encoding… \(Int(progress * 100))%" : "Exporting… \(Int(progress * 100))%"
        case .split:
            let current = min(batchCompletedClips + 1, max(batchTotalClips, 1))
            return "Clip \(current) of \(batchTotalClips) — Re-encoding… \(Int(progress * 100))%"
        }
    }

    private var availableResolutions: [Clipper.Resolution] {
        Clipper.Resolution.availableOptions(sourceHeight: info.height)
    }

    private var preciseOptionsView: some View {
        VStack(spacing: 6) {
            Picker("Quality", selection: $qualityTier) {
                ForEach(Clipper.QualityTier.allCases) { tier in
                    Text(tier.displayName).tag(tier)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 340)

            HStack(spacing: 8) {
                Text("Resolution")
                Picker("Resolution", selection: $resolution) {
                    ForEach(availableResolutions) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .labelsHidden()
                .frame(width: 140)

                if info.width > 0, info.height > 0 {
                    Text("Current: \(info.width)×\(info.height)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(isExporting)
    }

    private var intervalRow: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text("Interval")
                IntervalField(digits: $intervalDigits, disabled: isExporting)
                Picker("Unit", selection: $intervalUnit) {
                    Text("Seconds").tag(IntervalUnit.seconds)
                    Text("Minutes").tag(IntervalUnit.minutes)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 160)

                Text("Buffer")
                IntervalField(digits: $bufferDigits, disabled: isExporting)
                Text("sec").font(.caption).foregroundStyle(.secondary)
            }
            if let splitPreviewText {
                Text(splitPreviewText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(isExporting)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "film.fill").foregroundStyle(.secondary)
            Text(sourceURL.lastPathComponent)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func resultBanner(_ result: Clipper.Result) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Saved to \(result.outputURL.lastPathComponent)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .lineLimit(2)
                Spacer(minLength: 12)
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([result.outputURL])
                }
                .buttonStyle(.bordered)
            }
            if result.usedAudioReencodeFallback {
                Text("Note: the audio track was re-encoded to AAC because it couldn't be copied directly into an MP4 container.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.green.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 480)
    }

    private func batchResultBanner(_ urls: [URL]) -> some View {
        let sessionFolder = urls.first?.deletingLastPathComponent()
        let folderName = sessionFolder?.lastPathComponent
        return HStack {
            Label(
                "\(urls.count) clip\(urls.count == 1 ? "" : "s") saved" + (folderName.map { " to \"\($0)\"" } ?? ""),
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
            .lineLimit(2)
            Spacer(minLength: 12)
            Button("Reveal in Finder") {
                if let sessionFolder {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: sessionFolder.path)
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(12)
        .background(Color.green.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 480)
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
                    Task { @MainActor in
                        progress = fraction
                    }
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

/// A text field that only ever accepts digits, capped at 6 (HHMMSS), auto-inserting
/// the ":" separators as they're typed. Whitespace, letters, punctuation, and any
/// digit beyond the 6th are silently dropped rather than shown -- there is no
/// intermediate invalid state to correct.
private struct TimecodeField: View {
    let label: String
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
        VStack(alignment: .center, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField("HH:MM:SS", text: Binding(
                get: { displayText },
                set: { newValue in
                    digits = String(newValue.filter(\.isNumber).prefix(6))
                }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .multilineTextAlignment(.center)
            .frame(width: 110)
            .disabled(disabled)
        }
    }
}

/// A text field that only accepts digits, capped at 2 (1-99) -- used for the
/// bulk-split interval count. Same all-digits, no-invalid-state approach as
/// `TimecodeField`, just without colon insertion.
private struct IntervalField: View {
    @Binding var digits: String
    var disabled: Bool = false

    var body: some View {
        TextField("30", text: Binding(
            get: { digits },
            set: { newValue in
                digits = String(newValue.filter(\.isNumber).prefix(2))
            }
        ))
        .textFieldStyle(.roundedBorder)
        .font(.system(.body, design: .monospaced))
        .multilineTextAlignment(.center)
        .frame(width: 60)
        .disabled(disabled)
    }
}
