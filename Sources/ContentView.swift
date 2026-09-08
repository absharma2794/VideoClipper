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

    @ObservedObject private var queue = ExportQueue.shared

    @State private var sourceURL: URL?
    @State private var info: VideoProbe.Info?
    @State private var isProbing = false
    @State private var probeError: String?
    @State private var showQueue = false
    /// Set only by `reopen(from:)`, consumed once by the `EditorView` that
    /// `editorSessionID` forces fresh whenever this changes -- see that
    /// property's own comment for why nil-ing this out separately isn't
    /// needed the way it might look at first.
    @State private var pendingPrefill: EditorPrefill?
    /// Forces a brand-new `EditorView` identity (and so a fresh `@State`,
    /// correctly re-seeded from `prefill`) exactly when `load(url:)` or
    /// `reopen(from:)` actually starts a new editing session -- bumped
    /// alongside `sourceURL`/`pendingPrefill` in both. Without this,
    /// `.id(sourceURL)` alone would fail to refresh state for "reopen this
    /// same already-loaded file with different settings", and relying on
    /// `EditorView` being torn down by leaving/re-entering its branch (the
    /// previous approach) is exactly what let a mere trip to the Export
    /// Queue silently discard whatever the user had typed -- fixed below by
    /// keeping every branch mounted in a `ZStack` instead of an if/else-if
    /// chain, so this ID is now the ONLY thing that resets `EditorView`.
    @State private var editorSessionID = UUID()

    var body: some View {
        ZStack {
            Group {
                if isProbing {
                    ProgressView("Reading video…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let sourceURL, let info {
                    EditorView(
                        sourceURL: sourceURL, info: info, tools: tools, onChooseDifferentFile: reset,
                        onQueueRequested: { showQueue = true }, prefill: pendingPrefill
                    )
                    .id(editorSessionID)
                    .transition(.opacity)
                } else {
                    VStack(spacing: 12) {
                        DropZoneView(
                            onFilePicked: load,
                            queueCount: queue.jobs.count, queueIsRunning: queue.isRunning,
                            onQueueRequested: { showQueue = true }
                        )
                        if let probeError {
                            Text(probeError)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .padding(.horizontal, 40)
                        }
                    }
                }
            }
            // A ZStack layer, not a branch of the Group above: the Export
            // Queue used to be a sibling `if` in that same if/else-if chain,
            // which meant opening it tore down whichever wizard was
            // underneath (discarding all its in-progress state) and
            // rebuilt a fresh one on return. Layering it on top instead
            // keeps EditorView alive and untouched the whole time --
            // ExportQueueView now needs its own opaque background for this
            // to look right (see its own comment).
            if showQueue {
                ExportQueueView(onClose: { showQueue = false }, onExportAnotherVersion: reopen(from:))
                    .transition(.opacity)
            }
        }
        // Loading a file swaps the drop zone for the (much taller) editor,
        // and the window's resize to match briefly lags behind the new
        // content appearing -- same one-frame overlap with the title bar as
        // the mode-switch case in EditorView. Fading the editor in masks it
        // the same way.
        .animation(.easeInOut(duration: 0.35), value: sourceURL)
        .animation(.easeInOut(duration: 0.35), value: showQueue)
        .animation(.easeInOut(duration: 0.35), value: editorSessionID)
    }

    private func load(url: URL) {
        probeError = nil
        isProbing = true
        pendingPrefill = nil
        Task {
            do {
                let result = try await VideoProbe.probe(url: url, tools: tools)
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        self.sourceURL = url
                        self.info = result
                        self.isProbing = false
                        self.editorSessionID = UUID()
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
        pendingPrefill = nil
    }

    /// Reopens `EditorView` on a queued job's file with its settings
    /// pre-filled, whether or not that file is the one currently loaded --
    /// no re-probe needed, since `VideoProbe.Info` was already captured once
    /// when the job was enqueued.
    private func reopen(from job: ExportJob) {
        showQueue = false
        sourceURL = job.request.sourceURL
        info = job.request.sourceInfo
        pendingPrefill = EditorPrefill(job: job)
        editorSessionID = UUID()
    }
}
