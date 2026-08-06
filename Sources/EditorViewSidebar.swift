import SwiftUI
import AppKit

/// DESIGN VARIANT 2 of 3 -- "Sidebar Navigator". Temporary, for side-by-side
/// comparison via the picker in ContentView.swift; delete this file (and the
/// other two variants + the picker) once a design is chosen.
///
/// Settings live in categories in a left sidebar (System Settings style);
/// the detail pane shows one category's controls at a time instead of
/// everything on screen at once.
struct EditorViewSidebar: View {
    let sourceURL: URL
    let info: VideoProbe.Info
    let tools: FFmpegLocator.Tools
    let onChooseDifferentFile: () -> Void

    private enum EditMode { case single, split }
    private enum IntervalUnit { case seconds, minutes }

    private enum Category: String, CaseIterable, Identifiable {
        case range, splitting, output, quality
        var id: String { rawValue }
        var title: String {
            switch self {
            case .range: return "Range"
            case .splitting: return "Splitting"
            case .output: return "Output"
            case .quality: return "Quality"
            }
        }
        var icon: String {
            switch self {
            case .range: return "timer"
            case .splitting: return "square.stack.3d.up.fill"
            case .output: return "square.and.arrow.up"
            case .quality: return "slider.horizontal.3"
            }
        }
    }

    @State private var mode: EditMode = .single
    @State private var selectedCategory: Category = .range

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

    private var availableCategories: [Category] {
        mode == .split ? [.range, .splitting, .output, .quality] : [.range, .output, .quality]
    }

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
        NavigationSplitView {
            List(availableCategories, selection: $selectedCategory) { category in
                Label(category.title, systemImage: category.icon).tag(category)
            }
            .listStyle(.sidebar)
            .disabled(isExporting)
            .navigationSplitViewColumnWidth(150)
            .safeAreaInset(edge: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(sourceURL.lastPathComponent).font(.caption.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    Text(Timecode.format(info.durationSeconds)).font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        } detail: {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 20) {
                        modePicker

                        if isExporting {
                            progressCard
                        } else {
                            categoryContent
                            if let validationMessage {
                                InlineMessageSidebar(text: validationMessage, style: .warning)
                            }
                            if let errorMessage {
                                InlineMessageSidebar(text: errorMessage, style: .error, selectable: true)
                            }
                            if mode == .single, let exportResult {
                                resultBanner(exportResult)
                            }
                            if mode == .split, let batchResultURLs {
                                batchResultBanner(batchResultURLs)
                            }
                        }
                    }
                    .padding(22)
                }
                Divider()
                bottomBar.padding(.horizontal, 22).padding(.vertical, 14)
            }
        }
        .onChange(of: mode) { _ in
            errorMessage = nil
            exportResult = nil
            batchResultURLs = nil
            if !availableCategories.contains(selectedCategory) { selectedCategory = .range }
        }
        .frame(minWidth: 640, minHeight: 480)
    }

    private var modePicker: some View {
        Picker("Mode", selection: $mode) {
            Text("Single Clip").tag(EditMode.single)
            Text("Bulk Clip").tag(EditMode.split)
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 320)
        .disabled(isExporting)
    }

    @ViewBuilder
    private var categoryContent: some View {
        switch selectedCategory {
        case .range: rangeContent
        case .splitting: splittingContent
        case .output: outputContent
        case .quality: qualityContent
        }
    }

    private var rangeContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            categoryHeader("Range", subtitle: mode == .split ? "The portion of the video to split into clips." : "The portion of the video to export.")
            HStack(spacing: 24) {
                LabeledControlSidebar("Start") { TimecodeFieldSidebar(digits: $startDigits, disabled: isExporting) }
                LabeledControlSidebar("End") { TimecodeFieldSidebar(digits: $endDigits, disabled: isExporting) }
                LabeledControlSidebar("Total Duration") {
                    Text(Timecode.format(info.durationSeconds))
                        .font(.system(.body, design: .monospaced)).fontWeight(.medium).frame(height: 22)
                }
            }
        }
    }

    private var splittingContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            categoryHeader("Splitting", subtitle: "How the range gets divided into clips.")
            LabeledControlSidebar("Interval", alignment: .leading) {
                HStack(spacing: 8) {
                    IntervalFieldSidebar(digits: $intervalDigits, disabled: isExporting)
                    Picker("Unit", selection: $intervalUnit) {
                        Text("Seconds").tag(IntervalUnit.seconds)
                        Text("Minutes").tag(IntervalUnit.minutes)
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 150)
                }
            }
            LabeledControlSidebar("Buffer (seconds)", alignment: .leading) {
                HStack(spacing: 8) {
                    IntervalFieldSidebar(digits: $bufferDigits, disabled: isExporting)
                    Text("overlap added from clip 2 onward").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let splitPreviewText {
                Text(splitPreviewText)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.tint)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .disabled(isExporting)
    }

    private var outputContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            categoryHeader("Output", subtitle: "File format for the exported clip\(mode == .split ? "s" : "").")
            LabeledControlSidebar("Format", alignment: .leading) {
                Picker("Format", selection: $format) {
                    ForEach(Clipper.OutputFormat.allCases) { f in Text(f.displayName).tag(f) }
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 140)
            }
            if mode == .single {
                Toggle("Precise cut (re-encodes, slower)", isOn: $precise).disabled(isExporting)
            }
        }
    }

    private var qualityContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            categoryHeader("Quality", subtitle: mode == .split ? "Bulk Clip always re-encodes; these settings control size/quality." : "Only applies when Precise cut is on.")
            LabeledControlSidebar("Quality Tier", alignment: .leading) {
                Picker("Quality", selection: $qualityTier) {
                    ForEach(Clipper.QualityTier.allCases) { tier in Text(tier.displayName).tag(tier) }
                }
                .labelsHidden().pickerStyle(.segmented)
            }
            LabeledControlSidebar("Resolution", alignment: .leading) {
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
        .disabled(isExporting)
        .opacity(mode == .single && !precise ? 0.5 : 1)
    }

    private func categoryHeader(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title3.weight(.bold))
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
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
        .padding(.vertical, 40)
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

private struct LabeledControlSidebar<Content: View>: View {
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

private struct InlineMessageSidebar: View {
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

private struct TimecodeFieldSidebar: View {
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

private struct IntervalFieldSidebar: View {
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
