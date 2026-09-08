import Foundation
import SwiftUI

/// One entry in the export queue. Single-clip exports only -- Bulk Clip is
/// deliberately excluded from the queue (it already runs as its own
/// sequential batch within one wizard action, and mixing a second kind of
/// multi-file operation into this queue isn't worth the complexity it would
/// add here).
struct ExportJob: Identifiable {
    let id = UUID()
    let request: Clipper.Request
    let tools: FFmpegLocator.Tools
    /// A short, ready-to-display description of this export's settings, e.g.
    /// "1080p · 00:00:00–00:10:00" -- built once by the caller (which already
    /// knows resolution/range in context) rather than re-derived here.
    let settingsSummary: String
    var status: Status = .queued
    var resultURL: URL?

    enum Status: Equatable {
        case queued
        case running(fraction: Double)
        case done(summary: String)
        case failed(message: String)
        case cancelled

        /// Still queued or actively running, as opposed to having reached a
        /// terminal outcome -- the one definition of "active" everything
        /// touching the queue (the 10-job cap, Clear Queue, the list's
        /// active-jobs-first sort) reads from, instead of independently
        /// re-deriving the same partition in more than one place.
        var isActive: Bool {
            switch self {
            case .queued, .running: return true
            case .done, .failed, .cancelled: return false
            }
        }

        /// True only for `.queued` -- distinct from `isActive`, which also
        /// includes `.running`. Matters where "still waiting its turn,
        /// nothing to stop yet" specifically applies, e.g. removing a job
        /// outright vs. cancelling its in-flight process.
        var isQueued: Bool {
            if case .queued = self { return true }
            return false
        }

        /// Whether this status has a bigger detail view worth expanding
        /// into (`ExportQueueView`'s accordion) -- the one place this list
        /// needs naming, instead of three independent switches that all
        /// have to happen to agree.
        var isExpandable: Bool {
            switch self {
            case .running, .done: return true
            case .queued, .failed, .cancelled: return false
            }
        }
    }
}

/// Runs queued exports strictly one at a time -- deliberately not
/// concurrently, even though nothing in `Clipper`/`RunningExports` would
/// stop it, because overlapping hardware-encoder sessions risk exactly the
/// quality/thermal tradeoffs this feature was built to avoid. A singleton
/// (rather than an instance threaded through the view hierarchy, the way
/// `AppState` is) because it must survive `EditorView` being torn down when
/// the user picks a different file, and be reachable from
/// `AppDelegate.applicationShouldTerminate`, which has no view hierarchy at
/// all -- the same reachability need `RunningExports` already has, combined
/// with `AppState`'s `ObservableObject`/`@Published` pattern so queue UI can
/// react live instead of polling.
@MainActor
final class ExportQueue: ObservableObject {
    static let shared = ExportQueue()
    private init() {}

    /// "1 running + 9 queued", counted against active (queued/running) jobs
    /// only -- finished/failed/cancelled rows stay visible as history until
    /// cleared, but never block new work. A lifetime cap would make the
    /// queue useless after ten exports in a single session.
    static let maxActiveJobs = 10

    @Published private(set) var jobs: [ExportJob] = []

    private var runLoopTask: Task<Void, Never>?
    private var currentJobID: ExportJob.ID?
    private var currentJobTask: Task<Void, Never>?

    var activeCount: Int { jobs.filter { $0.status.isActive }.count }

    var canEnqueue: Bool { activeCount < Self.maxActiveJobs }

    /// Whether a job is actively exporting right now, as opposed to merely
    /// waiting its turn -- drives the "live" pulse on `QueueBubble`, which
    /// should never animate for a queue that's just sitting with pending
    /// work and nothing actually running yet.
    var isRunning: Bool {
        jobs.contains { if case .running = $0.status { return true }; return false }
    }

    @discardableResult
    func enqueue(_ job: ExportJob) -> Bool {
        guard canEnqueue else { return false }
        jobs.append(job)
        if runLoopTask == nil {
            runLoopTask = Task { await self.runLoop() }
        }
        return true
    }

    /// Cancels the running job (same `Task.cancel()` mechanism Force Stop
    /// already uses for a direct, non-queued export) or, for a still-queued
    /// job, just removes it -- there's no process to stop yet. The `&&
    /// isQueued` guard matters: `currentJobID` only clears to nil sometime
    /// after a job's terminal status is already published, so a tap that
    /// arrives in that gap (or just after) would otherwise fall into this
    /// branch and delete a job that's already done/failed/cancelled instead
    /// of being the no-op a stale tap should be.
    func cancel(jobID: ExportJob.ID) {
        if jobID == currentJobID {
            currentJobTask?.cancel()
        } else {
            jobs.removeAll { $0.id == jobID && $0.status.isQueued }
        }
    }

    /// Clears finished history (done/failed/cancelled) only. A still-queued
    /// or running job is left alone -- those are exactly the jobs the user
    /// is relying on the queue to still get to, so a single "Clear Queue"
    /// click must never make scheduled work disappear.
    func clearQueue() {
        jobs.removeAll { !$0.status.isActive }
    }

    /// Called from `AppDelegate` on quit: stops the run loop from starting
    /// another job. Actually killing whatever's still running is left to
    /// `RunningExports.terminateAll()`, unchanged -- this just closes the
    /// narrow race where the loop could advance to the next job in the
    /// instant before the app fully exits.
    func cancelAll() {
        currentJobTask?.cancel()
        runLoopTask?.cancel()
    }

    private func runLoop() async {
        // `!Task.isCancelled` is what makes `cancelAll()`'s `runLoopTask?.cancel()`
        // actually do something -- without checking it here, cancelling the
        // Task only sets a flag nobody reads, and the loop happily starts
        // the next queued job (registering a fresh process with
        // `RunningExports`) right after `AppDelegate` already ran
        // `terminateAll()` once, orphaning it past quit.
        while !Task.isCancelled, let next = jobs.first(where: { if case .queued = $0.status { return true }; return false }) {
            await run(next)
        }
        runLoopTask = nil
    }

    private func run(_ job: ExportJob) async {
        currentJobID = job.id
        updateStatus(job.id, .running(fraction: 0))

        let task = Task {
            do {
                let result = try await Clipper.export(job.request, tools: job.tools) { fraction in
                    Task { @MainActor in self.updateStatus(job.id, .running(fraction: fraction)) }
                }
                self.updateStatus(job.id, .done(summary: "Saved to \(result.outputURL.lastPathComponent)"))
                self.setResult(job.id, result.outputURL)
            } catch {
                self.finish(job.id, error: error)
            }
        }
        currentJobTask = task
        await task.value
        currentJobTask = nil
        currentJobID = nil
    }

    private func updateStatus(_ id: ExportJob.ID, _ status: ExportJob.Status) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        // A progress tick can still be in flight (each one hops to the main
        // actor via its own unordered `Task`) when the job's real, final
        // status lands -- ffmpeg's graceful shutdown after a Force Stop can
        // flush one more `out_time_us=` line before actually exiting, racing
        // the termination-triggered update with no guaranteed order between
        // them. Once a job is done/failed/cancelled, nothing should ever
        // move it back to .running.
        if case .running = status, !jobs[index].status.isActive { return }
        jobs[index].status = status
    }

    private func setResult(_ id: ExportJob.ID, _ url: URL) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].resultURL = url
    }

    /// A deliberate Force Stop surfaces as `.cancelled` (neutral) rather than
    /// `.failed` (alarming red).
    private func finish(_ id: ExportJob.ID, error: Error) {
        updateStatus(id, isCancellation(error) ? .cancelled : .failed(message: error.localizedDescription))
    }

    private func isCancellation(_ error: Error) -> Bool {
        if case Clipper.ExportError.cancelled = error { return true }
        return false
    }
}
