import SwiftUI
import AppKit

/// The Export Queue screen: up to 20 jobs (1 running + 19 waiting), reachable
/// from the `QueueBubble` docked into every other screen's own layout.
/// Accordion-style: tapping a Running or Done row's filename/status line expands it
/// into a bigger detail card right in its own place in the list -- not
/// pulled out to a fixed slot at the top -- so a finished job sorted near
/// the bottom expands there too, not back at the top where you'd have to
/// go find it again. Tapping that card's own header (or, for a finished
/// job, its "Done" button) collapses it back. Queued/Failed/Cancelled rows
/// don't expand -- their compact row already shows everything relevant (an
/// error message, or just a Remove/retry action).
///
/// The list is the first genuinely scrolling content in the app -- every
/// other page centers a fixed, known-size block, but a queue's row count is
/// unbounded over a session. Rows stay deliberately light -- plain
/// underlined links and icon buttons -- rather than a row of boxed buttons,
/// which read as much heavier than anything else in the app.
struct ExportQueueView: View {
    @ObservedObject private var queue = ExportQueue.shared
    let onClose: () -> Void
    let onExportAnotherVersion: (ExportJob) -> Void

    @State private var expandedJobID: ExportJob.ID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onClose) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                Text("Export Queue").font(.headline)
                Spacer()
                Button("Clear Queue", role: .destructive) { queue.clearQueue() }
                    .buttonStyle(.capsule)
                    .controlSize(.small)
                    .disabled(!canClear)
            }
            .padding(16)

            if queue.jobs.isEmpty {
                Spacer(minLength: 0)
                Text("No exports queued")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                List {
                    ForEach(sortedJobs) { job in
                        if job.id == expandedJob?.id {
                            expandedCard(for: job)
                        } else {
                            row(for: job)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        // Opaque fill is now load-bearing, not cosmetic: ContentView layers
        // this on top of whichever wizard is underneath (in a ZStack, so
        // that wizard's own state survives a queue visit instead of being
        // torn down) rather than swapping it in as the Group's only child,
        // so without this, gaps between this view's own elements would let
        // the page behind it show through.
        .background(Color(NSColor.windowBackgroundColor))
        .transition(wizardPageTransition(navigatingForward: true))
    }

    /// Active (Queued/Running) jobs always sort above finished
    /// (Done/Failed/Cancelled) ones, each group keeping its own relative
    /// order -- since execution is strictly one-at-a-time and FIFO, that
    /// relative order already matches both enqueue order and (for the
    /// finished group) completion order, so no separate timestamp is needed.
    private var sortedJobs: [ExportJob] {
        queue.jobs.filter { $0.status.isActive } + queue.jobs.filter { !$0.status.isActive }
    }

    /// Only Running and Done jobs have a bigger detail worth expanding into
    /// -- if the expanded job's status moved on to something else (e.g. it
    /// was Force-Stopped while expanded, becoming Cancelled), `isExpandable`
    /// simply stops matching and the card disappears on its own, no
    /// explicit collapse needed.
    private var expandedJob: ExportJob? {
        guard let expandedJobID, let job = queue.jobs.first(where: { $0.id == expandedJobID }), job.status.isExpandable else { return nil }
        return job
    }

    /// Only finished (done/failed/cancelled) rows are ever removed by
    /// "Clear Queue" -- disabled entirely when there's none to clear, so it
    /// never reads as a way to touch scheduled work.
    private var canClear: Bool {
        queue.jobs.contains { !$0.status.isActive }
    }

    // MARK: - Compact row

    @ViewBuilder
    private func row(for job: ExportJob) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            header(for: job, expanded: false)
            HStack {
                Text(job.settingsSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                actions(for: job)
            }
            if case .running(let fraction) = job.status {
                ProgressView(value: fraction)
            }
            if case .failed(let message) = job.status {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 6)
    }

    private func headerContent(for job: ExportJob) -> some View {
        HStack {
            Text(job.request.sourceURL.lastPathComponent)
                .font(.subheadline)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            statusText(job.status)
        }
    }

    /// `expanded: false` (in the compact list) taps to expand; `expanded:
    /// true` (on the card itself) taps to collapse -- the direction is
    /// implied entirely by where this is called from, not by inspecting
    /// current state, since a compact row is by definition never the one
    /// already expanded.
    @ViewBuilder
    private func header(for job: ExportJob, expanded: Bool) -> some View {
        if expanded {
            Button { expandedJobID = nil } label: { headerContent(for: job) }
                .buttonStyle(.plain)
        } else if job.status.isExpandable {
            Button { expandedJobID = job.id } label: { headerContent(for: job) }
                .buttonStyle(.plain)
        } else {
            headerContent(for: job)
        }
    }

    @ViewBuilder
    private func actions(for job: ExportJob) -> some View {
        switch job.status {
        case .queued:
            Button("Remove") { queue.cancel(jobID: job.id) }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .underline()
        case .running:
            Button("Force Stop") { queue.cancel(jobID: job.id) }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.red)
                .underline()
        case .done:
            HStack(spacing: 12) {
                Button { onExportAnotherVersion(job) } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .help("Export Another Version of This File")
                Button { reveal(job) } label: {
                    Image(systemName: "folder")
                }
                .help("Reveal in Finder")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        case .failed, .cancelled:
            Button { onExportAnotherVersion(job) } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Export Another Version of This File")
        }
    }

    private func statusText(_ status: ExportJob.Status) -> some View {
        let (text, color): (String, Color) = {
            switch status {
            case .queued: return ("Queued", .secondary)
            case .running: return ("Running", .blue)
            case .done: return ("Done", .green)
            case .failed: return ("Failed", .red)
            case .cancelled: return ("Cancelled", .orange)
            }
        }()
        return Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
    }

    private func reveal(_ job: ExportJob) {
        guard let url = job.resultURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Expanded card

    @ViewBuilder
    private func expandedCard(for job: ExportJob) -> some View {
        VStack(spacing: 14) {
            header(for: job, expanded: true)
            switch job.status {
            case .running(let fraction):
                expandedRunningDetail(job: job, fraction: fraction)
            case .done(let summary):
                expandedDoneDetail(job: job, summary: summary)
            case .queued, .failed, .cancelled:
                EmptyView() // unreachable -- `expandedJob` only returns running/done
            }
        }
        .padding(16)
    }

    private func expandedRunningDetail(job: ExportJob, fraction: Double) -> some View {
        WizardProgressPage(
            counter: {
                Text("\(Int(fraction * 100))%")
                    .font(.system(size: 40, weight: .thin, design: .rounded))
                    .monospacedDigit()
            },
            progress: fraction,
            onForceStop: { queue.cancel(jobID: job.id) }
        )
        .content
        .frame(maxWidth: .infinity)
    }

    private func expandedDoneDetail(job: ExportJob, summary: String) -> some View {
        WizardCompletedPage(
            message: summary,
            onReveal: { reveal(job) },
            onDone: { expandedJobID = nil },
            secondaryActionLabel: "Export Another Version of This File",
            onSecondaryAction: { onExportAnotherVersion(job) },
            iconSize: 32,
            messageFont: .subheadline
        )
        .content
        .frame(maxWidth: .infinity)
    }
}
