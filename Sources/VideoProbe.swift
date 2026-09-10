import Foundation

/// Reads metadata about a video file using ffprobe (preferred) or ffmpeg (fallback).
enum VideoProbe {

    struct Info {
        let durationSeconds: Double
        let hasAudio: Bool
        let width: Int
        let height: Int
        let videoCodec: String
        /// Video-stream bitrate in bits/sec. When the container declares a
        /// per-stream value, that's used as-is; when it doesn't (notably
        /// many MKVs), this is estimated from actual packet sizes rather
        /// than falling back to the container's total bitrate, which mixes
        /// in audio/subtitle bytes and can overstate the video's own share
        /// by a double-digit percentage (see TASKS-lossless.md T1.3). Still
        /// nil if even that estimate couldn't be produced.
        let videoBitrate: Int?
        /// nil when `hasAudio` is false. Used to compare audio compatibility
        /// across multiple source files before a stream-copy merge.
        let audioCodec: String?
        /// The video stream's own declared duration, when the container
        /// reports one -- distinct from `durationSeconds` (the container-level
        /// duration), because the two can genuinely disagree on files with an
        /// internally mismatched video/audio length. nil when unavailable.
        let videoStreamDurationSeconds: Double?
        /// The audio stream's own declared duration, same caveat as above.
        /// nil when `hasAudio` is false or unavailable.
        let audioStreamDurationSeconds: Double?
        /// Video frames per second, e.g. 29.97 or 30. Mixing frame rates
        /// across a stream-copy concat is a well-known source of desync --
        /// ffmpeg doesn't retime frames during a pure copy, so a boundary
        /// between differing rates can throw audio/video off for everything
        /// after it. nil when unavailable.
        let videoFrameRate: Double?
        /// nil when `hasAudio` is false or unavailable. Mixing sample rates
        /// across a stream-copy concat is the audio equivalent of the frame
        /// rate problem above -- no resampling happens during a pure copy.
        let audioSampleRate: Int?
        /// nil when `hasAudio` is false or unavailable.
        let audioChannels: Int?
        /// The primary video stream's pixel format, e.g. "yuv420p10le" for a
        /// 10-bit source vs. "yuv420p" for 8-bit. nil when unavailable (only
        /// the ffmpeg-stderr fallback probe below lacks this). Lets
        /// `Clipper` guard against a 10-bit source silently losing bit depth
        /// on an encoder or scale filter that defaults to 8-bit output.
        let pixFmt: String?
        /// Every audio stream in the source, in container order -- not just
        /// the first/default one `audioCodec` above describes. `typeIndex`
        /// on each is the value that slots into an `0:a:<n>` stream
        /// specifier. Used by the Tier 3 track-selection checklist and by
        /// `Clipper`'s track mapping, which need to reason about every
        /// track, not only the default.
        let audioStreams: [StreamTrack]
        /// Every subtitle stream in the source. Empty (not nil) when there
        /// are none, which is most sources.
        let subtitleStreams: [StreamTrack]
        /// True when the source has chapter markers to preserve.
        /// Informational only (surfaced in the pre-export summary panel).
        let hasChapters: Bool
    }

    /// One audio or subtitle stream as reported by ffprobe -- enough to both
    /// describe it in a UI list (Tier 3's track checklist) and reason about
    /// export compatibility (e.g. deciding per-stream whether a subtitle
    /// codec can convert to MP4's `mov_text`).
    struct StreamTrack: Identifiable {
        /// 0-based position among streams of this same type -- the value
        /// that slots into an `0:a:<n>`/`0:s:<n>` stream specifier. Not the
        /// container-wide absolute index ffprobe also reports.
        let typeIndex: Int
        let codec: String
        let language: String?
        let title: String?

        var id: Int { typeIndex }

        var displayName: String {
            var parts: [String] = []
            if let language, !language.isEmpty, language.lowercased() != "und" { parts.append(language) }
            parts.append(codec.uppercased())
            if let title, !title.isEmpty { parts.append("\"\(title)\"") }
            return parts.joined(separator: " · ")
        }
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

    /// One JSON query covers format duration, every stream (video/audio/
    /// subtitle), and chapter presence -- replacing three separate flat
    /// `key=value` queries. JSON (rather than the old
    /// `default=noprint_wrappers=1`) is what makes this possible: that flat
    /// format has no way to delimit multiple same-shaped stream blocks, so
    /// it only ever worked because the old queries used `-select_streams
    /// v:0`/`a:0` to guarantee exactly one match. Selecting every stream at
    /// once (needed for T1.1's full track mapping and the Tier 3 track
    /// list) needs a format that actually distinguishes stream boundaries.
    private static func probeWithFFprobe(url: URL, ffprobePath: String) async throws -> Info {
        let output = try await run(
            executable: ffprobePath,
            arguments: [
                "-v", "error",
                "-show_entries", "format=duration:stream=index,codec_type,codec_name,width,height,bit_rate,duration,r_frame_rate,pix_fmt,sample_rate,channels:stream_tags=language,title:stream_disposition=attached_pic",
                "-show_chapters",
                "-of", "json",
                url.path,
            ]
        )
        guard let data = output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProbeError.processFailed("Couldn't parse ffprobe's output.")
        }

        guard let duration = doubleValue(((root["format"] as? [String: Any])?["duration"])),
              duration.isFinite, duration > 0 else {
            throw ProbeError.durationNotFound
        }

        let hasChapters = !((root["chapters"] as? [[String: Any]] ?? []).isEmpty)
        let streams = root["streams"] as? [[String: Any]] ?? []

        let videoStreams = streams.filter { (stringValue($0["codec_type"]) ?? "") == "video" }
        // Exclude embedded cover art (a video-typed stream flagged
        // `attached_pic`) from being picked as the primary video stream --
        // T1.7. A file whose first video stream is cover art would
        // otherwise probe as a 0x0 "video," misfiring resolution matching,
        // the bitrate estimate below, and the scale filter.
        let primaryVideo = videoStreams.first(where: { !isAttachedPic($0) }) ?? videoStreams.first ?? [:]

        let width = intValue(primaryVideo["width"]) ?? 0
        let height = intValue(primaryVideo["height"]) ?? 0
        let videoCodec = stringValue(primaryVideo["codec_name"]) ?? "unknown"
        let pixFmt = stringValue(primaryVideo["pix_fmt"])
        let videoStreamDurationSeconds = doubleValue(primaryVideo["duration"])
        let videoFrameRate = parseFrameRateFraction(stringValue(primaryVideo["r_frame_rate"]))
        var videoBitrate = intValue(primaryVideo["bit_rate"])

        // Some containers (notably several MKVs) don't declare a per-stream
        // bit_rate. Estimate it from the stream's own packet sizes instead
        // of falling back to the container-level bitrate, which is the
        // video+audio+subtitles total -- see T1.3.
        if videoBitrate == nil, let streamIndex = intValue(primaryVideo["index"]) {
            videoBitrate = await estimateVideoBitrateFromPackets(
                url: url, ffprobePath: ffprobePath, streamIndex: streamIndex,
                sampleWindowSeconds: min(30, duration)
            )
        }

        let allAudio = streams.filter { (stringValue($0["codec_type"]) ?? "") == "audio" }
        let audioStreams = allAudio.enumerated().map { index, stream in
            StreamTrack(
                typeIndex: index, codec: stringValue(stream["codec_name"]) ?? "unknown",
                language: tagValue(stream, "language"), title: tagValue(stream, "title")
            )
        }
        let firstAudio = allAudio.first
        let hasAudio = firstAudio != nil
        let audioCodec = firstAudio.flatMap { stringValue($0["codec_name"]) }
        let audioStreamDurationSeconds = firstAudio.flatMap { doubleValue($0["duration"]) }
        let audioSampleRate = firstAudio.flatMap { intValue($0["sample_rate"]) }
        let audioChannels = firstAudio.flatMap { intValue($0["channels"]) }

        let allSubtitles = streams.filter { (stringValue($0["codec_type"]) ?? "") == "subtitle" }
        let subtitleStreams = allSubtitles.enumerated().map { index, stream in
            StreamTrack(
                typeIndex: index, codec: stringValue(stream["codec_name"]) ?? "unknown",
                language: tagValue(stream, "language"), title: tagValue(stream, "title")
            )
        }

        return Info(
            durationSeconds: duration, hasAudio: hasAudio, width: width, height: height,
            videoCodec: videoCodec, videoBitrate: videoBitrate, audioCodec: audioCodec,
            videoStreamDurationSeconds: videoStreamDurationSeconds, audioStreamDurationSeconds: audioStreamDurationSeconds,
            videoFrameRate: videoFrameRate, audioSampleRate: audioSampleRate, audioChannels: audioChannels,
            pixFmt: pixFmt, audioStreams: audioStreams, subtitleStreams: subtitleStreams, hasChapters: hasChapters
        )
    }

    /// Falls back to computing the video stream's own average bitrate from
    /// its packet sizes when the container doesn't declare one. Bounded to
    /// a sample window from the start of the file rather than demuxing the
    /// whole thing -- the same perf tradeoff `nearestKeyframeTimestamp`'s
    /// `-read_intervals` bound makes in Clipper.swift, and for the same
    /// reason (an unbounded packet listing was measured to effectively hang
    /// on a real multi-minute recording). A bounded sample assumes roughly
    /// constant bitrate; not exact for a highly variable-bitrate source, but
    /// a meaningfully better estimate than the container-wide total, which
    /// mixes in audio/subtitle bytes.
    private static func estimateVideoBitrateFromPackets(url: URL, ffprobePath: String, streamIndex: Int, sampleWindowSeconds: Double) async -> Int? {
        guard sampleWindowSeconds > 0 else { return nil }
        guard let output = try? await run(
            executable: ffprobePath,
            arguments: [
                "-v", "error",
                "-select_streams", "\(streamIndex)",
                "-read_intervals", "%\(sampleWindowSeconds)",
                "-show_entries", "packet=size,pts_time",
                "-of", "csv=p=0",
                url.path,
            ]
        ) else { return nil }

        // ffprobe's csv writer always emits packet fields in its own fixed
        // order (pts_time, then size) -- verified empirically that it
        // ignores the order given to -show_entries above, which had these
        // two swapped in an earlier version of this function and silently
        // parsed every line as unparseable (Int("0.13...") fails on the
        // decimal point), making the estimate never fire for the MKVs it
        // exists to fix.
        var totalBytes = 0
        var minPts: Double?
        var maxPts: Double?
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: ",")
            guard fields.count == 2, let size = Int(fields[1]) else { continue }
            totalBytes += size
            if let pts = Double(fields[0]) {
                minPts = min(minPts ?? pts, pts)
                maxPts = max(maxPts ?? pts, pts)
            }
        }
        guard totalBytes > 0, let minPts, let maxPts, maxPts > minPts else { return nil }
        return Int(Double(totalBytes) * 8 / (maxPts - minPts))
    }

    private static func isAttachedPic(_ stream: [String: Any]) -> Bool {
        guard let disposition = stream["disposition"] as? [String: Any] else { return false }
        return intValue(disposition["attached_pic"]) == 1
    }

    private static func tagValue(_ stream: [String: Any], _ key: String) -> String? {
        (stream["tags"] as? [String: Any])?[key] as? String
    }

    /// ffprobe's JSON writer doesn't consistently emit every field as the
    /// same JSON type across ffmpeg versions/fields (e.g. `bit_rate` and
    /// `duration` often come back as JSON strings rather than numbers,
    /// since they can also be "N/A"). These three accept whatever came
    /// back and coerce it, rather than assuming one representation.
    private static func stringValue(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return nil
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let n = any as? Int { return n }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        if let n = any as? Double { return n }
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    /// ffprobe's `r_frame_rate` is a fraction string like "30/1" or "30000/1001".
    private static func parseFrameRateFraction(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        let parts = raw.split(separator: "/")
        guard parts.count == 2, let numerator = Double(parts[0]), let denominator = Double(parts[1]), denominator != 0 else {
            return nil
        }
        return numerator / denominator
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
        let audioCodec = parseAudioCodec(from: text)
        let hasAudio = audioCodec != nil
        let (width, height, videoCodec, videoBitrate) = parseVideoStreamInfo(from: text)
        return Info(
            durationSeconds: duration, hasAudio: hasAudio, width: width, height: height,
            videoCodec: videoCodec, videoBitrate: videoBitrate, audioCodec: audioCodec,
            videoStreamDurationSeconds: nil, audioStreamDurationSeconds: nil,
            // ffmpeg's stderr banner doesn't reliably expose these (or full
            // per-track/chapter detail) in a form worth parsing -- this
            // fallback path only runs when ffprobe is entirely unavailable,
            // an already-rare case. Callers that need the track lists or
            // pixFmt (T1.5's bit-depth guard, Tier 3's track picker) simply
            // see nil/empty here and degrade to "no extra tracks known"
            // rather than crashing.
            videoFrameRate: nil, audioSampleRate: nil, audioChannels: nil,
            pixFmt: nil, audioStreams: [], subtitleStreams: [], hasChapters: false
        )
    }

    /// Parses a line like:
    /// `  Stream #0:1[0x2](und): Audio: aac (LC) (mp4a / 0x6134706D), 48000 Hz, stereo, fltp, 128 kb/s`
    private static func parseAudioCodec(from ffmpegOutput: String) -> String? {
        for line in ffmpegOutput.split(separator: "\n") {
            guard line.contains("Audio:") else { continue }
            return line
                .components(separatedBy: "Audio: ").last?
                .split(separator: " ").first
                .map(String.init)
        }
        return nil
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

    /// Parses a line like:
    /// `  Stream #0:0[0x1](und): Video: hevc (Main) ..., yuv420p(tv, bt709), 3840x2160 [SAR 1:1 DAR 16:9], 10295 kb/s, 23.98 fps, ...`
    private static func parseVideoStreamInfo(from ffmpegOutput: String) -> (width: Int, height: Int, codec: String, bitrate: Int?) {
        for line in ffmpegOutput.split(separator: "\n") {
            guard line.contains("Video:") else { continue }
            let codec = line
                .components(separatedBy: "Video: ").last?
                .split(separator: " ").first
                .map(String.init) ?? "unknown"

            var width = 0, height = 0
            for token in line.split(separator: " ") {
                let cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: ",[]"))
                let parts = cleaned.split(separator: "x")
                if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) {
                    width = w; height = h
                    break
                }
            }

            var bitrate: Int?
            if let range = line.range(of: " kb/s") {
                let beforeUnit = line[..<range.lowerBound]
                if let comma = beforeUnit.range(of: ",", options: .backwards) {
                    let numberText = beforeUnit[comma.upperBound...].trimmingCharacters(in: .whitespaces)
                    if let kbps = Int(numberText) { bitrate = kbps * 1000 }
                }
            }
            return (width, height, codec, bitrate)
        }
        return (0, 0, "unknown", nil)
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
