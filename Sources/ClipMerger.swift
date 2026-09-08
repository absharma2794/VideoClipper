import Foundation

/// Concatenates many whole video files into one, embedding a chapter marker
/// at each source's boundary so players can jump between the original clips.
/// Unlike `Clipper`, which cuts one range out of one source, this is
/// N-sources-in, 1-file-out -- kept separate for that reason, but it reuses
/// `Clipper.runFFmpeg` (progress parsing, cancellation, `RunningExports`
/// registration) rather than duplicating any of that.
enum ClipMerger {

    enum MergeError: LocalizedError {
        case tooFewFiles
        case incompatibleFiles([CompatibilityIssue])

        var errorDescription: String? {
            switch self {
            case .tooFewFiles:
                return "Select at least 2 files to merge."
            case .incompatibleFiles:
                return "These files don't share the same codec, resolution, or audio format, so they can't be merged without re-encoding."
            }
        }
    }

    struct CompatibilityIssue: Identifiable, Hashable {
        let id = UUID()
        let fileName: String
        let property: String
        let value: String
        let expected: String
    }

    struct ChapterSource {
        let url: URL
        let title: String
        let durationSeconds: Double
    }

    // MARK: - Probing

    /// Probes every file concurrently (bounded, so 175 files doesn't spawn
    /// 175 simultaneous ffprobe processes), reporting progress as each
    /// completes.
    static func probeAll(
        urls: [URL],
        tools: FFmpegLocator.Tools,
        maxConcurrency: Int = 6,
        onProgress: @escaping (_ completed: Int, _ total: Int) -> Void
    ) async throws -> [URL: VideoProbe.Info] {
        try await withThrowingTaskGroup(of: (URL, VideoProbe.Info).self) { group in
            var iterator = urls.makeIterator()
            var results: [URL: VideoProbe.Info] = [:]
            var completed = 0

            func addNext() {
                guard let url = iterator.next() else { return }
                group.addTask { (url, try await VideoProbe.probe(url: url, tools: tools)) }
            }
            for _ in 0..<min(maxConcurrency, urls.count) { addNext() }

            while let (url, info) = try await group.next() {
                results[url] = info
                completed += 1
                onProgress(completed, urls.count)
                addNext()
            }
            return results
        }
    }

    /// A file whose own audio track runs meaningfully shorter than its video
    /// track will silently produce a merged file where audio runs out partway
    /// through -- the video keeps playing muted from that point on, since a
    /// stream-copy concat carries each file's internal defect straight
    /// through rather than fixing it. 2 seconds of tolerance absorbs normal
    /// container/frame-alignment rounding; anything past that is a real
    /// defect worth stopping for.
    private static let audioVideoMismatchToleranceSeconds = 2.0

    /// ffmpeg's concat demuxer does no retiming during a pure stream copy --
    /// a frame rate change mid-stream throws off every timestamp after it.
    /// 0.05fps of tolerance absorbs how some containers round e.g. 29.97
    /// slightly differently; real mismatches (25 vs 30, say) are nowhere
    /// near this close.
    private static let frameRateMismatchTolerance = 0.05

    /// One entry in the data-driven comparison below: how to read a
    /// property off `VideoProbe.Info`, how to print it, and (for properties
    /// like frame rate that need a tolerance) how to decide two values are
    /// "the same". `Value` is whatever's natural for that property (String,
    /// Int, Double) rather than everything being forced through one shape.
    private struct CompatibilityField<Value: Hashable> {
        let property: String
        /// Whether this file participates in the check at all -- e.g. audio
        /// sample rate/channel checks only apply to files that actually have
        /// an audio track, so a silent (video-only) file is skipped here
        /// rather than flagged as "unknown". Defaults to always-applicable.
        let isApplicable: (VideoProbe.Info) -> Bool
        let extract: (VideoProbe.Info) -> Value?
        let describe: (Value) -> String
        let matches: (Value, Value) -> Bool

        init(
            _ property: String,
            isApplicable: @escaping (VideoProbe.Info) -> Bool = { _ in true },
            _ extract: @escaping (VideoProbe.Info) -> Value?,
            describe: @escaping (Value) -> String,
            matches: @escaping (Value, Value) -> Bool = (==)
        ) {
            self.property = property
            self.isApplicable = isApplicable
            self.extract = extract
            self.describe = describe
            self.matches = matches
        }
    }

    /// Compares every file's video codec, resolution, video frame rate, and
    /// audio codec/sample rate/channel count against whatever value is most
    /// common across the whole set for that property -- not always against
    /// `urls.first`, since the first file can itself be the actual outlier
    /// (observed directly: a 5-file set where the first file was the only
    /// 25fps file among four 30fps files reported as "4 files don't match"
    /// instead of flagging the one that actually differs). A file missing a
    /// value for a property that most other files do report is flagged as
    /// unverifiable rather than silently skipped, since letting an unknown
    /// value pass as compatible is exactly how this feature broke before.
    /// Also separately checks each file against itself for an internal
    /// audio/video length mismatch.
    static func checkCompatibility(urls: [URL], infoByURL: [URL: VideoProbe.Info]) -> [CompatibilityIssue] {
        func majority<Value: Hashable>(_ extract: (VideoProbe.Info) -> Value?) -> Value? {
            let counts = Dictionary(
                urls.compactMap { infoByURL[$0] }.compactMap(extract).map { ($0, 1) },
                uniquingKeysWith: +
            )
            return counts.max(by: { $0.value < $1.value })?.key
        }

        let fields: [(URL, VideoProbe.Info) -> CompatibilityIssue?] = [
            makeCheck(CompatibilityField("Video codec", { $0.videoCodec }, describe: { $0 }), majority: majority),
            makeCheck(CompatibilityField("Resolution", { "\($0.width)×\($0.height)" }, describe: { $0 }), majority: majority),
            makeCheck(CompatibilityField("Frame rate", { $0.videoFrameRate }, describe: { String(format: "%.2f fps", $0) }, matches: { abs($0 - $1) <= frameRateMismatchTolerance }), majority: majority),
            // Audio codec is compared for every file, "none" included, so a
            // silent file merged alongside files that do have audio is still
            // correctly flagged -- unlike sample rate/channels below, which
            // are meaningless (and rightly skipped, not flagged) for a file
            // that has no audio track at all.
            makeCheck(CompatibilityField("Audio codec", { $0.audioCodec ?? "none" }, describe: { $0 }), majority: majority),
            makeCheck(CompatibilityField("Audio sample rate", isApplicable: { $0.hasAudio }, { $0.audioSampleRate }, describe: { "\($0) Hz" }), majority: majority),
            makeCheck(CompatibilityField("Audio channels", isApplicable: { $0.hasAudio }, { $0.audioChannels }, describe: { "\($0)" }), majority: majority),
        ]

        var issues: [CompatibilityIssue] = []
        for url in urls {
            guard let info = infoByURL[url] else { continue }
            for field in fields {
                if let issue = field(url, info) { issues.append(issue) }
            }
        }

        for url in urls {
            guard let info = infoByURL[url],
                  let videoDuration = info.videoStreamDurationSeconds,
                  let audioDuration = info.audioStreamDurationSeconds else { continue }
            let gap = videoDuration - audioDuration
            if abs(gap) > audioVideoMismatchToleranceSeconds {
                issues.append(CompatibilityIssue(
                    fileName: url.lastPathComponent, property: "Audio/video length mismatch",
                    value: "audio \(Int(audioDuration))s vs video \(Int(videoDuration))s",
                    expected: "matching lengths"
                ))
            }
        }
        return issues
    }

    /// Binds one `CompatibilityField` against the set's majority value once,
    /// returning a per-file checker: nil when the file matches (or the
    /// property couldn't be determined for the set at all), an issue when it
    /// differs, and an issue tagged "unknown" when this file is missing a
    /// value the majority of the others do have.
    private static func makeCheck<Value: Hashable>(
        _ field: CompatibilityField<Value>,
        majority: (@escaping (VideoProbe.Info) -> Value?) -> Value?
    ) -> (URL, VideoProbe.Info) -> CompatibilityIssue? {
        guard let expected = majority(field.extract) else { return { _, _ in nil } }
        return { url, info in
            guard field.isApplicable(info) else { return nil }
            guard let value = field.extract(info) else {
                return CompatibilityIssue(fileName: url.lastPathComponent, property: field.property, value: "unknown", expected: field.describe(expected))
            }
            guard !field.matches(value, expected) else { return nil }
            return CompatibilityIssue(fileName: url.lastPathComponent, property: field.property, value: field.describe(value), expected: field.describe(expected))
        }
    }

    // MARK: - Output naming

    /// The selected files' common parent folder name (typically a playlist
    /// folder, e.g. "React Course"), falling back to a generic name when
    /// the files come from different folders or the name is empty.
    static func defaultOutputName(for urls: [URL]) -> String {
        let parentNames = Set(urls.map { $0.deletingLastPathComponent().lastPathComponent })
        if parentNames.count == 1, let common = parentNames.first, !common.isEmpty {
            return common
        }
        return "Merged Video"
    }

    private static func uniqueMergedOutputURL(baseName: String, in directory: URL, format: Clipper.OutputFormat) -> URL {
        let trimmed = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeBase = trimmed.isEmpty ? "Merged Video" : trimmed
        return Clipper.uniqueCandidatePath(base: safeBase, in: directory, pathExtension: format.rawValue)
    }

    // MARK: - concat list / ffmetadata chapters file generation

    /// ffmpeg's concat demuxer quoting rule: to embed a literal `'` inside a
    /// single-quoted string, close the quote, escape a literal `'`, reopen.
    private static func concatEscapedPath(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func concatListContents(_ urls: [URL]) -> String {
        urls.map { "file \(concatEscapedPath($0.path))" }.joined(separator: "\n") + "\n"
    }

    /// Escapes ffmetadata's special characters in free-text values (chapter
    /// titles are user-editable, so this isn't just a theoretical concern).
    private static func ffmetadataEscape(_ value: String) -> String {
        var out = ""
        for ch in value {
            if "=;#\\\n".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// One `[CHAPTER]` block per source. Each file's own probed duration is
    /// rounded to whole milliseconds once and summed as integers, so
    /// quantization error stays bounded per-file rather than compounding
    /// across many files the way repeated float round-tripping would.
    private static func chaptersFileContents(for entries: [ChapterSource]) -> String {
        var lines = [";FFMETADATA1"]
        var cursorMs: Int64 = 0
        for entry in entries {
            let durationMs = Int64((entry.durationSeconds * 1000).rounded())
            let start = cursorMs
            let end = cursorMs + durationMs
            lines += [
                "[CHAPTER]",
                "TIMEBASE=1/1000",
                "START=\(start)",
                "END=\(end)",
                "title=\(ffmetadataEscape(entry.title))",
            ]
            cursorMs = end
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Merge

    static func merge(
        entries: [ChapterSource],
        format: Clipper.OutputFormat,
        outputName: String,
        tools: FFmpegLocator.Tools,
        onProgress: @escaping (Double) -> Void
    ) async throws -> Clipper.Result {
        guard entries.count >= 2 else { throw MergeError.tooFewFiles }
        let totalDuration = entries.reduce(0) { $0 + $1.durationSeconds }

        let directory = try Clipper.exportsBaseFolder()
        let outputURL = uniqueMergedOutputURL(baseName: outputName, in: directory, format: format)

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MKVClipperMerge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let listURL = workDir.appendingPathComponent("list.txt")
        let chaptersURL = workDir.appendingPathComponent("chapters.txt")
        try concatListContents(entries.map(\.url)).write(to: listURL, atomically: true, encoding: .utf8)
        try chaptersFileContents(for: entries).write(to: chaptersURL, atomically: true, encoding: .utf8)

        var args = [
            "-hide_banner", "-y",
            "-f", "concat", "-safe", "0", "-i", listURL.path,
            "-i", chaptersURL.path,
            "-map_metadata", "1", "-map_chapters", "1",
        ]
        switch format {
        case .mkv:
            // MKV container is permissive -- a straight full-stream copy
            // works for essentially every codec combination, matching
            // Clipper.fastCopyArguments's MKV case.
            args += ["-map", "0", "-c", "copy"]
        case .mp4:
            // Matches Clipper.fastCopyArguments's MP4 case: video + first
            // audio track only, since there's no re-encode fallback here to
            // recover from an unexpected extra stream failing to mux.
            args += ["-map", "0:v:0", "-map", "0:a:0?", "-c", "copy", "-movflags", "+faststart"]
        }
        args += ["-progress", "pipe:1", outputURL.path]

        do {
            try await Clipper.runFFmpeg(tools.ffmpeg, args, totalDuration: totalDuration, onProgress: onProgress)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
        return Clipper.Result(outputURL: outputURL, usedAudioReencodeFallback: false)
    }
}
