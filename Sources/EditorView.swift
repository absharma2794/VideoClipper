import SwiftUI
import AppKit

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

    private enum EditMode { case single, split }
    private enum IntervalUnit { case seconds, minutes }
    private enum Page { case modeSelect, rangeSettings, advancedSettings }

    @State private var page: Page = .modeSelect
    @State private var navigatingForward = true

    @State private var mode: EditMode = .single

    @State private var startDigits = "000000"
    @State private var endDigits: String
    @State private var format: Clipper.OutputFormat = .mkv
    @State private var precise = true
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

    private var pageTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: navigatingForward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: navigatingForward ? .leading : .trailing).combined(with: .opacity)
        )
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
                .transition(pageTransition)
            }
        }
        .frame(width: 480, height: 480)
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
                Button("Next →") { goNext() }
                    .buttonStyle(.borderedProminent)
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
                        LabeledControlFocused("Start", labelFont: .subheadline) { TimecodeFieldFocused(digits: $startDigits) }
                        LabeledControlFocused("End", labelFont: .subheadline) { TimecodeFieldFocused(digits: $endDigits) }
                    }
                    Text("of \(Timecode.format(info.durationSeconds)) total")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
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
                Button("← Back") { goBack() }.buttonStyle(.bordered)
                Spacer()
                Button("Next →") { goNext() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(validationMessage != nil)
            }
        }
        .padding(28)
    }

    // MARK: - Page 4: Advanced settings + Export

    private var advancedSettingsPage: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Advanced Settings").font(.headline)
                Spacer()
                Button("Reset") { resetAdvancedSettings() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
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
                    LabeledControlFocused("Buffer (seconds)", labelFont: .system(size: 13)) {
                        HStack(spacing: 6) {
                            IntervalFieldFocused(digits: $bufferDigits)
                            Text("sec").font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                    }
                    noteRow("Overlaps each clip with the end of the one before it, so nothing gets cut off mid-moment. Clip 1 is unaffected.")
                }

                LabeledControlFocused("Format", labelFont: .system(size: 13)) {
                    Picker("Format", selection: $format) {
                        ForEach(Clipper.OutputFormat.allCases) { f in Text(f.displayName).tag(f) }
                    }
                    .labelsHidden().pickerStyle(.segmented).controlSize(.large).frame(width: 155)
                }

                if mode == .split {
                    noteRow("Bulk clips are always precisely cut, so every clip starts exactly on time.")
                }

                LabeledControlFocused("Quality", labelFont: .system(size: 13)) {
                    Picker("Quality", selection: $qualityTier) {
                        ForEach(Clipper.QualityTier.allCases) { tier in Text(tier.displayName).tag(tier) }
                    }
                    .labelsHidden().pickerStyle(.segmented).controlSize(.large).frame(width: 330)
                }
                LabeledControlFocused("Resolution", labelFont: .system(size: 13)) {
                    HStack(spacing: 8) {
                        Picker("Resolution", selection: $resolution) {
                            ForEach(availableResolutions) { option in Text(option.displayName).tag(option) }
                        }
                        .labelsHidden().controlSize(.large).frame(width: 145)
                        Text("(\(info.width)×\(info.height) native)").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)

            HStack {
                Button("← Back") { goBack() }.buttonStyle(.bordered)
                Spacer()
                Button(exportButtonLabel) { startExport() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canExport)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
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
                .tint(.red)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Page 6/7: Completed

    private var completedPage: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text(completedText)
                .font(.headline)
                .foregroundStyle(.green)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if mode == .single, exportResult?.usedAudioReencodeFallback == true {
                Text("Note: the audio track was re-encoded to AAC because it couldn't be copied directly into an MP4 container.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            HStack(spacing: 10) {
                Button("Reveal in Finder") { revealCompletedResult() }
                    .buttonStyle(.bordered)
                Button("Done") { dismissCompleted() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 6)
            Button(action: onChooseDifferentFile) {
                Text("Choose a Different File").underline()
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private func dismissCompleted() {
        exportResult = nil
        batchResultURLs = nil
        navigatingForward = false
        page = .modeSelect
    }

    // MARK: - Page 8: Stopped mid-way

    private var stoppedPage: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text(errorMessage ?? "Export stopped.")
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button("Go Back") {
                errorMessage = nil
                navigatingForward = false
                page = .rangeSettings
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            precise: precise, qualityTier: qualityTier, resolution: resolution
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

private struct LabeledControlFocused<Content: View>: View {
    let label: String
    let labelFont: Font
    @ViewBuilder let content: Content

    init(_ label: String, labelFont: Font = .caption, @ViewBuilder content: () -> Content) {
        self.label = label
        self.labelFont = labelFont
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(label).font(labelFont).foregroundStyle(.secondary)
            content
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
