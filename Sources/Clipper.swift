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

        // T2.5: "Same Quality"/"Smaller" were renamed once Tier 6 made them
        // true -- both audit rounds measured the old hardware-encoder path
        // *not* matching source quality, and "Smaller" sometimes losing to
        // "Same Quality" on both size and VMAF at once. Shortened from the
        // task list's "High quality (re-encoded)"/"Compact (re-encoded)" to
        // fit this picker's segmented control; the fuller phrasing lives in
        // the pre-export summary panel (`summaryLines`) instead, where
        // there's room for it.
        var displayName: String {
            switch self {
            case .smaller: return "Compact"
            case .same: return "High Quality"
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
        /// Which HEVC encoder a Precise export uses:
        /// - `false` (default): `hevc_videotoolbox` -- Apple Silicon's
        ///   fixed-function hardware encoder. Near-real-time, low power. The
        ///   sane default for a laptop, especially on longer clips.
        /// - `true`: `libx265 -preset slow` -- pure software. Roughly an
        ///   order of magnitude slower and pins every CPU core for the whole
        ///   run, but genuinely better quality-per-byte, so a re-encode is
        ///   more likely to come out smaller than the source. Opt-in, for
        ///   when the machine is plugged in and the wait is acceptable.
        ///
        /// Tier 6 (T6.2) originally made software the *only* path; that made
        /// every Precise export a multi-minute, battery-draining operation,
        /// so hardware is back as the default with software as a toggle.
        var useSoftwareEncoder: Bool = false
        /// Which audio tracks (by `VideoProbe.StreamTrack.typeIndex`) a
        /// Precise export maps -- Tier 3's per-track selection, replacing
        /// T1.1's "map every track" default with one a user actually
        /// chose, or -- wherever a request is built without going through
        /// the track picker -- `Clipper.defaultTrackSelection`'s "one
        /// track matching system language" default. No default value here:
        /// every call site has to pick one deliberately rather than
        /// silently inherit "all tracks" or "none". Ignored by Fast
        /// exports, which keep their own fixed map (see the guardrail
        /// against changing Fast, TASKS-lossless.md).
        var selectedAudioTracks: Set<Int>
        /// Same idea as `selectedAudioTracks`, for subtitle tracks. An
        /// empty set (Tier 3's own default) means "no subtitles," not
        /// "fall back to something else" -- there's no separate nil case.
        var selectedSubtitleTracks: Set<Int>
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
        /// Non-fatal notices about what changed during export -- e.g. a subtitle
        /// track dropped because its codec can't convert into the target
        /// container. Empty when there's nothing to report. Surfaced so a
        /// dropped track is never silent (TASKS-lossless.md T1.1).
        let warnings: [String]
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
        let outputURL = try uniqueOutputURL(in: directory, for: request.sourceURL, start: request.start, end: request.end, format: request.format, resolution: request.resolution)

        if request.precise {
            // T1.1: figure out up front which subtitle tracks the target
            // container can actually carry -- MKV keeps everything, MP4
            // only text-based codecs it can convert to mov_text. Whatever's
            // left out is reported back, never dropped silently.
            let subtitlePlan = subtitlePlan(sourceInfo: request.sourceInfo, outputFormat: request.format, selection: request.selectedSubtitleTracks)
            let warnings = subtitlePlan.droppedDescriptions.map {
                "Dropped subtitle track (\($0)) -- its format can't convert into \(request.format.displayName)."
            }

            // T1.2: try a native audio copy first. Mirrors the Fast path's
            // own MP4 fallback below exactly -- an incompatible codec in an
            // MP4 mux (e.g. AC-3) is rejected essentially immediately, not
            // after most of the (much slower, re-encoded) video has already
            // been processed, so retrying the whole invocation costs little.
            let args = preciseArguments(request: request, clipDuration: clipDuration, outputURL: outputURL, subtitlePlan: subtitlePlan, reencodeAudio: false)
            do {
                try await runFFmpeg(tools.ffmpeg, args, totalDuration: clipDuration, onProgress: onProgress)
                return Result(outputURL: outputURL, usedAudioReencodeFallback: false, warnings: warnings)
            } catch ExportError.cancelled {
                try? FileManager.default.removeItem(at: outputURL)
                throw ExportError.cancelled
            } catch {
                // Only worth retrying with a transcode if audio was
                // actually mapped in the first place -- Tier 3 lets the
                // user deselect every audio track, in which case a failure
                // here has nothing to do with audio codec compatibility.
                guard request.format == .mp4, !request.selectedAudioTracks.isEmpty else {
                    try? FileManager.default.removeItem(at: outputURL)
                    throw clarifyBitDepthFailure(error, pixFmt: request.sourceInfo.pixFmt)
                }
                try? FileManager.default.removeItem(at: outputURL) // clean up any partial output
                let fallbackArgs = preciseArguments(request: request, clipDuration: clipDuration, outputURL: outputURL, subtitlePlan: subtitlePlan, reencodeAudio: true)
                do {
                    try await runFFmpeg(tools.ffmpeg, fallbackArgs, totalDuration: clipDuration, onProgress: onProgress)
                } catch {
                    try? FileManager.default.removeItem(at: outputURL)
                    throw clarifyBitDepthFailure(error, pixFmt: request.sourceInfo.pixFmt)
                }
                return Result(outputURL: outputURL, usedAudioReencodeFallback: true, warnings: warnings)
            }
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
            return Result(outputURL: outputURL, usedAudioReencodeFallback: false, warnings: [])
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
            return Result(outputURL: outputURL, usedAudioReencodeFallback: true, warnings: [])
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

        // Bulk Clip has no track-picker UI (Tier 3's checklist is Single
        // Clip only), so every clip in the batch uses the same computed
        // default rather than "every track" -- resolved once up front
        // since it depends only on the source, not the interval.
        let defaultTracks = defaultTrackSelection(sourceInfo: sourceInfo)

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
                selectedAudioTracks: defaultTracks.audio, selectedSubtitleTracks: defaultTracks.subtitles,
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
    static func nearestKeyframeTimestamp(atOrBefore target: Double, sourceURL: URL, tools: FFmpegLocator.Tools) async -> Double {
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

    /// Subtitle codecs ffmpeg can convert into MP4's `mov_text` -- text-based
    /// formats only. Image-based subtitle codecs (PGS/VobSub/DVB) can't:
    /// ffmpeg errors outright if asked ("Subtitle encoding currently only
    /// possible from text to text or bitmap to bitmap"). Those tracks are
    /// excluded from the MP4 map entirely instead (T1.1), with a warning
    /// surfaced in `Result.warnings` rather than a silent drop.
    private static let mp4ConvertibleSubtitleCodecs: Set<String> = [
        "subrip", "srt", "ass", "ssa", "mov_text", "webvtt", "text",
    ]

    private struct SubtitlePlan {
        /// Ordinal indices (0-based among subtitle streams, i.e. the `n` in
        /// an `0:s:n` stream specifier) to include in the export's `-map` list.
        let mappedOrdinals: [Int]
        /// Descriptions of subtitle tracks left out because their codec
        /// can't convert into the target container -- always empty for MKV,
        /// which keeps everything.
        let droppedDescriptions: [String]
    }

    /// MKV keeps every *selected* subtitle track (`-c:s copy` handles
    /// essentially any subtitle codec natively); MP4 additionally drops
    /// whichever selected tracks `mp4ConvertibleSubtitleCodecs` can't
    /// convert. Convertibility is determined up front from already-probed
    /// codec names, rather than by trial-and-error against ffmpeg -- unlike
    /// the audio codec fallback below, there's no need to run ffmpeg at all
    /// to know this per-track compatibility ahead of time. `selection` is
    /// Tier 3's track picker (by `typeIndex`); a track left out of
    /// `selection` is simply not mapped at all, and doesn't appear in
    /// `droppedDescriptions` -- that list is only for a track the user
    /// *did* want that couldn't make it into the container, since only
    /// those need a warning.
    private static func subtitlePlan(sourceInfo: VideoProbe.Info, outputFormat: OutputFormat, selection: Set<Int>) -> SubtitlePlan {
        let selectedStreams = sourceInfo.subtitleStreams.filter { selection.contains($0.typeIndex) }
        guard outputFormat == .mp4 else {
            return SubtitlePlan(mappedOrdinals: selectedStreams.map { $0.typeIndex }, droppedDescriptions: [])
        }
        var mapped: [Int] = []
        var dropped: [String] = []
        for stream in selectedStreams {
            if mp4ConvertibleSubtitleCodecs.contains(stream.codec.lowercased()) {
                mapped.append(stream.typeIndex)
            } else {
                dropped.append(stream.displayName)
            }
        }
        return SubtitlePlan(mappedOrdinals: mapped, droppedDescriptions: dropped)
    }

    /// Tier 3's sensible default track selection: one audio track matching
    /// the system's preferred language (falling back to the first audio
    /// track if none match), and subtitles off. Used wherever a request is
    /// built without going through the track-picker UI (Bulk Clip, which
    /// has no picker at all) -- deliberately not "every track" (T1.1's own
    /// mechanical default, which is still what an *empty* source-language
    /// list falls back to) or "first track only," both of which either
    /// bloat every export with tracks nobody asked for or silently miss the
    /// one a non-English speaker actually wants.
    static func defaultTrackSelection(sourceInfo: VideoProbe.Info) -> (audio: Set<Int>, subtitles: Set<Int>) {
        guard sourceInfo.hasAudio else { return (audio: [], subtitles: []) }
        let preferredLanguages = Locale.preferredLanguages.compactMap { Locale(identifier: $0).language.languageCode?.identifier }
        let matched = sourceInfo.audioStreams.first { stream in
            guard let language = stream.language else { return false }
            return preferredLanguages.contains { language.lowercased().hasPrefix($0.lowercased()) }
        }
        let defaultIndex = matched?.typeIndex ?? sourceInfo.audioStreams.first?.typeIndex ?? 0
        return (audio: [defaultIndex], subtitles: [])
    }

    /// Rewrites a raw ffmpeg failure into a clearer one when it looks like a
    /// 10-bit/bit-depth rejection from the chosen encoder (T1.5's "fail
    /// loudly" requirement). There's no reliable static way to ask an
    /// encoder like `hevc_videotoolbox` whether it supports 10-bit input on
    /// this particular Mac -- Apple doesn't expose that as a capability
    /// query -- so this recognizes the failure after the fact from ffmpeg's
    /// own stderr instead of trying to predict it up front. Falls through
    /// completely unchanged for every other kind of failure; it only adds
    /// context, never hides the original detail.
    private static func clarifyBitDepthFailure(_ error: Error, pixFmt: String?) -> Error {
        guard let pixFmt, pixFmt.lowercased().contains("10"),
              case ExportError.ffmpegFailed(let detail) = error else { return error }
        let lower = detail.lowercased()
        guard lower.contains("pix_fmt") || lower.contains("pixel format") || lower.contains("p010") || lower.contains("unsupported") else {
            return error
        }
        return ExportError.ffmpegFailed(
            "The hardware encoder can't produce 10-bit output on this Mac, so the export was stopped instead of silently dropping to 8-bit. Turn on \"Use software encoder\" in Advanced Settings — libx265 handles 10-bit — or pick an 8-bit output.\n\n\(detail)"
        )
    }

    private static func preciseArguments(request: Request, clipDuration: Double, outputURL: URL, subtitlePlan: SubtitlePlan, reencodeAudio: Bool) -> [String] {
        var args = [
            "-hide_banner", "-y",
            "-ss", String(request.start),
            "-i", request.sourceURL.path,
            "-t", String(clipDuration),
        ]

        // T1.1: map every real video stream (`V` excludes embedded cover
        // art -- see T1.7/VideoProbe). Audio and subtitle tracks are
        // mapped individually per Tier 3's selection (`request.selected*`)
        // rather than a blanket "every track" -- replacing the original
        // hard-coded "first video, first audio, nothing else," which
        // silently dropped every extra audio track and all subtitles (42
        // lost on one of the audit's sources), without going all the way
        // to the opposite extreme of always keeping every track a source
        // happens to carry.
        args += ["-map", "0:V"]
        for ordinal in request.selectedAudioTracks.sorted() {
            args += ["-map", "0:a:\(ordinal)"]
        }
        for ordinal in subtitlePlan.mappedOrdinals {
            args += ["-map", "0:s:\(ordinal)"]
        }

        args += videoEncodingArguments(tier: request.qualityTier, outputFormat: request.format, useSoftwareEncoder: request.useSoftwareEncoder)

        // T1.2: copy audio natively instead of always transcoding to a fixed
        // 192k AAC -- measured to have halved one source's bitrate and
        // forced a lossy generational transcode on another, for no measured
        // benefit. MP4 can't legally carry every codec (e.g. AC-3), so this
        // still falls back to AAC there, same as the Fast path's own MP4
        // fallback (see the retry in `export(_:tools:onProgress:)`).
        if !request.selectedAudioTracks.isEmpty {
            args += reencodeAudio ? ["-c:a", "aac", "-b:a", "192k"] : ["-c:a", "copy"]
        }

        if !subtitlePlan.mappedOrdinals.isEmpty {
            args += request.format == .mp4 ? ["-c:s", "mov_text"] : ["-c:s", "copy"]
        }

        // T1.6: carry chapters and global metadata through, matching what
        // the Fast path already gets for free via `-c copy`.
        args += ["-map_chapters", "0", "-map_metadata", "0"]

        // Force a keyframe roughly every 6 seconds, regardless of source
        // framerate or which encoder the quality tier picked. Without any
        // forced interval, libx264/libx265 fall back to their own default
        // GOP (250 frames -- ~4s at 60fps, 10+s at 24fps), and a multi-
        // second GOP means seeking in the exported clip stalls (in any
        // player, not just this app) for up to that long while it decodes
        // forward to the next keyframe. 6s is a deliberately relaxed
        // interim value (was a hard-coded 2s, fighting every encoder's own
        // scene-cut placement for no real benefit on a local file) --
        // TASKS-lossless.md T1.4 flags this as worth re-tuning empirically
        // once Tier 6's encoder swap lands, not a number to treat as final.
        // The time-based "expr:gte(t,n_forced*6)" form (vs. a fixed
        // frame-count -g) stays correct regardless of the source's actual
        // framerate.
        args += ["-force_key_frames", "expr:gte(t,n_forced*6)"]

        // T1.5: keep the source's own bit depth through both the direct-
        // encode and scale-filter paths instead of letting either fall back
        // to 8-bit silently. Only forced for a 10-bit source -- an 8-bit
        // source already gets each encoder's normal 8-bit default with
        // nothing to preserve.
        let sourceIs10Bit = (request.sourceInfo.pixFmt ?? "").lowercased().contains("10")
        var filters: [String] = []
        if let targetHeight = request.resolution.targetHeight {
            // scale=-2:H keeps the source's aspect ratio, computing width automatically
            // (rounded to an even number, required by most encoders).
            filters.append("scale=-2:\(targetHeight)")
        } else if request.sourceInfo.width % 2 != 0 || request.sourceInfo.height % 2 != 0 {
            // Native resolution requested, but the source has an odd dimension.
            // libx264 tolerates that; hevc_videotoolbox (the "Smaller" tier)
            // does not -- verified it silently truncates by a pixel with no
            // filter and no error, rather than failing loudly. Make that
            // rounding explicit and identical across every tier instead of
            // leaving it to an undocumented per-encoder default.
            filters.append("scale=trunc(iw/2)*2:trunc(ih/2)*2")
        }
        if sourceIs10Bit, let pixFmt = request.sourceInfo.pixFmt {
            // Forces the filter chain (and, through it, the encoder's own
            // input) to keep the source's exact pixel format instead of
            // letting an implicit conversion settle on an 8-bit
            // intermediate. If the chosen encoder genuinely can't take this
            // format as input, ffmpeg now fails loudly here rather than
            // silently downconverting -- `clarifyBitDepthFailure` above
            // turns that failure into a clear message instead of a raw
            // ffmpeg stderr dump.
            filters.append("format=\(pixFmt)")
        }
        if !filters.isEmpty {
            args += ["-vf", filters.joined(separator: ",")]
        }
        if request.format == .mp4 {
            args += ["-movflags", "+faststart"]
        }
        args += ["-progress", "pipe:1", outputURL.path]
        return args
    }

    /// Picks the HEVC encoder and its constant-quality target for each tier.
    ///
    /// T6.1 deletes the old `-b:v` average-bitrate path entirely (on both
    /// encoders): a whole-file average bitrate is the wrong control variable
    /// for an arbitrary clip, and it wasn't a close call -- on the 10-bit
    /// audit source, a constant-quality export beat the `-b:v` export on
    /// **both** size and VMAF simultaneously (94.6 vs 91.1 VMAF, 91.2 vs
    /// 95.6 MB) with that one variable changed. Both encoder paths below are
    /// constant-quality now, so a shorter clip just costs less, the same
    /// way a lossless copy does.
    ///
    /// **Encoder choice (`useSoftwareEncoder`):**
    ///
    /// - **`hevc_videotoolbox` (default, `useSoftwareEncoder == false`)** --
    ///   Apple Silicon's fixed-function hardware encoder. Near-real-time,
    ///   negligible power draw. T6.2 had removed this as the default in
    ///   favour of software x265; that turned every Precise export into a
    ///   multi-minute, all-cores-pinned, battery-draining job (a full-length
    ///   re-encode ran ~1 hour vs. ~5 minutes on the hardware path), so it's
    ///   back as the default. `-q:v` here is VideoToolbox's 0-100 quality
    ///   scale (higher = better); the values are approximate tier anchors,
    ///   not VMAF-measured -- the hardware `-q:v` scale is non-linear and
    ///   driver-dependent, so it can't be tuned the way CRF can. `.same`'s
    ///   65 matches what the app shipped with pre-Tier-6.
    /// - **`libx265 -preset slow` (`useSoftwareEncoder == true`)** -- pure
    ///   software, ~10x slower, but a real generation ahead in
    ///   rate-distortion, so a re-encode is much more likely to come out
    ///   smaller than the source (the hardware path is why "Smaller"
    ///   sometimes came out *bigger* in the original audits). CRF values
    ///   were verified against this branch's Tier 6 gate (VMAF via `libvmaf`
    ///   on a low-motion 4:2:0 source and a harder detail-heavy 4:4:4 one):
    ///   - `.highestQuality`: CRF 16 -- effectively transparent (97.3/97.3).
    ///   - `.same`: CRF 18 -- 97.3/96.3 VMAF, comfortably above the tier's
    ///     ≥95 gate on both (CRF 20 was tried first and measured 94.93 on
    ///     the harder source -- below the gate -- which is why it re-tests
    ///     against more than one source).
    ///   - `.smaller`: CRF 26 -- reliably smaller *and* lower-VMAF than
    ///     `.same` on both sources (96.4/87.8), fixing the VMAF inversion
    ///     the original audits found.
    private static func videoEncodingArguments(tier: QualityTier, outputFormat: OutputFormat, useSoftwareEncoder: Bool) -> [String] {
        let hevcTag = outputFormat == .mp4 ? ["-tag:v", "hvc1"] : [] // QuickTime/Finder expect 'hvc1', not ffmpeg's default 'hev1'
        if useSoftwareEncoder {
            let crf: Int
            switch tier {
            case .highestQuality: crf = 16
            case .same: crf = 18
            case .smaller: crf = 26
            }
            return ["-c:v", "libx265", "-preset", "slow", "-crf", "\(crf)"] + hevcTag
        } else {
            let quality: Int
            switch tier {
            case .highestQuality: quality = 78
            case .same: quality = 65
            case .smaller: quality = 50
            }
            return ["-c:v", "hevc_videotoolbox", "-q:v", "\(quality)"] + hevcTag
        }
    }

    // MARK: - Pre-export visibility (T2.1/T2.2)

    /// A short, human-readable line per stream describing what a
    /// Precise/Fast export will actually do -- the "what Clipper already
    /// knows" the pre-export summary panel surfaces before the user commits
    /// to an export whose shape would otherwise stay hidden behind the UI
    /// until it's already running.
    static func summaryLines(for request: Request) -> [String] {
        var lines: [String] = []
        if request.precise {
            let encoderArgs = videoEncodingArguments(tier: request.qualityTier, outputFormat: request.format, useSoftwareEncoder: request.useSoftwareEncoder)
            let engine = request.useSoftwareEncoder ? "software x265, slow" : "hardware, fast"
            lines.append("Video: \(describeEncoderArgs(encoderArgs)) → re-encoded (\(engine))")
        } else {
            // T2.5: "Fast" renamed to "Lossless" here -- this is the app's
            // only genuinely bit-exact path, and both audit rounds found
            // the old "Same Quality" Precise tier didn't actually earn that
            // name, which made "Fast" the odd one out for actually meaning
            // what it said. Keeping "keyframe-aligned cut" alongside it so
            // the one real tradeoff (the snapped start, see T2.3 above) is
            // still named, not just "lossless" on its own.
            lines.append("Video: copied (Lossless, keyframe-aligned cut)")
        }

        if !request.sourceInfo.hasAudio {
            lines.append("Audio: none")
        } else if request.precise {
            // Tier 3: reflects whichever tracks are actually selected,
            // not just "the source has audio" -- a user can deselect all
            // of them, or keep more than one.
            let count = request.selectedAudioTracks.count
            lines.append(count == 0 ? "Audio: none selected" : "Audio: \(count) track\(count == 1 ? "" : "s") → copied")
        } else {
            lines.append("Audio: \(request.sourceInfo.audioCodec?.uppercased() ?? "unknown") → copied (Lossless)")
        }

        let subtitleStreams = request.sourceInfo.subtitleStreams
        if subtitleStreams.isEmpty {
            lines.append("Subtitles: none")
        } else if request.precise {
            let plan = subtitlePlan(sourceInfo: request.sourceInfo, outputFormat: request.format, selection: request.selectedSubtitleTracks)
            if plan.mappedOrdinals.isEmpty, plan.droppedDescriptions.isEmpty {
                lines.append("Subtitles: none selected")
            } else if plan.droppedDescriptions.isEmpty {
                lines.append("Subtitles: \(plan.mappedOrdinals.count) track\(plan.mappedOrdinals.count == 1 ? "" : "s") → copied")
            } else {
                lines.append("Subtitles: \(plan.mappedOrdinals.count) copied, \(plan.droppedDescriptions.count) dropped (format can't convert to \(request.format.displayName))")
            }
        } else {
            lines.append("Subtitles: \(subtitleStreams.count) track\(subtitleStreams.count == 1 ? "" : "s") → copied (Lossless)")
        }

        lines.append("Chapters: \(request.sourceInfo.hasChapters ? "copied" : "none")")
        return lines
    }

    /// Pulls a plain-English "codec, quality setting" description out of an
    /// already-built `-c:v ...` argument list, rather than re-deriving the
    /// tier/codec decision a second time -- `videoEncodingArguments` stays
    /// the single place that logic lives.
    private static func describeEncoderArgs(_ args: [String]) -> String {
        func value(after flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
            return args[index + 1]
        }
        let codec = value(after: "-c:v") ?? "unknown"
        let codecName = (codec.contains("264")) ? "H.264" : ((codec.contains("265") || codec.contains("hevc")) ? "HEVC" : codec)
        if let crf = value(after: "-crf") { return "\(codecName), CRF \(crf)" }
        if let q = value(after: "-q:v") { return "\(codecName), Q\(q)" }
        if let bitrate = value(after: "-b:v"), let bps = Int(bitrate) { return "\(codecName), ~\(bps / 1000) kbps" }
        return codecName
    }

    /// Builds the exact ffmpeg invocation `export(_:tools:onProgress:)`
    /// would run for `request` on its first attempt (not a retry/fallback
    /// variant), as a shell-quoted, copy-pasteable string -- the "Copy
    /// ffmpeg command" button (T2.1), so the exact command this app runs is
    /// never hidden behind the UI. Async because the Fast path needs the
    /// same keyframe lookup `export` itself performs to know its real start.
    static func previewCommandLine(for request: Request, tools: FFmpegLocator.Tools) async -> String {
        let clipDuration = request.end - request.start
        guard clipDuration > 0 else { return "" }
        let directory = (try? request.outputDirectory ?? exportsBaseFolder())
        let outputURL = directory.flatMap { try? uniqueOutputURL(in: $0, for: request.sourceURL, start: request.start, end: request.end, format: request.format, resolution: request.resolution) }
            ?? request.sourceURL.deletingLastPathComponent().appendingPathComponent("output.\(request.format.rawValue)")

        let args: [String]
        if request.precise {
            let plan = subtitlePlan(sourceInfo: request.sourceInfo, outputFormat: request.format, selection: request.selectedSubtitleTracks)
            args = preciseArguments(request: request, clipDuration: clipDuration, outputURL: outputURL, subtitlePlan: plan, reencodeAudio: false)
        } else {
            let seekStart = await nearestKeyframeTimestamp(atOrBefore: request.start, sourceURL: request.sourceURL, tools: tools)
            args = fastCopyArguments(request: request, seekStart: seekStart, clipDuration: request.end - seekStart, outputURL: outputURL, reencodeAudio: false)
        }
        return (["ffmpeg"] + args).map(shellQuoted).joined(separator: " ")
    }

    /// Quotes an argument for safe pasting into a shell, only when it
    /// actually needs it -- most ffmpeg flags and simple paths are left
    /// bare so the copied command stays easy to read.
    private static func shellQuoted(_ argument: String) -> String {
        if argument.isEmpty { return "''" }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./:")
        if argument.unicodeScalars.allSatisfy({ safe.contains($0) }) { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
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

    /// Finds the first path under `directory` named `base` (optionally with
    /// `pathExtension`) that doesn't already exist, appending " (2)", " (3)",
    /// ... on collision. The one place this logic lives -- every export path
    /// (single clip, a Bulk Clip session folder, a merge output) goes through
    /// this instead of re-deriving the same while-loop.
    static func uniqueCandidatePath(base: String, in directory: URL, pathExtension: String? = nil) -> URL {
        func candidateURL(_ name: String) -> URL {
            let url = directory.appendingPathComponent(name)
            return pathExtension.map { url.appendingPathExtension($0) } ?? url
        }
        var candidate = candidateURL(base)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = candidateURL("\(base) (\(suffix))")
            suffix += 1
        }
        return candidate
    }

    /// A per-Bulk-Clip-session folder inside `exportsBaseFolder()`, named
    /// after the source file so a session's many same-named-but-different-
    /// timestamp clips stay together instead of loose in the general folder.
    static func uniqueExportSubfolder(named base: String, in parent: URL) throws -> URL {
        let candidate = uniqueCandidatePath(base: base, in: parent)
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        return candidate
    }

    /// Builds `<directory>/<basename>_clip_<start>-<end>[_<height>p].<ext>`,
    /// appending " (2)", " (3)", ... on collision so an existing file is
    /// never overwritten. The resolution suffix is omitted for `.native`
    /// (today's exact filename, unchanged) and only appears for an actual
    /// downscale -- needed now that a Queue can produce several exports of
    /// the same range at different resolutions, which would otherwise all
    /// collide down to the same stem and just pile up as "(2)", "(3)".
    private static func uniqueOutputURL(in directory: URL, for sourceURL: URL, start: Double, end: Double, format: OutputFormat, resolution: Resolution) throws -> URL {
        let base = sourceURL.deletingPathExtension().lastPathComponent
        var stem = "\(base)_clip_\(Timecode.filenameSafe(start))-\(Timecode.filenameSafe(end))"
        if let height = resolution.targetHeight { stem += "_\(height)p" }
        return uniqueCandidatePath(base: stem, in: directory, pathExtension: format.rawValue)
    }

    // MARK: - Process execution with progress

    static func runFFmpeg(
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
        // from "ffmpeg hit a real error". This gate is what onCancel below
        // uses to record that, so the termination handler can tell the
        // difference directly instead of guessing from the signal -- and
        // (see the type's own doc comment) it's also what keeps a
        // cancellation that arrives right as the process is about to launch
        // from being silently lost.
        let cancellationGate = CancellationGate()

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
                        } else if cancellationGate.isCancelled {
                            continuation.resume(throwing: ExportError.cancelled)
                        } else {
                            let tail = stderrBuffer.tail(lines: 8)
                            continuation.resume(throwing: ExportError.ffmpegFailed(tail.isEmpty ? "exit code \(proc.terminationStatus)" : tail))
                        }
                    }

                    // `onCancel` (below) can fire before this closure even runs, let
                    // alone before `process.run()` -- Swift only guarantees it runs
                    // no *later* than cancellation, not that `operation` has made any
                    // particular progress first. `cancellationGate.launch(_:)` decides
                    // "launch or don't" and actually calls `process.run()` under one
                    // lock shared with `onCancel`'s `cancel()`, so there's no gap
                    // between the two where a cancellation could be seen by neither
                    // side -- if `launch(_:)` says no, the process was never started,
                    // so the continuation is resumed right here instead of waiting on
                    // a termination handler that will now never fire.
                    do {
                        guard try cancellationGate.launch(process) else {
                            continuation.resume(throwing: ExportError.cancelled)
                            return
                        }
                        RunningExports.shared.register(process)
                    } catch {
                        continuation.resume(throwing: ExportError.ffmpegFailed(error.localizedDescription))
                    }
                }
            },
            onCancel: {
                cancellationGate.cancel()
            }
        )
    }
}

/// Thread-safe one-shot flag: set once, from whichever thread cancels the task.
/// Coordinates a `Process`'s launch with cancellation under one lock, so
/// "should this launch" and "should this be terminated" can never be
/// decided out of sync with each other. Two independent checks used to
/// handle this (a plain cancelled flag checked right before `process.run()`,
/// and a `process.isRunning` check inside `onCancel`) but left a gap: a
/// cancellation arriving between the first check passing and `process.run()`
/// actually executing saw "not cancelled yet" on one side and "not running
/// yet" on the other, so neither side terminated it -- it launched and ran
/// to completion, silently ignoring a Force Stop that arrived at exactly
/// the wrong instant.
private final class CancellationGate: @unchecked Sendable {
    private enum State { case idle, launched(Process), cancelled }
    private var state: State = .idle
    private let lock = NSLock()

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        if case .cancelled = state { return true }
        return false
    }

    /// Launches `process` unless cancellation already won the race; returns
    /// whether it actually launched. Holds the lock across `process.run()`
    /// itself (a fast local syscall) so `cancel()` can't observe or act on
    /// a half-finished transition.
    @discardableResult
    func launch(_ process: Process) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .idle = state else { return false }
        try process.run()
        state = .launched(process)
        return true
    }

    /// Terminates `process` immediately if it's already launched;
    /// otherwise just marks cancelled so a `launch(_:)` call still in
    /// flight skips starting it at all.
    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        if case .launched(let process) = state {
            process.terminate()
        }
        state = .cancelled
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
