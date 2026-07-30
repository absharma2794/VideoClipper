import Foundation

/// Drives ffmpeg to cut `[start, end)` out of a source video and write the
/// result to ~/Downloads.
enum Clipper {

    enum OutputFormat: String, CaseIterable, Identifiable {
        case mkv = "mkv"
        case mp4 = "mp4"
        var id: String { rawValue }
        var displayName: String { rawValue.uppercased() }
    }

    struct Request {
        let sourceURL: URL
        let start: Double
        let end: Double
        let format: OutputFormat
        let precise: Bool
    }

    struct Result {
        let outputURL: URL
        /// True if, when exporting to MP4, the audio track couldn't be stream-copied
        /// and was re-encoded to AAC instead. Surfaced so the quality change is never silent.
        let usedAudioReencodeFallback: Bool
    }

    enum ExportError: LocalizedError {
        case invalidRange
        case ffmpegFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidRange:
                return "The end time must be after the start time."
            case .ffmpegFailed(let detail):
                return "Export failed: \(detail)"
            }
        }
    }

    /// Runs the export. `onProgress` receives a 0...1 fraction on an arbitrary queue;
    /// hop to the main actor in the caller before touching UI state.
    static func export(
        _ request: Request,
        tools: FFmpegLocator.Tools,
        onProgress: @escaping (Double) -> Void
    ) async throws -> Result {
        let clipDuration = request.end - request.start
        guard clipDuration > 0 else { throw ExportError.invalidRange }

        let outputURL = try uniqueOutputURL(for: request.sourceURL, start: request.start, end: request.end, format: request.format)

        if request.precise {
            let args = preciseArguments(request: request, clipDuration: clipDuration, outputURL: outputURL)
            try await runFFmpeg(tools.ffmpeg, args, totalDuration: clipDuration, onProgress: onProgress)
            return Result(outputURL: outputURL, usedAudioReencodeFallback: false)
        }

        // Fast (stream-copy) path: ffmpeg can only start a copied stream at an
        // actual keyframe -- it cannot decode-and-drop like the precise path
        // does. Verified empirically: seeking to a non-keyframe timestamp and
        // using `-t <duration>` produces an output *longer* than requested
        // (by up to a GOP's worth of seconds on sources with sparse keyframes,
        // e.g. some OBS recordings with ~4s GOPs) because ffmpeg's internal
        // seek adjustment and its `-t` accounting disagree on where the clip
        // actually starts. Seeking to the *exact* preceding keyframe instead
        // eliminates that mismatch — `-t` is then measured from a real sync
        // point and lands within a frame of the requested end. The visible
        // cost is the documented tradeoff: the copied clip's true start snaps
        // backward to that keyframe rather than the requested time.
        let seekStart = await nearestKeyframeTimestamp(atOrBefore: request.start, sourceURL: request.sourceURL, tools: tools)
        let copyDuration = request.end - seekStart

        // Fast path: try a full stream copy first.
        let copyArgs = fastCopyArguments(request: request, seekStart: seekStart, clipDuration: copyDuration, outputURL: outputURL, reencodeAudio: false)
        do {
            try await runFFmpeg(tools.ffmpeg, copyArgs, totalDuration: copyDuration, onProgress: onProgress)
            return Result(outputURL: outputURL, usedAudioReencodeFallback: false)
        } catch {
            // Common on MP4 output when the source audio codec (e.g. AC-3, or MKV-only
            // codecs) isn't legal inside an MP4 container. Retry once with AAC audio.
            guard request.format == .mp4 else { throw error }
            try? FileManager.default.removeItem(at: outputURL) // clean up any partial output
            let fallbackArgs = fastCopyArguments(request: request, seekStart: seekStart, clipDuration: copyDuration, outputURL: outputURL, reencodeAudio: true)
            try await runFFmpeg(tools.ffmpeg, fallbackArgs, totalDuration: copyDuration, onProgress: onProgress)
            return Result(outputURL: outputURL, usedAudioReencodeFallback: true)
        }
    }

    /// Finds the timestamp of the last video keyframe at or before `target`,
    /// by asking ffprobe for the list of keyframe packets. `-read_intervals`
    /// bounds ffprobe to scanning only `[0, target]` -- without it, ffprobe
    /// demuxes the *entire* file just to list packets, which is needlessly
    /// slow (and was measured to effectively hang on a real ~12-minute MP4
    /// recording). Falls back to `target` unmodified if ffprobe isn't
    /// available or the lookup fails -- fast-copy exports may then overshoot
    /// the requested end on sparse-keyframe sources, but the app still
    /// functions with ffmpeg alone.
    private static func nearestKeyframeTimestamp(atOrBefore target: Double, sourceURL: URL, tools: FFmpegLocator.Tools) async -> Double {
        guard target > 0, let ffprobePath = tools.ffprobe else { return max(target, 0) }
        let arguments = [
            "-v", "error",
            "-read_intervals", "%\(target)",
            "-select_streams", "v:0",
            "-show_entries", "packet=pts_time,flags",
            "-of", "csv=p=0",
            sourceURL.path,
        ]
        guard let output = try? await runCapture(ffprobePath, arguments) else { return target }

        var best = 0.0
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: ",")
            guard fields.count == 2, fields[1].contains("K"), let pts = Double(fields[0]), pts <= target else { continue }
            best = pts
        }
        return best
    }

    /// Runs a process to completion and returns its combined stdout.
    /// Reads incrementally as data arrives (rather than waiting for the
    /// process to exit and reading once) -- pipes have a small kernel buffer,
    /// and a process producing more output than that buffer will block on
    /// `write()` forever if nothing drains the pipe while it's still running.
    private static func runCapture(_ executable: String, _ arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let stdoutPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = Pipe()

            let outputBuffer = UnboundedOutputBuffer()

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                outputBuffer.append(text)
            }

            process.terminationHandler = { proc in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: outputBuffer.contents)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Argument construction

    private static func fastCopyArguments(request: Request, seekStart: Double, clipDuration: Double, outputURL: URL, reencodeAudio: Bool) -> [String] {
        var args = [
            "-hide_banner", "-y",
            "-ss", String(seekStart),
            "-i", request.sourceURL.path,
            "-t", String(clipDuration),
        ]

        switch request.format {
        case .mkv:
            // MKV container is permissive — a straight full-stream copy works for
            // essentially every codec combination that came out of an MKV source.
            args += ["-map", "0", "-c", "copy", "-avoid_negative_ts", "make_zero"]
        case .mp4:
            args += ["-map", "0:v:0", "-map", "0:a:0?"]
            if reencodeAudio {
                args += ["-c:v", "copy", "-c:a", "aac", "-b:a", "192k"]
            } else {
                args += ["-c", "copy"]
            }
            args += ["-movflags", "+faststart", "-avoid_negative_ts", "make_zero"]
        }

        args += ["-progress", "pipe:1", outputURL.path]
        return args
    }

    private static func preciseArguments(request: Request, clipDuration: Double, outputURL: URL) -> [String] {
        var args = [
            "-hide_banner", "-y",
            "-ss", String(request.start),
            "-i", request.sourceURL.path,
            "-t", String(clipDuration),
            "-map", "0:v:0", "-map", "0:a:0?",
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "18",
            "-c:a", "aac", "-b:a", "192k",
        ]
        if request.format == .mp4 {
            args += ["-movflags", "+faststart"]
        }
        args += ["-progress", "pipe:1", outputURL.path]
        return args
    }

    // MARK: - Output path

    /// Builds `~/Downloads/<basename>_clip_<start>-<end>.<ext>`, appending
    /// " (2)", " (3)", ... on collision so an existing file is never overwritten.
    private static func uniqueOutputURL(for sourceURL: URL, start: Double, end: Double, format: OutputFormat) throws -> URL {
        let downloads = try FileManager.default.url(
            for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let base = sourceURL.deletingPathExtension().lastPathComponent
        let stem = "\(base)_clip_\(Timecode.filenameSafe(start))-\(Timecode.filenameSafe(end))"

        var candidate = downloads.appendingPathComponent(stem).appendingPathExtension(format.rawValue)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = downloads.appendingPathComponent("\(stem) (\(suffix))").appendingPathExtension(format.rawValue)
            suffix += 1
        }
        return candidate
    }

    // MARK: - Process execution with progress

    private static func runFFmpeg(
        _ executable: String,
        _ arguments: [String],
        totalDuration: Double,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // Accumulate the stderr tail so a failure can be reported with a
            // real reason instead of a bare exit code.
            let stderrBuffer = StderrBuffer()

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                for line in text.split(separator: "\n") {
                    if line.hasPrefix("out_time_us=") {
                        let valueString = line.dropFirst("out_time_us=".count)
                        if let microseconds = Double(valueString), totalDuration > 0 {
                            let fraction = min(max(microseconds / 1_000_000 / totalDuration, 0), 1)
                            onProgress(fraction)
                        }
                    }
                }
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                stderrBuffer.append(text)
            }

            process.terminationHandler = { proc in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                if proc.terminationStatus == 0 {
                    onProgress(1.0)
                    continuation.resume(returning: ())
                } else {
                    let tail = stderrBuffer.tail(lines: 8)
                    continuation.resume(throwing: ExportError.ffmpegFailed(tail.isEmpty ? "exit code \(proc.terminationStatus)" : tail))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: ExportError.ffmpegFailed(error.localizedDescription))
            }
        }
    }
}

/// Thread-safe rolling buffer of ffmpeg's stderr, so a failure can be reported
/// with the last few diagnostic lines rather than just an exit code.
private final class StderrBuffer: @unchecked Sendable {
    private var lines: [String] = []
    private let lock = NSLock()

    func append(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        lines.append(contentsOf: text.split(separator: "\n").map(String.init))
        if lines.count > 200 {
            lines.removeFirst(lines.count - 200)
        }
    }

    func tail(lines count: Int) -> String {
        lock.lock()
        defer { lock.unlock() }
        return lines.suffix(count).joined(separator: "\n")
    }
}

/// Thread-safe, untruncated accumulator for a process's full stdout --
/// used where every line of output is meaningful (e.g. a keyframe list),
/// unlike `StderrBuffer` which intentionally keeps only a diagnostic tail.
private final class UnboundedOutputBuffer: @unchecked Sendable {
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
