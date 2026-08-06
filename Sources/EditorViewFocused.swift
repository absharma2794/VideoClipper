import SwiftUI
import AppKit

/// DESIGN VARIANT 3 of 3 -- "Focused Flow". Temporary, for side-by-side
/// comparison via the picker in ContentView.swift; delete this file (and the
/// other two variants + the picker) once a design is chosen.
///
/// No card chrome -- just generous space and strong type. Only Range and
/// Interval are visible by default; Buffer, Quality, and Resolution live
/// behind one "Advanced" disclosure. Bet: most exports don't touch those.
struct EditorViewFocused: View {
    let sourceURL: URL
    let info: VideoProbe.Info
    let tools: FFmpegLocator.Tools
    let onChooseDifferentFile: () -> Void

    private enum EditMode { case single, split }
    private enum IntervalUnit { case seconds, minutes }

    @State private var mode: EditMode = .single
    @State private var showAdvanced = false

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

    private var canExport: Bool { validationMessage == nil && !isExporting }

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

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if isExporting {
                    progressView
                        .padding(.top, 60)
                } else {
                    VStack(spacing: 30) {
                        fileHeader
                        modePicker

                        VStack(spacing: 10) {
                            HStack(spacing: 36) {
                                LabeledControlFocused("Start") { TimecodeFieldFocused(digits: $startDigits, disabled: isExporting) }
                                LabeledControlFocused("End") { TimecodeFieldFocused(digits: $endDigits, disabled: isExporting) }
                            }
                            Text("of \(Timecode.format(info.durationSeconds)) total")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if mode == .split {
                            VStack(spacing: 10) {
                                Text("SPLIT EVERY").font(.caption.weight(.semibold)).foregroundStyle(.secondary).tracking(0.6)
                                HStack(spacing: 10) {
                                    IntervalFieldFocused(digits: $intervalDigits, disabled: isExporting, large: true)
                                    Picker("Unit", selection: $intervalUnit) {
                                        Text("Sec").tag(IntervalUnit.seconds)
                                        Text("Min").tag(IntervalUnit.minutes)
                                    }
                                    .labelsHidden().pickerStyle(.segmented).frame(width: 130)
                                }
                                if let splitPreviewText {
                                    Text("→ \(splitPreviewText)")
                                        .font(.callout.weight(.semibold))
                                        .foregroundStyle(.tint)
                                }
                            }
                            .disabled(isExporting)
                        } else {
                            Toggle("Precise cut (re-encodes, slower)", isOn: $precise)
                                .disabled(isExporting)
                        }

                        DisclosureGroup(isExpanded: $showAdvanced) {
                            advancedContent
                                .padding(.top, 16)
                        } label: {
                            Text("Advanced").font(.callout).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: 360)
                        .disabled(isExporting)

                        if let validationMessage {
                            Text(validationMessage)
                                .font(.callout)
                                .foregroundStyle(.orange)
                                .multilineTextAlignment(.center)
                        }
                        if let errorMessage {
                            Text(errorMessage)
                                .font(.callout)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 420)
                        }
                        if mode == .single, let exportResult {
                            resultBanner(exportResult)
                        }
                        if mode == .split, let batchResultURLs {
                            batchResultBanner(batchResultURLs)
                        }

                        VStack(spacing: 10) {
                            Button(exportButtonLabel) { startExport() }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                                .disabled(!canExport)
                                .keyboardShortcut(.defaultAction)
                            Button("Choose a Different File", action: onChooseDifferentFile)
                                .buttonStyle(.plain)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .disabled(isExporting)
                        }
                    }
                    .padding(.top, 44)
                    .padding(.bottom, 40)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 520, minHeight: 480)
    }

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

    private var modePicker: some View {
        Picker("Mode", selection: $mode) {
            Text("Single Clip").tag(EditMode.single)
            Text("Bulk Clip").tag(EditMode.split)
        }
        .pickerStyle(.segmented)
        .frame(width: 280)
        .disabled(isExporting)
        .onChange(of: mode) { _ in
            errorMessage = nil
            exportResult = nil
            batchResultURLs = nil
        }
    }

    private var advancedContent: some View {
        VStack(spacing: 18) {
            if mode == .split {
                LabeledControlFocused("Buffer (seconds)") {
                    HStack(spacing: 6) {
                        IntervalFieldFocused(digits: $bufferDigits, disabled: isExporting)
                        Text("sec").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            LabeledControlFocused("Format") {
                Picker("Format", selection: $format) {
                    ForEach(Clipper.OutputFormat.allCases) { f in Text(f.displayName).tag(f) }
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 140)
            }
            if mode == .split || precise {
                LabeledControlFocused("Quality") {
                    Picker("Quality", selection: $qualityTier) {
                        ForEach(Clipper.QualityTier.allCases) { tier in Text(tier.displayName).tag(tier) }
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 300)
                }
                LabeledControlFocused("Resolution") {
                    HStack(spacing: 8) {
                        Picker("Resolution", selection: $resolution) {
                            ForEach(availableResolutions) { option in Text(option.displayName).tag(option) }
                        }
                        .labelsHidden().frame(width: 130)
                        Text("(\(info.width)×\(info.height) native)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var progressView: some View {
        VStack(spacing: 6) {
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

            Text(mode == .split ? "Re-encoding this clip… \(Int(progress * 100))%" : (precise ? "Re-encoding…" : "Exporting…"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 18)

            ProgressView(value: overallProgress)
                .frame(maxWidth: 260)
                .padding(.bottom, 20)

            Button("Force Stop", role: .destructive) { exportTask?.cancel() }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
    }

    private func resultBanner(_ result: Clipper.Result) -> some View {
        VStack(spacing: 8) {
            Label("Saved to \(result.outputURL.lastPathComponent)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            if result.usedAudioReencodeFallback {
                Text("Note: the audio track was re-encoded to AAC because it couldn't be copied directly into an MP4 container.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([result.outputURL])
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: 420)
    }

    private func batchResultBanner(_ urls: [URL]) -> some View {
        let sessionFolder = urls.first?.deletingLastPathComponent()
        let folderName = sessionFolder?.lastPathComponent
        return VStack(spacing: 8) {
            Label(
                "\(urls.count) clip\(urls.count == 1 ? "" : "s") saved" + (folderName.map { " to \"\($0)\"" } ?? ""),
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
            .font(.callout)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            Button("Reveal in Finder") {
                if let sessionFolder {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: sessionFolder.path)
                }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: 420)
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

private struct LabeledControlFocused<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            content
        }
    }
}

private struct TimecodeFieldFocused: View {
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

private struct IntervalFieldFocused: View {
    @Binding var digits: String
    var disabled: Bool = false
    var large: Bool = false

    var body: some View {
        TextField("0", text: Binding(
            get: { digits },
            set: { newValue in digits = String(newValue.filter(\.isNumber).prefix(2)) }
        ))
        .textFieldStyle(.roundedBorder)
        .font(.system(large ? .title3 : .body, design: .monospaced))
        .multilineTextAlignment(.center)
        .frame(width: large ? 64 : 60)
        .disabled(disabled)
    }
}
