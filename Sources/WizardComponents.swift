import SwiftUI

/// Shared building blocks for the app's paged wizard (`EditorView`'s Single
/// Clip/Bulk Clip flow) and the Export Queue screen, which deliberately
/// share one visual language -- same dark theme, same slide transitions,
/// same progress/completed/stopped page shapes -- rather than each hand-
/// rolling its own copy. Centralizing them here means a design change to
/// any of these only needs to happen once.

/// The pill-shaped button style every labeled button in the app uses --
/// explicitly drawing a `Capsule()` (the same shape `QueueBubble` already
/// uses) rather than relying on the system `.bordered`/`.borderedProminent`
/// styles' own corner rounding, which varies by control size and macOS
/// version instead of reliably reading as a full capsule at every size this
/// app uses. Reads `configuration.role` so a `role: .destructive` button
/// (Force Stop, Clear Queue) renders red automatically, without every call
/// site needing its own `.tint(.red)`.
struct CapsuleButtonStyle: ButtonStyle {
    var prominent: Bool = false

    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(font)
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .background(Capsule().fill(fillColor(configuration)))
            .foregroundStyle(foregroundColor(configuration))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }

    private var height: CGFloat {
        switch controlSize {
        case .mini: return 20
        case .small: return 24
        case .large: return 34
        default: return 28
        }
    }

    private var horizontalPadding: CGFloat {
        switch controlSize {
        case .mini: return 8
        case .small: return 10
        case .large: return 18
        default: return 14
        }
    }

    private var font: Font {
        switch controlSize {
        case .mini, .small: return .caption
        case .large: return .body
        default: return .callout
        }
    }

    private func fillColor(_ configuration: Configuration) -> Color {
        guard isEnabled else { return Color.gray.opacity(0.12) }
        if configuration.role == .destructive { return .red }
        return prominent ? Color.accentColor : Color.gray.opacity(0.28)
    }

    private func foregroundColor(_ configuration: Configuration) -> Color {
        guard isEnabled else { return .secondary }
        if configuration.role == .destructive { return .white }
        return prominent ? .white : .primary
    }
}

extension ButtonStyle where Self == CapsuleButtonStyle {
    static var capsule: CapsuleButtonStyle { CapsuleButtonStyle() }
    static var capsuleProminent: CapsuleButtonStyle { CapsuleButtonStyle(prominent: true) }
}

/// The asymmetric slide transition used for pushing/popping wizard pages:
/// new content enters from the trailing edge and exits toward the leading
/// edge when moving forward, reversed when going back.
func wizardPageTransition(navigatingForward: Bool) -> AnyTransition {
    .asymmetric(
        insertion: .move(edge: navigatingForward ? .trailing : .leading).combined(with: .opacity),
        removal: .move(edge: navigatingForward ? .leading : .trailing).combined(with: .opacity)
    )
}

/// A small caption label stacked above its control.
struct LabeledWizardControl<Content: View>: View {
    let label: String
    let labelFont: Font
    @ViewBuilder let content: Content

    init(_ label: String, labelFont: Font = .caption, @ViewBuilder content: () -> Content) {
        self.label = label
        self.labelFont = labelFont
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(label).font(labelFont).foregroundStyle(.secondary)
            content
        }
    }
}

/// A big centered counter/percentage with a status line, a progress bar,
/// and a red "Force Stop". `counter` is the top display -- a plain
/// percentage for a single operation, or a "current of total" pair for a
/// batch -- since that's the one part that genuinely differs per caller.
struct WizardProgressPage<Counter: View>: View {
    @ViewBuilder let counter: Counter
    var statusText: String?
    let progress: Double
    let onForceStop: () -> Void

    var body: some View {
        content.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The content alone, sized to fit rather than stretched to fill a
    /// whole page -- reused directly by `ExportQueueView`'s expanded
    /// "running" card, which needs this same shape inline within a list
    /// row instead of duplicating it.
    var content: some View {
        VStack(spacing: 6) {
            counter
            if let statusText {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 18)
            }
            ProgressView(value: progress)
                .frame(maxWidth: 260)
                .padding(.bottom, 20)
            Button("Force Stop", role: .destructive, action: onForceStop)
                .buttonStyle(.capsule)
        }
    }
}

/// A green checkmark, a headline message, an optional secondary note, and
/// Reveal in Finder / Done buttons. `secondaryAction` is an optional extra
/// link below those two -- EditorView's completed page uses it for "Export
/// Another Version of This File"; nil hides it.
struct WizardCompletedPage: View {
    let message: String
    var note: String?
    let onReveal: () -> Void
    let onDone: () -> Void
    var secondaryActionLabel: String?
    var onSecondaryAction: (() -> Void)?
    /// Defaults match this page's own full-page look; `ExportQueueView`'s
    /// expanded "done" card passes smaller values to fit inline within a
    /// list row instead of hand-duplicating this entire layout at a
    /// different, previously-undocumented size.
    var iconSize: CGFloat = 44
    var messageFont: Font = .headline

    var body: some View {
        content.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var content: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: iconSize))
                .foregroundStyle(.green)
            Text(message)
                .font(messageFont)
                .foregroundStyle(.green)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if let note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            HStack(spacing: 10) {
                Button("Reveal in Finder", action: onReveal)
                    .buttonStyle(.capsule)
                Button("Done", action: onDone)
                    .buttonStyle(.capsuleProminent)
            }
            .padding(.top, 6)
            if let secondaryActionLabel, let onSecondaryAction {
                Button(action: onSecondaryAction) {
                    Text(secondaryActionLabel).underline()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// An orange warning triangle, red error text, and a "Go Back" button --
/// the shared shape of "something failed mid-flow, here's why, here's how
/// to recover" across both wizards.
struct WizardStoppedPage: View {
    let message: String
    let onGoBack: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button("Go Back", action: onGoBack)
                .buttonStyle(.capsuleProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A small pill showing how many jobs are in the export queue, tappable to
/// open it -- the queue's entry point on pages that already have a bottom
/// action row to dock it into. Deliberately not a floating overlay: every
/// corner tried collided with some page's own header or button, since this
/// app's pages already use their space tightly. Hides itself entirely when
/// `count` is 0 -- every call site used to have to remember to wrap this in
/// its own `if !queue.jobs.isEmpty { ... }`; now that's built in, so a
/// future call site can't forget the guard and render an empty "0" pill.
struct QueueBubble: View {
    let count: Int
    /// Pulses the icon while true -- signals "something is actually
    /// exporting right now", not just "there's stuff waiting its turn".
    var isRunning: Bool = false
    let onTap: () -> Void

    // Runs continuously from the moment this view appears, independent of
    // `isRunning` -- only the icon's color below is gated by that, so
    // there's no separate start/stop trigger to wire up for whenever
    // `isRunning` later flips true.
    @State private var pulse = false

    @ViewBuilder
    var body: some View {
        if count > 0 {
            bubble
        }
    }

    private var bubble: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                Image(systemName: "tray.full.fill")
                    .foregroundStyle(isRunning && pulse ? Color.black : Color.white)
                Text("\(count)")
            }
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 12)
            // Matches the height of the `.controlSize(.large)` buttons it
            // always sits next to -- the tighter caption-sized padding this
            // had before made it look noticeably smaller than its neighbors.
            .frame(height: 30)
            // A specific orange (#FF4D00, chosen after a live preview),
            // not the shared blue accent color every other button uses --
            // needs to read as its own thing at a glance.
            .background(Capsule().fill(Color(red: 1.0, green: 0.302, blue: 0.0)))
            .foregroundStyle(.white)
        }
        .onAppear {
            // Deferred by one run-loop tick: starting a `repeatForever`
            // animation directly inside `onAppear` doesn't reliably take
            // when the view's own insertion (this `if` branch turning true)
            // isn't itself wrapped in an animated transaction -- exactly
            // what happens when a job gets added to the queue while already
            // on the page showing this bubble. The animation only started
            // correctly before because leaving and returning to a page goes
            // through EditorView's own page-transition animation, which
            // gave `onAppear` a transaction to piggyback on; adding a job
            // in place has no such transaction, so `withAnimation` here was
            // silently swallowed into that "no animation" one instead of
            // starting its own repeating one. Hopping to the next run loop
            // tick guarantees this always starts fresh.
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
        }
        .buttonStyle(.plain)
    }
}
