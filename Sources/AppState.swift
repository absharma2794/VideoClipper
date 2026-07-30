import Foundation
import SwiftUI

/// Top-level app state: whether ffmpeg/ffprobe are available.
/// Everything file/export related lives in `EditorFlowState`, scoped to the
/// main flow view so it resets cleanly if the user picks a new file.
@MainActor
final class AppState: ObservableObject {
    @Published private(set) var ffmpegTools: FFmpegLocator.Tools?
    @Published private(set) var hasCheckedOnce = false

    func recheckFFmpeg() {
        ffmpegTools = FFmpegLocator.locate()
        hasCheckedOnce = true
    }
}
