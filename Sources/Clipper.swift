import Foundation

/// Drives ffmpeg to cut `[start, end)` out of a source video and write the
/// result to ~/Downloads/MKV Clipper Exports.
enum Clipper {

    enum OutputFormat: String, CaseIterable, Identifiable {
        case mkv = "mkv"
        case mp4 = "mp4"
        var id: String { rawValue }
        var displayName: String { rawValue.uppercased() }
    }

    /// Size/quality tradeoff for Precise (re-encoded) exports. Fast/stream-copy
    /// exports are always bit-identical to the source, so this only applies
    /// when `Request.precise` is true.
    enum QualityTier: String, CaseIterable, Identifiable {
        case smaller
        case same
        case highestQuality

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .smaller: return "Smaller"
            case .same: return "Same Quality"
            case .highestQuality: return "Highest Quality"
            }
        }
    }

    /// Output resolution for Precise exports. `native` (no scaling) is always
    /// offered; the others are filtered to the source's own height so this is
    /// never used to upscale (which adds file size without adding real detail).
    enum Resolution: CaseIterable, Identifiable, Hashable {
        case native, p2160, p1440, p1080, p720, p540

        var id: Int { targetHeight ?? 0 }

        var targetHeight: Int? {
            switch self {
            case .native: return nil
            case .p2160: return 2160
            case .p1440: return 1440
            case .p1080: return 1080
            case .p720: return 720
            case .p540: return 540
            }
        }

        var displayName: String {
            switch self {
            case .native: return "Native"
            case .p2160: return "4K (2160p)"
            case .p1440: return "2K (1440p)"
            case .p1080: return "1080p"
            case .p720: return "720p"
            case .p540: return "540p"
            }
        }

        static func availableOptions(sourceHeight: Int) -> [Resolution] {
            allCases.filter { $0 == .native || ($0.targetHeight ?? 0) <= sourceHeight }
        }
    }

    struct Request {
        let sourceURL: URL
        let sourceInfo: VideoProbe.Info
        let start: Double
        let end: Double
        let format: OutputFormat
        let precise: Bool
        var qualityTier: QualityTier = .same
        var resolution: Resolution = .native
        /// Where the clip is written. `nil` means the general exports folder
        /// (`~/Downloads/MKV Clipper Exports`); `exportBatch` sets this to a
        /// shared per-session subfolder so every clip in a Bulk Clip run lands
        /// together.
        var outputDirectory: URL?
    }

    struct Result {
        let outputURL: URL
        /// True if, when exporting to MP4, the audio track couldn't be stream-copied
        /// and was re-encoded to AAC instead. Surfaced so the quality change is never silent.
        let usedAudioReencodeFallback: Bool
    }

    enum ExportError: LocalizedError {
        case invalidRange
        case cancelled
        case ffmpegFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidRange:
                return "The end time must be after the start time."
            case .cancelled:
                return "Export stopped."
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

        let directory = try request.outputDirectory ?? exportsBaseFolder()
        let outputURL = try uniqueOutputURL(in: directory, for: request.sourceURL, start: request.start, end: request.end, format: request.format)

        if request.precise {
            let args = preciseArguments(request: request, clipDuration: clipDuration, outputURL: outputURL)
            do {
                try await runFFmpeg(tools.ffmpeg, args, totalDuration: clipDuration, onProgress: onProgress)
            } catch {
                try? FileManager.default.removeItem(at: outputURL) // don't leave a partial/cancelled file behind
                throw error
            }
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
        } catch ExportError.cancelled {
            // Never retry a user-requested stop -- just clean up and propagate.
            try? FileManager.default.removeItem(at: outputURL)
            throw ExportError.cancelled
        } catch {
            // Common on MP4 output when the source audio codec (e.g. AC-3, or MKV-only
            // codecs) isn't legal inside an MP4 container. Retry once with AAC audio.
            guard request.format == .mp4 else {
                try? FileManager.default.removeItem(at: outputURL)
                throw error
            }
            try? FileManager.default.removeItem(at: outputURL) // clean up any partial output
            let fallbackArgs = fastCopyArguments(request: request, seekStart: seekStart, clipDuration: copyDuration, outputURL: outputURL, reencodeAudio: true)
            do {
                try await runFFmpeg(tools.ffmpeg, fallbackArgs, totalDuration: copyDuration, onProgress: onProgress)
            } catch {
                try? FileManager.default.removeItem(at: outputURL)
                throw error
            }
            return Result(outputURL: outputURL, usedAudioReencodeFallback: true)
        }
    }

    // MARK: - Bulk split into equal-length clips

    /// Splits `[rangeStart, rangeEnd)` into consecutive, gap-free, non-overlapping
    /// intervals of `intervalSeconds` each. The last interval is clamped to
    /// `rangeEnd`, so it comes out shorter when the range doesn't divide evenly.
    ///
    /// Boundaries are computed as `rangeStart + Double(index) * intervalSeconds`
    /// (multiplication, not repeated addition) so floating-point error can't
    /// accumulate across many intervals -- important since this same function
    /// drives both the UI's live clip-count preview and the actual export loop,
    /// and the two must never disagree.
    ///
    /// `bufferSeconds` (default 0, today's exact behavior) pulls every clip's
    /// start back by that much *except the first clip*, so consecutive clips
    /// overlap and nothing right at a cut boundary gets lost. Only the start
    /// moves -- ends stay at the normal boundaries, so the last clip still
    /// stops exactly at `rangeEnd` rather than reaching past footage that
    /// doesn't exist. A buffered start is clamped to never precede `rangeStart`.
    static func splitIntoIntervals(rangeStart: Double, rangeEnd: Double, intervalSeconds: Double, bufferSeconds: Double = 0) -> [(start: Double, end: Double)] {
        guard intervalSeconds > 0, rangeEnd > rangeStart else { return [] }
        var result: [(start: Double, end: Double)] = []
        var index = 0
        while true {
            let normalStart = rangeStart + Double(index) * intervalSeconds
            if normalStart >= rangeEnd { break }
            let end = min(normalStart + intervalSeconds, rangeEnd)
            let start = index == 0 ? normalStart : max(rangeStart, normalStart - bufferSeconds)
            result.append((start: start, end: end))
            index += 1
        }
        return result
    }

    enum BatchError: LocalizedError {
        case clipFailed(index: Int, total: Int, underlying: Error)

        var errorDescription: String? {
            switch self {
            case .clipFailed(let index, let total, let underlying):
                if case ExportError.cancelled = underlying {
                    return "Stopped after clip \(index) of \(total)."
                }
                return "Stopped at clip \(index + 1) of \(total): \(underlying.localizedDescription)"
            }
        }
    }

    /// Exports each interval as a separate clip, sequentially -- one ffmpeg
    /// process at a time, both for simplicity and to avoid any risk of
    /// contention between concurrent hardware-encoder sessions. Always uses
    /// Precise mode: Fast mode's keyframe-snapped start (see `export` above)
    /// would leave gaps or duplicated frames at clip boundaries, which defeats
    /// the entire point of splitting a video into contiguous pieces.
    ///
    /// Stops on the first failure or cancellation and leaves already-completed
    /// clips in place -- simpler and safer than trying to skip past bad clips
    /// or roll back finished ones.
    static func exportBatch(
        sourceURL: URL,
        sourceInfo: VideoProbe.Info,
        intervals: [(start: Double, end: Double)],
        format: OutputFormat,
        qualityTier: QualityTier,
        resolution: Resolution,
        tools: FFmpegLocator.Tools,
        onProgress: @escaping (_ completedClips: Int, _ totalClips: Int, _ currentClipFraction: Double) -> Void
    ) async throws -> [URL] {
        // One subfolder per session, named after the source file, resolved once
        // up front so every clip in this run lands together rather than loose
        // in the general exports folder.
        let sessionFolder = try uniqueExportSubfolder(
            named: sourceURL.deletingPathExtension().lastPathComponent,
            in: exportsBaseFolder()
        )

        var outputURLs: [URL] = []
        for (index, interval) in intervals.enumerated() {
            do {
                try Task.checkCancellation()
            } catch {
                throw BatchError.clipFailed(index: index, total: intervals.count, underlying: ExportError.cancelled)
            }

            let request = Request(
                sourceURL: sourceURL, sourceInfo: sourceInfo, start: interval.start, end: interval.end,
                format: format, precise: true, qualityTier: qualityTier, resolution: resolution,
                outputDirectory: sessionFolder
            )
            do {
                let result = try await export(request, tools: tools) { fraction in
                    onProgress(index, intervals.count, fraction)
                }
                outputURLs.append(result.outputURL)
            } catch {
                throw BatchError.clipFailed(index: index, total: intervals.count, underlying: error)
            }
        }
        onProgress(intervals.count, intervals.count, 1.0)
        return outputURLs
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
        ]

        args += videoEncodingArguments(tier: request.qualityTier, sourceInfo: request.sourceInfo, outputFormat: request.format)
        args += ["-c:a", "aac", "-b:a", "192k"]

        // Force a keyframe every 2 seconds, regardless of source framerate or
        // which encoder the quality tier picked. Without this, libx264 falls
        // back to its default 250-frame GOP -- fine at low framerates, but on
        // a 60fps source that's a keyframe every ~4.17s. Players can only
        // resume playback at a keyframe after a seek, so a multi-second GOP
        // produces exactly what it sounds like: seeking forward/back in the
        // exported clip stalls (audio drops out) for up to that long while it
        // waits for/decodes forward to the next keyframe. The time-based
        // "expr:gte(t,n_forced*2)" form (vs. a fixed frame-count -g) stays
        // correct regardless of the source's actual framerate.
        args += ["-force_key_frames", "expr:gte(t,n_forced*2)"]

        if let targetHeight = request.resolution.targetHeight {
            // scale=-2:H keeps the source's aspect ratio, computing width automatically
            // (rounded to an even number, required by most encoders).
            args += ["-vf", "scale=-2:\(targetHeight)"]
        } else if request.sourceInfo.width % 2 != 0 || request.sourceInfo.height % 2 != 0 {
            // Native resolution requested, but the source has an odd dimension.
            // libx264 tolerates that; hevc_videotoolbox (the "Smaller" tier)
            // does not -- verified it silently truncates by a pixel with no
            // filter and no error, rather than failing loudly. Make that
            // rounding explicit and identical across every tier instead of
            // leaving it to an undocumented per-encoder default.
            args += ["-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2"]
        }
        if request.format == .mp4 {
            args += ["-movflags", "+faststart"]
        }
        args += ["-progress", "pipe:1", outputURL.path]
        return args
    }

    /// Picks the encoder and quality/bitrate target for each tier.
    ///
    /// - `.smaller` always uses hardware HEVC (Apple's VideoToolbox encoder):
    ///   verified ~7x smaller than H.264 CRF 18 at comparable visual quality,
    ///   at similar or better speed since it's hardware-accelerated.
    /// - `.same` matches the source's own codec family and targets its
    ///   measured bitrate, so a shorter clip comes out proportionally smaller
    ///   -- verified this reproduces close to the source's own size/quality
    ///   ratio. Falls back to a reasonable fixed quality setting if the
    ///   source's bitrate couldn't be determined (some containers omit it).
    /// - `.highestQuality` is the original fixed H.264 CRF 18 behavior:
    ///   prioritizes quality/precision and accepts the largest files.
    private static func videoEncodingArguments(tier: QualityTier, sourceInfo: VideoProbe.Info, outputFormat: OutputFormat) -> [String] {
        let hevcTag = outputFormat == .mp4 ? ["-tag:v", "hvc1"] : [] // QuickTime/Finder expect 'hvc1', not ffmpeg's default 'hev1'

        switch tier {
        case .smaller:
            return ["-c:v", "hevc_videotoolbox", "-q:v", "60"] + hevcTag
        case .same:
            let sourceIsHEVC = sourceInfo.videoCodec.lowercased().contains("hevc") || sourceInfo.videoCodec.lowercased().contains("265")
            if sourceIsHEVC {
                if let bitrate = sourceInfo.videoBitrate {
                    return ["-c:v", "hevc_videotoolbox", "-b:v", "\(bitrate)"] + hevcTag
                }
                return ["-c:v", "hevc_videotoolbox", "-q:v", "65"] + hevcTag
            } else {
                if let bitrate = sourceInfo.videoBitrate {
                    return ["-c:v", "libx264", "-preset", "veryfast", "-b:v", "\(bitrate)"]
                }
                return ["-c:v", "libx264", "-preset", "veryfast", "-crf", "20"]
            }
        case .highestQuality:
            return ["-c:v", "libx264", "-preset", "veryfast", "-crf", "18"]
        }
    }

    // MARK: - Output path

    /// `~/Downloads/MKV Clipper Exports` -- the general home for every export
    /// this app produces, created on first use. Replaces writing straight
    /// into `~/Downloads`, which got cluttered fast once Bulk Clip sessions
    /// could drop dozens of files there at once.
    static func exportsBaseFolder() throws -> URL {
        let downloads = try FileManager.default.url(
            for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let folder = downloads.appendingPathComponent("MKV Clipper Exports")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A per-Bulk-Clip-session folder inside `exportsBaseFolder()`, named
    /// after the source file so a session's many same-named-but-different-
    /// timestamp clips stay together instead of loose in the general folder.
    /// " (2)", " (3)", ... on collision, same pattern as `uniqueOutputURL`
    /// below, so two sessions on the same source never mix their clips.
    static func uniqueExportSubfolder(named base: String, in parent: URL) throws -> URL {
        var candidate = parent.appendingPathComponent(base)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(base) (\(suffix))")
            suffix += 1
        }
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        return candidate
    }

    /// Builds `<directory>/<basename>_clip_<start>-<end>.<ext>`, appending
    /// " (2)", " (3)", ... on collision so an existing file is never overwritten.
    private static func uniqueOutputURL(in directory: URL, for sourceURL: URL, start: Double, end: Double, format: OutputFormat) throws -> URL {
        let base = sourceURL.deletingPathExtension().lastPathComponent
        let stem = "\(base)_clip_\(Timecode.filenameSafe(start))-\(Timecode.filenameSafe(end))"

        var candidate = directory.appendingPathComponent(stem).appendingPathExtension(format.rawValue)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(stem) (\(suffix))").appendingPathExtension(format.rawValue)
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

        // ffmpeg traps SIGTERM and exits through its own "graceful shutdown"
        // path (logging "Exiting normally, received signal 15" and a non-zero
        // status) rather than dying from an uncaught signal -- so
        // `Process.terminationReason` can't distinguish "we cancelled this"
        // from "ffmpeg hit a real error". This flag is set by onCancel below
        // right before terminate() is called, so the termination handler can
        // tell the difference directly instead of guessing from the signal.
        let cancelFlag = CancelFlag()

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

        // Registered with RunningExports so a Force Stop click (which cancels
        // the enclosing Task, triggering onCancel below) and an app-quit
        // safety net (RunningExports.terminateAll(), called from the app
        // delegate) both have a handle to actually kill the child process.
        // Without this, quitting the app left ffmpeg orphaned and still
        // writing to the output file in the background -- exactly the stuck
        // export that prompted this feature, and the two ffmpeg processes it
        // can produce (an old orphan plus a freshly started one, both writing
        // to the same path) is enough to corrupt the output outright.
        try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    process.terminationHandler = { proc in
                        stdoutPipe.fileHandleForReading.readabilityHandler = nil
                        stderrPipe.fileHandleForReading.readabilityHandler = nil
                        RunningExports.shared.unregister(process)
                        if proc.terminationStatus == 0 {
                            onProgress(1.0)
                            continuation.resume(returning: ())
                        } else if cancelFlag.isSet {
                            continuation.resume(throwing: ExportError.cancelled)
                        } else {
                            let tail = stderrBuffer.tail(lines: 8)
                            continuation.resume(throwing: ExportError.ffmpegFailed(tail.isEmpty ? "exit code \(proc.terminationStatus)" : tail))
                        }
                    }

                    do {
                        try process.run()
                        RunningExports.shared.register(process)
                    } catch {
                        continuation.resume(throwing: ExportError.ffmpegFailed(error.localizedDescription))
                    }
                }
            },
            onCancel: {
                cancelFlag.set()
                process.terminate()
            }
        )
    }
}

/// Thread-safe one-shot flag: set once, from whichever thread cancels the task.
private final class CancelFlag: @unchecked Sendable {
    private var flag = false
    private let lock = NSLock()

    func set() {
        lock.lock(); defer { lock.unlock() }
        flag = true
    }

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }
}

/// Tracks currently-running ffmpeg export processes so they can be force-killed
/// -- either cooperatively (Force Stop cancels the Task, which signals the
/// process via `runFFmpeg`'s cancellation handler) or as a hard safety net when
/// the app itself is quitting, so no export is ever left running as an orphan
/// after the app closes.
final class RunningExports: @unchecked Sendable {
    static let shared = RunningExports()
    private init() {}

    private var active: [ObjectIdentifier: Process] = [:]
    private let lock = NSLock()

    func register(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        active[ObjectIdentifier(process)] = process
    }

    func unregister(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        active.removeValue(forKey: ObjectIdentifier(process))
    }

    func terminateAll() {
        lock.lock()
        let processes = Array(active.values)
        lock.unlock()
        for process in processes where process.isRunning {
            process.terminate()
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
