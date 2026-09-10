import SwiftUI
import AppKit

/// Shown when ffmpeg couldn't be located. Explains why it's needed (MKV has
/// no native macOS demuxer) and gives a one-click-copy install command.
struct FFmpegSetupView: View {
    let onRecheck: () -> Void

    private static let installCommand = "brew install ffmpeg"

    @State private var justCopied = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("ffmpeg is required")
                .font(.title2).bold()

            Text("macOS can't read .mkv files on its own — MKV Clipper uses ffmpeg to inspect and cut them. Install it once with Homebrew, then come back here.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)

            HStack {
                Text(Self.installCommand)
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.gray.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(Self.installCommand, forType: .string)
                    justCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { justCopied = false }
                } label: {
                    Label(justCopied ? "Copied" : "Copy", systemImage: justCopied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.capsule)
            }

            Text("Don't have Homebrew? Install it first from brew.sh")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Re-check", action: onRecheck)
                .buttonStyle(.capsuleProminent)
                .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
