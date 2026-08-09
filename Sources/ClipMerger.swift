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

    /// Compares every file's video codec, resolution, audio codec, video
    /// frame rate, and audio sample rate/channel count against the first
    /// file, and separately checks each file against itself for an internal
    /// audio/video length mismatch. Frame rate and sample rate matter just
    /// as much as codec name for stream-copy correctness -- two files can
    /// report the same codec ("aac", "h264") while still being genuinely
    /// incompatible to concatenate without retiming/resampling, which this
    /// feature deliberately never does.
    static func checkCompatibility(urls: [URL], infoByURL: [URL: VideoProbe.Info]) -> [CompatibilityIssue] {
        guard let firstURL = urls.first, let reference = infoByURL[firstURL] else { return [] }
        var issues: [CompatibilityIssue] = []
        for url in urls.dropFirst() {
            guard let info = infoByURL[url] else { continue }
            let name = url.lastPathComponent
            if info.videoCodec != reference.videoCodec {
                issues.append(CompatibilityIssue(fileName: name, property: "Video codec", value: info.videoCodec, expected: reference.videoCodec))
            }
            if info.width != reference.width || info.height != reference.height {
                issues.append(CompatibilityIssue(
                    fileName: name, property: "Resolution",
                    value: "\(info.width)×\(info.height)", expected: "\(reference.width)×\(reference.height)"
                ))
            }
            if let rate = info.videoFrameRate, let referenceRate = reference.videoFrameRate,
               abs(rate - referenceRate) > frameRateMismatchTolerance {
                issues.append(CompatibilityIssue(
                    fileName: name, property: "Frame rate",
                    value: String(format: "%.2f fps", rate), expected: String(format: "%.2f fps", referenceRate)
                ))
            }
            let audio = info.audioCodec ?? "none"
            let referenceAudio = reference.audioCodec ?? "none"
            if audio != referenceAudio {
                issues.append(CompatibilityIssue(fileName: name, property: "Audio codec", value: audio, expected: referenceAudio))
            }
            if let sampleRate = info.audioSampleRate, let referenceSampleRate = reference.audioSampleRate,
               sampleRate != referenceSampleRate {
                issues.append(CompatibilityIssue(
                    fileName: name, property: "Audio sample rate",
                    value: "\(sampleRate) Hz", expected: "\(referenceSampleRate) Hz"
                ))
            }
            if let channels = info.audioChannels, let referenceChannels = reference.audioChannels,
               channels != referenceChannels {
                issues.append(CompatibilityIssue(
                    fileName: name, property: "Audio channels",
                    value: "\(channels)", expected: "\(referenceChannels)"
                ))
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
        var candidate = directory.appendingPathComponent(safeBase).appendingPathExtension(format.rawValue)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(safeBase) (\(suffix))").appendingPathExtension(format.rawValue)
            suffix += 1
        }
        return candidate
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
