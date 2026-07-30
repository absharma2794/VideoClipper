import Foundation

/// Pure value logic for parsing and formatting timecodes.
/// No UI, no process spawning — safe to unit test in isolation.
enum Timecode {

    /// Parses a user-entered timecode into seconds.
    ///
    /// Accepted forms:
    ///   - `HH:MM:SS` or `HH:MM:SS.mmm`
    ///   - `MM:SS` or `MM:SS.mmm`
    ///   - `SS` or `SS.mmm`
    ///
    /// Returns `nil` for anything unparseable, negative, or with an
    /// out-of-range minutes/seconds component (e.g. "00:99:00").
    static func parse(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 1 && parts.count <= 3 else { return nil }

        // Every part must be a non-negative number; only the last part may be fractional.
        var components: [Double] = []
        for (index, part) in parts.enumerated() {
            guard let value = Double(part), value >= 0 else { return nil }
            // Only the final (seconds) component may have a fractional part.
            if index != parts.count - 1, value != value.rounded(.down) {
                return nil
            }
            components.append(value)
        }

        let seconds: Double
        let minutes: Double
        let hours: Double

        switch components.count {
        case 1:
            hours = 0; minutes = 0; seconds = components[0]
        case 2:
            hours = 0; minutes = components[0]; seconds = components[1]
        case 3:
            hours = components[0]; minutes = components[1]; seconds = components[2]
        default:
            return nil
        }

        // Reject out-of-range minutes/seconds so "00:99:00" isn't silently accepted.
        if components.count >= 2, minutes >= 60 { return nil }
        if seconds >= 60 { return nil }

        return hours * 3600 + minutes * 60 + seconds
    }

    /// Formats seconds as a zero-padded `HH:MM:SS` string (no fractional part).
    static func format(_ totalSeconds: Double) -> String {
        let clamped = max(0, totalSeconds)
        let wholeSeconds = Int(clamped.rounded())
        let hours = wholeSeconds / 3600
        let minutes = (wholeSeconds % 3600) / 60
        let seconds = wholeSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    /// A filesystem/display-safe rendering, e.g. "00-01-30", for use in output filenames.
    static func filenameSafe(_ totalSeconds: Double) -> String {
        format(totalSeconds).replacingOccurrences(of: ":", with: "-")
    }
}
