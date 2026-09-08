import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// A paged wizard for merging many whole video files into one, with a
/// chapter marker embedded at each source's boundary. Separate from
/// `EditorView`'s Single Clip/Bulk Clip flow (which structurally assumes one
/// file is loaded before mode selection) but matches its visual language:
/// same dark theme, same `Spacer`-centered content, same completed/stopped
/// page patterns, and lives inside the same fixed square window.
struct MergeClipsView: View {
    let tools: FFmpegLocator.Tools
    let onExit: () -> Void
    let onQueueRequested: () -> Void

    @ObservedObject private var queue = ExportQueue.shared

    /// Every mutually-exclusive stage of the flow, in one place -- previously
    /// six independent flags (`page`, `isProbing`, `compatibilityIssues`,
    /// `isMerging`, `mergeResult`, `errorMessage`) could in principle be set
    /// in combinations that don't correspond to any real screen; a single
    /// enum makes the invalid combinations unrepresentable.
    private enum FlowState {
        case selectingFiles
        case outputSettings
        case probing(completed: Int, total: Int)
        case incompatible([ClipMerger.CompatibilityIssue])
        case merging(progress: Double)
        case completed(Clipper.Result)
        case failed(String)

        /// An associated-value-free discriminator for `.id()` and
        /// `.animation(value:)`, which need `Equatable` -- `FlowState`
        /// itself can't be, since `Clipper.Result` isn't.
        enum Stage: Equatable { case selectingFiles, outputSettings, probing, incompatible, merging, completed, failed }

        var stage: Stage {
            switch self {
            case .selectingFiles: return .selectingFiles
            case .outputSettings: return .outputSettings
            case .probing: return .probing
            case .incompatible: return .incompatible
            case .merging: return .merging
            case .completed: return .completed
            case .failed: return .failed
            }
        }
    }

    private struct ClipEntry: Identifiable, Equatable {
        let id = UUID()
        var url: URL
        var chapterTitle: String
    }

    private static let supportedExtensions: Set<String> = ["mkv", "mp4"]

    @State private var flow: FlowState = .selectingFiles
    @State private var navigatingForward = true
    @State private var entries: [ClipEntry] = []

    @State private var format: Clipper.OutputFormat = .mp4
    @State private var outputName = ""

    @State private var probedInfo: [URL: VideoProbe.Info] = [:]
    @State private var mergeTask: Task<Void, Never>?

    private var totalDurationSeconds: Double {
        entries.reduce(0) { $0 + (probedInfo[$1.url]?.durationSeconds ?? 0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            switch flow {
            case .merging(let progress):
                mergingPage(progress: progress)
            case .completed(let result):
                completedPage(result: result)
            case .failed(let message):
                failedPage(message: message)
            case .probing(let completed, let total):
                probingPage(completed: completed, total: total)
            case .incompatible(let issues):
                incompatiblePage(issues: issues)
            case .selectingFiles, .outputSettings:
                Group {
                    switch flow {
                    case .selectingFiles: selectFilesPage
                    case .outputSettings: outputSettingsPage
                    default: EmptyView()
                    }
                }
                .id(flow.stage)
                .transition(wizardPageTransition(navigatingForward: navigatingForward))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: flow.stage)
    }

    // MARK: - Page 1: Select files

    private var selectFilesPage: some View {
        VStack(spacing: 14) {
            Text("Select Files to Merge").font(.headline)

            Text("Files are ordered by any number in their name — rename them first (e.g. \"[1] ...\", \"[2] ...\") if they aren't already sequential, or drag rows below to reorder manually.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)

            if entries.isEmpty {
                emptyDropZone
            } else {
                fileList
            }

            HStack(spacing: 10) {
                Button("Add Files…") { presentOpenPanel() }
                    .buttonStyle(.bordered)
                if !entries.isEmpty {
                    Text("\(entries.count) file\(entries.count == 1 ? "" : "s") selected")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            HStack {
                Button(action: onExit) {
                    Text("Cancel").underline()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                QueueBubble(count: queue.jobs.count, isRunning: queue.isRunning, onTap: onQueueRequested)
                Button("Next →") { startCompatibilityCheck() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(entries.count < 2)
            }
        }
        .padding(20)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in handleDrop(providers: providers) }
    }

    private var emptyDropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Drop files here or use \"Add Files…\" below")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 220)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                .foregroundStyle(.gray.opacity(0.3))
        )
    }

    private var fileList: some View {
        List {
            ForEach($entries) { $entry in
                HStack(spacing: 8) {
                    Text("\(indexLabel(for: entry))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 26, alignment: .trailing)
                    TextField("Chapter title", text: $entry.chapterTitle)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                    Button {
                        entries.removeAll { $0.id == entry.id }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .onMove { indices, newOffset in entries.move(fromOffsets: indices, toOffset: newOffset) }
        }
        .listStyle(.plain)
        .frame(height: 220)
        .background(Color.gray.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func indexLabel(for entry: ClipEntry) -> Int {
        (entries.firstIndex(of: entry) ?? 0) + 1
    }

    private func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = []
        if panel.runModal() == .OK { addFiles(panel.urls) }
    }

    /// Each provider's URL resolves asynchronously and independently, so
    /// calling `addFiles` once per file as each one lands would only ever
    /// natural-sort a 1-element list (a no-op) and append in whatever order
    /// the async completions happen to fire in -- not filename order, which
    /// is exactly what the on-screen caption above promises. Waiting for
    /// every provider to resolve and calling `addFiles` once, with the full
    /// dropped batch, is what actually lets naturalSort do its job.
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }

        let collected = DroppedURLCollector()
        let group = DispatchGroup()
        for provider in fileProviders {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { collected.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) { addFiles(collected.urls) }
        return true
    }

    private func addFiles(_ newURLs: [URL]) {
        let existing = Set(entries.map(\.url))
        let accepted = newURLs.filter {
            Self.supportedExtensions.contains($0.pathExtension.lowercased()) && !existing.contains($0)
        }
        let sorted = naturalSort(accepted)
        entries.append(contentsOf: sorted.map {
            ClipEntry(url: $0, chapterTitle: $0.deletingPathExtension().lastPathComponent)
        })
    }

    private func naturalSort(_ urls: [URL]) -> [URL] {
        urls.sorted {
            $0.lastPathComponent.compare($1.lastPathComponent, options: [.numeric, .caseInsensitive]) == .orderedAscending
        }
    }

    // MARK: - Compatibility check

    private func startCompatibilityCheck() {
        flow = .probing(completed: 0, total: entries.count)
        let urls = entries.map(\.url)
        Task {
            do {
                let infoByURL = try await ClipMerger.probeAll(urls: urls, tools: tools) { completed, total in
                    Task { @MainActor in flow = .probing(completed: completed, total: total) }
                }
                let issues = ClipMerger.checkCompatibility(urls: urls, infoByURL: infoByURL)
                await MainActor.run {
                    self.probedInfo = infoByURL
                    if issues.isEmpty {
                        self.outputName = ClipMerger.defaultOutputName(for: urls)
                        self.navigatingForward = true
                        self.flow = .outputSettings
                    } else {
                        self.flow = .incompatible(issues)
                    }
                }
            } catch {
                await MainActor.run {
                    self.flow = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func probingPage(completed: Int, total: Int) -> some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Checking \(completed) of \(total)…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func incompatiblePage(issues: [ClipMerger.CompatibilityIssue]) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text("These files don't match").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(groupedIssueSummaries(issues), id: \.self) { summary in
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 4)
            }
            .frame(height: 220)
            Button("Go Back") { flow = .selectingFiles }
                .buttonStyle(.borderedProminent)
        }
        .padding(20)
    }

    private func groupedIssueSummaries(_ issues: [ClipMerger.CompatibilityIssue]) -> [String] {
        Dictionary(grouping: issues, by: \.property)
            .sorted { $0.key < $1.key }
            .map { property, issues in
                let names = issues.map { "\($0.fileName) (\($0.value))" }
                let expected = issues.first?.expected ?? ""
                return "\(property) — expected \(expected):\n" + names.joined(separator: "\n")
            }
    }

    // MARK: - Page 2: Output settings

    private var outputSettingsPage: some View {
        VStack(spacing: 24) {
            Text("Output Settings").font(.headline)
            Spacer(minLength: 0)
            VStack(spacing: 20) {
                LabeledWizardControl("Output Name") {
                    TextField("Merged Video", text: $outputName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                }
                LabeledWizardControl("Format") {
                    Picker("Format", selection: $format) {
                        ForEach(Clipper.OutputFormat.allCases) { f in Text(f.displayName).tag(f) }
                    }
                    .labelsHidden().pickerStyle(.segmented).controlSize(.large).frame(width: 140)
                }
                if format == .mkv {
                    Text("MKV chapters work in VLC (macOS & Android) but not in QuickTime Player.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)
                }
                Text("\(entries.count) clips · \(Timecode.format(totalDurationSeconds)) total")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack {
                Button("← Back") {
                    navigatingForward = false
                    flow = .selectingFiles
                }
                .buttonStyle(.bordered)
                Spacer()
                QueueBubble(count: queue.jobs.count, isRunning: queue.isRunning, onTap: onQueueRequested)
                Button("Merge") { startMerge() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .padding(20)
    }

    // MARK: - Merge

    private func startMerge() {
        flow = .merging(progress: 0)

        let chapterEntries = entries.map { entry -> ClipMerger.ChapterSource in
            let info = probedInfo[entry.url]
            // The video stream's own duration is what actually matters for
            // chapter boundaries (chapters mark positions on the video
            // timeline) -- container-level duration can understate it on a
            // file whose audio track runs shorter than its video, which is
            // exactly the defect `checkCompatibility` now catches and blocks
            // before this point, but falling back defensively here too.
            let duration = info?.videoStreamDurationSeconds ?? info?.durationSeconds ?? 0
            return ClipMerger.ChapterSource(url: entry.url, title: entry.chapterTitle, durationSeconds: duration)
        }
        let mergeFormat = format
        let mergeOutputName = outputName

        mergeTask = Task {
            do {
                let result = try await ClipMerger.merge(
                    entries: chapterEntries, format: mergeFormat, outputName: mergeOutputName, tools: tools
                ) { fraction in
                    Task { @MainActor in flow = .merging(progress: fraction) }
                }
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        self.flow = .completed(result)
                    }
                }
            } catch {
                await MainActor.run {
                    self.flow = .failed(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Page: Progress

    private func mergingPage(progress: Double) -> some View {
        WizardProgressPage(
            counter: {
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 46, weight: .thin, design: .rounded))
                    .monospacedDigit()
            },
            statusText: "Merging \(entries.count) clips…",
            progress: progress,
            onForceStop: { mergeTask?.cancel() }
        )
    }

    // MARK: - Page: Completed

    private func completedPage(result: Clipper.Result) -> some View {
        WizardCompletedPage(
            message: "Saved to \(result.outputURL.lastPathComponent)",
            onReveal: { NSWorkspace.shared.activateFileViewerSelecting([result.outputURL]) },
            onDone: onExit
        )
    }

    // MARK: - Page: Failed

    private func failedPage(message: String) -> some View {
        WizardStoppedPage(message: message) {
            navigatingForward = false
            flow = .selectingFiles
        }
    }
}

/// Thread-safe accumulator for URLs resolved from concurrent
/// `NSItemProvider.loadObject` completions, which can fire on arbitrary
/// background queues.
private final class DroppedURLCollector: @unchecked Sendable {
    private var collected: [URL] = []
    private let lock = NSLock()

    func append(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        collected.append(url)
    }

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }
}
