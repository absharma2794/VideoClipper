import Foundation

/// Locates the `ffmpeg` and `ffprobe` executables on this machine.
///
/// A GUI app launched from Finder/Dock does NOT inherit the user's shell
/// `PATH` (no `.zshrc`/`.zprofile` gets sourced), which is the classic reason
/// a tool "works in Terminal but not in the app". We hardcode the two
/// standard Homebrew prefixes first, then fall back to whatever `PATH` the
/// process does have, so this app doesn't fall into that trap.
enum FFmpegLocator {

    struct Tools {
        let ffmpeg: String
        /// ffprobe is optional — VideoProbe falls back to parsing `ffmpeg -i` output if absent.
        let ffprobe: String?
    }

    private static let searchDirectories = [
        "/opt/homebrew/bin",   // Homebrew on Apple Silicon
        "/usr/local/bin",      // Homebrew on Intel
    ]

    /// Attempts to locate both tools. Returns nil only if `ffmpeg` itself can't be found —
    /// ffmpeg is mandatory, ffprobe is a nice-to-have.
    static func locate() -> Tools? {
        guard let ffmpeg = findExecutable(named: "ffmpeg") else { return nil }
        let ffprobe = findExecutable(named: "ffprobe")
        return Tools(ffmpeg: ffmpeg, ffprobe: ffprobe)
    }

    private static func findExecutable(named name: String) -> String? {
        var candidateDirectories = searchDirectories

        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            candidateDirectories.append(contentsOf: pathEnv.split(separator: ":").map(String.init))
        }

        let fileManager = FileManager.default
        for directory in candidateDirectories {
            let candidatePath = (directory as NSString).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidatePath) {
                if verify(candidatePath) {
                    return candidatePath
                }
            }
        }
        return nil
    }

    /// Confirms the candidate actually runs and reports a version (i.e. isn't a
    /// broken symlink or an unrelated file that happens to be named "ffmpeg").
    private static func verify(_ path: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-version"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
