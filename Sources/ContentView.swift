import SwiftUI
import AppKit

/// Root view: gates on ffmpeg availability, then hands off between the
/// drop zone and the editor depending on whether a file is loaded.
struct ContentView: View {
    @StateObject private var appState = AppState()

    /// One fixed square, shared by every screen in the app -- the drop
    /// zone, the ffmpeg setup screen, and every page of the editor wizard.
    /// No screen sizes itself independently anymore.
    static let windowSize: CGFloat = 480

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
        .frame(width: Self.windowSize, height: Self.windowSize)
        .onAppear {
            if !appState.hasCheckedOnce {
                appState.recheckFFmpeg()
            }
        }
        // The window never needs to resize itself anymore -- every screen
        // renders inside the same fixed square above. That makes it safe to
        // also strip `.resizable` from the real NSWindow here, which is the
        // only way to guarantee the user can't drag the window to a
        // different size at all (a sizing *hint* like
        // `.windowResizability(.contentSize)` alone doesn't reliably disable
        // the resize handles/cursor).
        .background(WindowResizeLock())
    }
}

private struct WindowResizeLock: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { Self.lock(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { Self.lock(nsView) }
    }

    private static func lock(_ view: NSView) {
        guard let window = view.window else { return }
        window.styleMask.remove(.resizable)
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
    @State private var showMergeFlow = false

    var body: some View {
        Group {
            if isProbing {
                ProgressView("Reading video…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let sourceURL, let info {
                EditorView(sourceURL: sourceURL, info: info, tools: tools, onChooseDifferentFile: reset)
                    .transition(.opacity)
            } else if showMergeFlow {
                MergeClipsView(tools: tools, onExit: { showMergeFlow = false })
                    .transition(.opacity)
            } else {
                VStack(spacing: 12) {
                    DropZoneView(onFilePicked: load, onMergeRequested: { showMergeFlow = true })
                    if let probeError {
                        Text(probeError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 40)
                    }
                }
            }
        }
        // Loading a file swaps the drop zone for the (much taller) editor,
        // and the window's resize to match briefly lags behind the new
        // content appearing -- same one-frame overlap with the title bar as
        // the mode-switch case in EditorView. Fading the editor in masks it
        // the same way.
        .animation(.easeInOut(duration: 0.35), value: sourceURL)
        .animation(.easeInOut(duration: 0.35), value: showMergeFlow)
    }

    private func load(url: URL) {
        probeError = nil
        isProbing = true
        Task {
            do {
                let result = try await VideoProbe.probe(url: url, tools: tools)
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        self.sourceURL = url
                        self.info = result
                        self.isProbing = false
                    }
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
