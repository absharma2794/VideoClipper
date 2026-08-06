import SwiftUI

/// Root view: gates on ffmpeg availability, then hands off between the
/// drop zone and the editor depending on whether a file is loaded.
struct ContentView: View {
    @StateObject private var appState = AppState()

    var body: some View {
        Group {
            if let tools = appState.ffmpegTools {
                MainFlowView(tools: tools)
            } else if appState.hasCheckedOnce {
                FFmpegSetupView(onRecheck: appState.recheckFFmpeg)
            } else {
                ProgressView("Checking for ffmpeg…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if !appState.hasCheckedOnce {
                appState.recheckFFmpeg()
            }
        }
    }
}

/// TEMPORARY, for comparing the 3 redesign candidates side by side -- delete
/// this enum and the picker in `MainFlowView` once a design is chosen, and
/// keep only the winning EditorView* file (renamed back to EditorView.swift).
private enum DesignVariant: String, CaseIterable, Identifiable {
    case cards, sidebar, focused
    var id: String { rawValue }
    var label: String {
        switch self {
        case .cards: return "1 · Cards"
        case .sidebar: return "2 · Sidebar"
        case .focused: return "3 · Focused"
        }
    }
}

/// Everything after ffmpeg is confirmed present: pick a file, probe it,
/// then edit/export. Resets to the drop zone when a new file is chosen.
private struct MainFlowView: View {
    let tools: FFmpegLocator.Tools

    @State private var sourceURL: URL?
    @State private var info: VideoProbe.Info?
    @State private var isProbing = false
    @State private var probeError: String?
    @State private var designVariant: DesignVariant = .cards

    var body: some View {
        Group {
            if isProbing {
                ProgressView("Reading video…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let sourceURL, let info {
                VStack(spacing: 0) {
                    // TEMPORARY comparison switcher -- see DesignVariant above.
                    HStack(spacing: 10) {
                        Text("Design preview:").font(.caption).foregroundStyle(.secondary)
                        Picker("Design", selection: $designVariant) {
                            ForEach(DesignVariant.allCases) { variant in
                                Text(variant.label).tag(variant)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 280)
                        .labelsHidden()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(Color.yellow.opacity(0.15))

                    Divider()

                    switch designVariant {
                    case .cards:
                        EditorViewCards(sourceURL: sourceURL, info: info, tools: tools, onChooseDifferentFile: reset)
                    case .sidebar:
                        EditorViewSidebar(sourceURL: sourceURL, info: info, tools: tools, onChooseDifferentFile: reset)
                    case .focused:
                        EditorViewFocused(sourceURL: sourceURL, info: info, tools: tools, onChooseDifferentFile: reset)
                    }
                }
            } else {
                VStack(spacing: 12) {
                    DropZoneView(onFilePicked: load)
                    if let probeError {
                        Text(probeError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 40)
                    }
                }
                .frame(minWidth: 520, minHeight: 380)
            }
        }
    }

    private func load(url: URL) {
        probeError = nil
        isProbing = true
        Task {
            do {
                let result = try await VideoProbe.probe(url: url, tools: tools)
                await MainActor.run {
                    self.sourceURL = url
                    self.info = result
                    self.isProbing = false
                }
            } catch {
                await MainActor.run {
                    self.probeError = error.localizedDescription
                    self.isProbing = false
                }
            }
        }
    }

    private func reset() {
        sourceURL = nil
        info = nil
        probeError = nil
    }
}
