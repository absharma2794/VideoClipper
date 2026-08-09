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

    private enum Page { case selectFiles, outputSettings }

    private struct ClipEntry: Identifiable, Equatable {
        let id = UUID()
        var url: URL
        var chapterTitle: String
    }

    private static let supportedExtensions: Set<String> = ["mkv", "mp4"]

    @State private var page: Page = .selectFiles
    @State private var navigatingForward = true
    @State private var entries: [ClipEntry] = []

    @State private var format: Clipper.OutputFormat = .mp4
    @State private var outputName = ""

    @State private var isProbing = false
    @State private var checkProgress: (completed: Int, total: Int) = (0, 0)
    @State private var probedInfo: [URL: VideoProbe.Info] = [:]
    @State private var compatibilityIssues: [ClipMerger.CompatibilityIssue] = []

    @State private var isMerging = false
    @State private var mergeProgress: Double = 0
    @State private var mergeTask: Task<Void, Never>?
    @State private var mergeResult: Clipper.Result?
    @State private var errorMessage: String?

    private var totalDurationSeconds: Double {
        entries.reduce(0) { $0 + (probedInfo[$1.url]?.durationSeconds ?? 0) }
    }

    private var pageTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: navigatingForward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: navigatingForward ? .leading : .trailing).combined(with: .opacity)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if isMerging {
                progressPage
            } else if mergeResult != nil {
                completedPage
            } else if let errorMessage {
                stoppedPage(errorMessage)
            } else if isProbing {
                probingPage
            } else if !compatibilityIssues.isEmpty {
                incompatiblePage
            } else {
                Group {
                    switch page {
                    case .selectFiles: selectFilesPage
                    case .outputSettings: outputSettingsPage
                    }
                }
                .id(page)
                .transition(pageTransition)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: page)
        .animation(.easeInOut(duration: 0.3), value: isMerging)
        .animation(.easeInOut(duration: 0.3), value: mergeResult == nil)
        .animation(.easeInOut(duration: 0.3), value: errorMessage != nil)
        .animation(.easeInOut(duration: 0.3), value: isProbing)
        .animation(.easeInOut(duration: 0.3), value: compatibilityIssues.isEmpty)
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

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { addFiles([url]) }
            }
        }
        return accepted
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
        isProbing = true
        checkProgress = (0, entries.count)
        let urls = entries.map(\.url)
        Task {
            do {
                let infoByURL = try await ClipMerger.probeAll(urls: urls, tools: tools) { completed, total in
                    Task { @MainActor in checkProgress = (completed, total) }
                }
                let issues = ClipMerger.checkCompatibility(urls: urls, infoByURL: infoByURL)
                await MainActor.run {
                    self.probedInfo = infoByURL
                    self.isProbing = false
                    if issues.isEmpty {
                        self.outputName = ClipMerger.defaultOutputName(for: urls)
                        self.navigatingForward = true
                        self.page = .outputSettings
                    } else {
                        self.compatibilityIssues = issues
                    }
                }
            } catch {
                await MainActor.run {
                    self.isProbing = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private var probingPage: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Checking \(checkProgress.completed) of \(checkProgress.total)…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var incompatiblePage: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text("These files don't match").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(groupedIssueSummaries, id: \.self) { summary in
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 4)
            }
            .frame(height: 220)
            Button("Go Back") { compatibilityIssues = [] }
                .buttonStyle(.borderedProminent)
        }
        .padding(20)
    }

    private var groupedIssueSummaries: [String] {
        Dictionary(grouping: compatibilityIssues, by: \.property)
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
                LabeledMergeControl("Output Name") {
                    TextField("Merged Video", text: $outputName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                }
                LabeledMergeControl("Format") {
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
                    page = .selectFiles
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("Merge") { startMerge() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .padding(20)
    }

    // MARK: - Merge

    private func startMerge() {
        errorMessage = nil
        mergeResult = nil
        mergeProgress = 0
        isMerging = true

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
                    Task { @MainActor in mergeProgress = fraction }
                }
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        self.mergeResult = result
                        self.isMerging = false
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isMerging = false
                }
            }
        }
    }

    // MARK: - Page: Progress

    private var progressPage: some View {
        VStack(spacing: 6) {
            Text("\(Int(mergeProgress * 100))%")
                .font(.system(size: 46, weight: .thin, design: .rounded))
                .monospacedDigit()
            Text("Merging \(entries.count) clips…")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 18)
            ProgressView(value: mergeProgress)
                .frame(maxWidth: 260)
                .padding(.bottom, 20)
            Button("Force Stop", role: .destructive) { mergeTask?.cancel() }
                .buttonStyle(.bordered)
                .tint(.red)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Page: Completed

    private var completedPage: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text("Saved to \(mergeResult?.outputURL.lastPathComponent ?? "")")
                .font(.headline)
                .foregroundStyle(.green)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            HStack(spacing: 10) {
                Button("Reveal in Finder") {
                    if let url = mergeResult?.outputURL {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                .buttonStyle(.bordered)
                Button("Done", action: onExit)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Page: Stopped

    private func stoppedPage(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button("Go Back") {
                errorMessage = nil
                navigatingForward = false
                page = .selectFiles
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LabeledMergeControl<Content: View>: View {
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
