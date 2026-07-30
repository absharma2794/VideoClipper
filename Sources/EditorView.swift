import SwiftUI
import AppKit

/// The main editing screen: shows the loaded file's duration, lets the user
/// type a start/end time, pick an output format, optionally request a
/// precise (re-encoded) cut, and export.
struct EditorView: View {
    let sourceURL: URL
    let info: VideoProbe.Info
    let tools: FFmpegLocator.Tools
    let onChooseDifferentFile: () -> Void

    /// Raw digits only (up to 6, "HHMMSS") -- TimecodeField is the only thing
    /// that writes to these, and it strips everything but digits.
    @State private var startDigits = "000000"
    @State private var endDigits: String
    @State private var format: Clipper.OutputFormat = .mkv
    @State private var precise = false

    @State private var isExporting = false
    @State private var progress: Double = 0
    @State private var exportResult: Clipper.Result?
    @State private var errorMessage: String?
    @State private var exportTask: Task<Void, Never>?

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

    /// nil means valid; otherwise the reason Export is disabled.
    private var validationMessage: String? {
        if startDigits.count < 6 { return "Start time is incomplete." }
        guard let start = parsedStart else { return "Start time isn't a valid HH:MM:SS value." }
        if endDigits.count < 6 { return "End time is incomplete." }
        guard let end = parsedEnd else { return "End time isn't a valid HH:MM:SS value." }
        if start >= end { return "End time must be after start time." }
        if end > info.durationSeconds + 0.5 { return "End time is beyond the video's duration." }
        return nil
    }

    private var canExport: Bool {
        validationMessage == nil && !isExporting
    }

    var body: some View {
        VStack(alignment: .center, spacing: 18) {
            header

            HStack(spacing: 24) {
                TimecodeField(label: "Start", digits: $startDigits, disabled: isExporting)
                TimecodeField(label: "End", digits: $endDigits, disabled: isExporting)
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

                Toggle("Precise cut (re-encodes, slower)", isOn: $precise)
            }

            if let validationMessage, !isExporting {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }

            if isExporting {
                VStack(alignment: .center, spacing: 8) {
                    ProgressView(value: progress)
                        .frame(maxWidth: 320)
                    Text(precise ? "Re-encoding… \(Int(progress * 100))%" : "Exporting… \(Int(progress * 100))%")
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

            if let exportResult {
                resultBanner(exportResult)
            }

            Spacer()

            HStack(spacing: 16) {
                Button("Choose a Different File", action: onChooseDifferentFile)
                    .disabled(isExporting)
                Button("Export") { startExport() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canExport)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 380)
        .frame(maxWidth: .infinity)
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

    private func startExport() {
        guard let start = parsedStart, let end = parsedEnd else { return }
        errorMessage = nil
        exportResult = nil
        progress = 0
        isExporting = true

        let request = Clipper.Request(sourceURL: sourceURL, start: start, end: end, format: format, precise: precise)

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
