import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// The initial screen: a drag-and-drop target for a single .mkv or .mp4 file,
/// plus conventional buttons for anyone who'd rather not drag.
struct DropZoneView: View {
    let onFilePicked: (URL) -> Void
    /// The same `QueueBubble` pill every other screen uses for this --
    /// shown below the file-picking controls when there's anything queued.
    /// `QueueBubble` itself hides when `queueCount` is 0.
    var queueCount: Int = 0
    var queueIsRunning: Bool = false
    var onQueueRequested: (() -> Void)?

    private static let supportedExtensions: Set<String> = ["mkv", "mp4"]

    @State private var isTargeted = false
    @State private var rejectionMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            // Equal `Spacer`s above and below a naturally-sized content
            // block -- the same reliable centering technique every other
            // page in the app uses, rather than the manual `.offset(y:)`
            // this used to have, which only looked centered by coincidence
            // for whatever content happened to be below it at the time.
            Spacer(minLength: 0)
            VStack(spacing: 16) {
                Image(systemName: "film")
                    .font(.system(size: 44))
                    .foregroundStyle(isTargeted ? Color.accentColor : .secondary)

                Text("Drop an .mkv file here")
                    .font(.title3).bold()

                Text("or")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Choose File…", action: presentOpenPanel)
                    .buttonStyle(.capsule)

                Button("I know you have a .mp4 file", action: presentOpenPanel)
                    .buttonStyle(.link)
            }
            Spacer(minLength: 0)

            if queueCount > 0, let onQueueRequested {
                QueueBubble(count: queueCount, isRunning: queueIsRunning, onTap: onQueueRequested)
                    .padding(.bottom, 8)
            }

            if let rejectionMessage {
                Text(rejectionMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.gray.opacity(0.4))
                .padding(20)
        )
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    private func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        // UTType for Matroska isn't reliably registered system-wide, so filter
        // by extension rather than a UTType the panel might not recognize.
        panel.allowedContentTypes = []
        if panel.runModal() == .OK, let url = panel.url {
            accept(url: url)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            rejectionMessage = "That didn't look like a file."
            return false
        }
        _ = provider.loadObject(ofClass: URL.self) { url, error in
            DispatchQueue.main.async {
                guard let url, error == nil else {
                    self.rejectionMessage = "Couldn't read that item."
                    return
                }
                self.accept(url: url)
            }
        }
        return true
    }

    private func accept(url: URL) {
        guard Self.supportedExtensions.contains(url.pathExtension.lowercased()) else {
            rejectionMessage = "\"\(url.lastPathComponent)\" isn't an .mkv or .mp4 file."
            return
        }
        rejectionMessage = nil
        onFilePicked(url)
    }
}
