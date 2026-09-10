import Foundation

/// Decodes a single frame from a video at a given timestamp -- the engine
/// behind the Range Settings page's Start/End preview thumbnails (T2.4,
/// flagged in TASKS-lossless.md as the highest-leverage item in the whole
/// plan: previously nothing in the app showed what a chosen range actually
/// contained until after export).
enum FrameThumbnailer {
    enum ThumbnailError: Error { case decodeFailed }

    /// Grabs one frame at `timestamp` as PNG data via ffmpeg's own decoder
    /// -- no AVFoundation needed, and it works uniformly for both MKV and
    /// MP4 sources the same way the rest of the app already shells out to
    /// ffmpeg for everything else. `-ss` before `-i` uses ffmpeg's fast,
    /// keyframe-adjacent seek rather than a frame-accurate one -- exactly
    /// what a live preview needs while someone is still typing a timecode;
    /// it doesn't need to land on the exact frame, just stay fast.
    static func frame(from url: URL, atSeconds timestamp: Double, ffmpegPath: String) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpegPath)
            process.arguments = [
                "-hide_banner", "-v", "error",
                "-ss", String(max(timestamp, 0)),
                "-i", url.path,
                "-frames:v", "1",
                "-f", "image2pipe",
                "-c:v", "png",
                "-",
            ]
            let stdoutPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = Pipe()

            // Same incremental-read pattern used everywhere else this app
            // captures a process's stdout: a PNG frame is small (tens of
            // KB), well under a pipe's kernel buffer, but reading only on
            // termination has bitten this codebase before on larger output.
            let buffer = ThumbnailBuffer()
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                buffer.append(data)
            }
            process.terminationHandler = { proc in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                let data = buffer.contents
                if proc.terminationStatus == 0, !data.isEmpty {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: ThumbnailError.decodeFailed)
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

private final class ThumbnailBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
    }

    var contents: Data {
        lock.lock(); defer { lock.unlock() }
        return data
    }
}
