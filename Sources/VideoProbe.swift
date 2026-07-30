import Foundation

/// Reads metadata about a video file using ffprobe (preferred) or ffmpeg (fallback).
enum VideoProbe {

    struct Info {
        let durationSeconds: Double
        let hasAudio: Bool
    }

    enum ProbeError: LocalizedError {
        case processFailed(String)
        case durationNotFound

        var errorDescription: String? {
            switch self {
            case .processFailed(let detail):
                return "Could not read the video file: \(detail)"
            case .durationNotFound:
                return "Could not determine the video's duration."
            }
        }
    }

    static func probe(url: URL, tools: FFmpegLocator.Tools) async throws -> Info {
        if let ffprobePath = tools.ffprobe {
            if let info = try? await probeWithFFprobe(url: url, ffprobePath: ffprobePath) {
                return info
            }
            // Fall through to the ffmpeg-based fallback if ffprobe misbehaves on this file.
        }
        return try await probeWithFFmpeg(url: url, ffmpegPath: tools.ffmpeg)
    }

    // MARK: - ffprobe path (preferred: fast, structured output)

    private static func probeWithFFprobe(url: URL, ffprobePath: String) async throws -> Info {
        let durationOutput = try await run(
            executable: ffprobePath,
            arguments: [
                "-v", "error",
                "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1",
                url.path,
            ]
        )
        guard let duration = Double(durationOutput.trimmingCharacters(in: .whitespacesAndNewlines)),
              duration.isFinite, duration > 0 else {
            throw ProbeError.durationNotFound
        }

        let audioOutput = try await run(
            executable: ffprobePath,
            arguments: [
                "-v", "error",
                "-select_streams", "a",
                "-show_entries", "stream=index",
                "-of", "csv=p=0",
                url.path,
            ]
        )
        let hasAudio = !audioOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return Info(durationSeconds: duration, hasAudio: hasAudio)
    }

    // MARK: - ffmpeg fallback (parses stderr banner when ffprobe is unavailable)

    private static func probeWithFFmpeg(url: URL, ffmpegPath: String) async throws -> Info {
        // `ffmpeg -i <file>` with no output always "fails" (no output specified),
        // but it prints the input's format/stream info to stderr on the way out.
        let output = try? await run(
            executable: ffmpegPath,
            arguments: ["-hide_banner", "-i", url.path],
            allowNonZeroExit: true
        )
        guard let text = output else {
            throw ProbeError.processFailed("ffmpeg produced no output")
        }

        guard let duration = parseDuration(from: text) else {
            throw ProbeError.durationNotFound
        }
        let hasAudio = text.contains("Stream #") && text.contains("Audio:")
        return Info(durationSeconds: duration, hasAudio: hasAudio)
    }

    /// Parses a line like: `  Duration: 00:12:34.56, start: 0.000000, bitrate: 1234 kb/s`
    static func parseDuration(from ffmpegOutput: String) -> Double? {
        guard let range = ffmpegOutput.range(of: "Duration: ") else { return nil }
        let afterLabel = ffmpegOutput[range.upperBound...]
        guard let commaRange = afterLabel.range(of: ",") else { return nil }
        let timeString = String(afterLabel[afterLabel.startIndex..<commaRange.lowerBound])
        if timeString.contains("N/A") { return nil }
        return Timecode.parse(timeString)
    }

    // MARK: - Process execution

    @discardableResult
    private static func run(executable: String, arguments: [String], allowNonZeroExit: Bool = false) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // Read incrementally as data arrives rather than waiting for the
            // process to exit and reading once -- a pipe's kernel buffer is
            // only ~64KB, and a process producing more output than that
            // (e.g. ffprobe listing many streams/chapters) would otherwise
            // block on write() forever with nothing draining the pipe.
            let stdoutBuffer = UnboundedTextBuffer()
            let stderrBuffer = UnboundedTextBuffer()

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                stdoutBuffer.append(text)
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                stderrBuffer.append(text)
            }

            process.terminationHandler = { proc in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                let stdoutText = stdoutBuffer.contents
                let stderrText = stderrBuffer.contents

                if proc.terminationStatus != 0 && !allowNonZeroExit {
                    let detail = stderrText.isEmpty ? "exit code \(proc.terminationStatus)" : stderrText
                    continuation.resume(throwing: ProbeError.processFailed(detail))
                    return
                }
                // ffmpeg -i writes the info we want to stderr; ffprobe writes to stdout.
                continuation.resume(returning: stdoutText.isEmpty ? stderrText : stdoutText)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: ProbeError.processFailed(error.localizedDescription))
            }
        }
    }
}

/// Thread-safe, untruncated accumulator for a process's stdout/stderr,
/// filled incrementally so reading never stalls behind a full pipe buffer.
private final class UnboundedTextBuffer: @unchecked Sendable {
    private var text = ""
    private let lock = NSLock()

    func append(_ chunk: String) {
        lock.lock()
        defer { lock.unlock() }
        text += chunk
    }

    var contents: String {
        lock.lock()
        defer { lock.unlock() }
        return text
    }
}
