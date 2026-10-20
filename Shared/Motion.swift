import AppKit
import SwiftUI

/// The one timing source for motion in Pnoe: one case per kind of moment, each with a duration
/// and a curve, and no animation at all under Reduce Motion (the end state is the same, it just
/// appears at once). Views call the helpers at the bottom of this file, never `withAnimation`,
/// `.animation`, `.transition` or `.symbolEffect` with their own numbers, so one search finds a
/// stray animation. Motion is native only: SF Symbol effects, transitions, one-pass animation.
///
/// Moment table (the effect each moment gets; `Motion` is the timing, the helpers are the effect):
///
/// | Moment | Effect | Helper |
/// | --- | --- | --- |
/// | A job starts (recording, transcribing, Run, a download) | Symbol replace; pulse on its symbol while it runs | `motionJobSymbol`, `motionSymbolReplace` |
/// | A job finishes | Replace with a check mark, one bounce; a transient chip fades out | `motionJobSymbol`, `motionFade` |
/// | A job fails (or a Playground run falls back) | Replace with the error symbol, one wiggle | `motionJobSymbol` |
/// | A take ends in the recorder (pasted, cancelled, failed) | The processing indicator is replaced by a check mark with one bounce, or the error symbol with one wiggle, for `Motion.outcomeHold` | `motionBounce`, `motionWiggle`, `motionFade` |
/// | A control changes state on a click (toggle, eye, media pausing) | Symbol replace, magic where the two symbols share a shape | `motionSymbolReplace` |
/// | A value is copied or saved | Copy → check mark, back after about 1 s | `Motion.copiedHold` |
/// | A panel opens or closes | Fade with a small move from its edge | `motionPanel` |
/// | A row or section expands | Chevron rotates, content fades in | `Motion.disclosure` |
/// | A row is hidden or shown | Eye replace; the row fades, its layout stays | `motionSymbolReplace`, `motionFade` |
/// | A picker or toggle changes | The control's own motion; the dependent value cross-fades | `Motion.change` |
/// | A screen or stage changes (onboarding, history detail) | Cross-fade | `Motion.screen` |
/// | A pointer enters a clickable control or row | About 10 % fill on the control itself, no size jump | `motionHover` |
/// | A pointer rests on a decorative element that turns while it is over it | Turns while the pointer is over it, eases to a stop when it leaves | `MotionTurning` |
///
/// Timing: at most 200 ms for any state change (hover 120, disclosure and copy 150, symbol
/// replace 180, panel, finish, failure, reveal and screen 200). A loop (pulse, spin) runs only
/// while its job runs: gate it on the running flag, never on `true`. A bounce or wiggle plays once.
enum Motion: CaseIterable, Sendable {
    /// A pointer enters or leaves a control or row, a drop target lights.
    case hover
    /// A control is pressed.
    case press
    /// A row or section expands or collapses.
    case disclosure
    /// A value is copied or saved and the control shows a check mark.
    case copy
    /// A symbol is swapped for another.
    case symbolReplace
    /// A picker or toggle changes the value that depends on it.
    case change
    /// A row, chip or hint appears or goes away.
    case reveal
    /// A panel, popover card or recorder pill opens, closes or resizes.
    case panel
    /// A job finishes (the check mark bounces).
    case finish
    /// A job fails (the error symbol wiggles).
    case failure
    /// A whole screen or stage changes.
    case screen
    /// A progress value moves; data, so short and linear.
    case progress

    enum Curve: Equatable, Sendable {
        case easeInOut
        case easeOut
        case linear
    }

    /// Seconds, before Reduce Motion.
    var baseDuration: TimeInterval {
        switch self {
        case .hover, .press: return 0.12
        case .disclosure, .copy, .change: return 0.15
        case .symbolReplace: return 0.18
        case .reveal, .panel, .finish, .failure, .screen: return 0.2
        case .progress: return 0.1
        }
    }

    var curve: Curve {
        switch self {
        case .hover, .press, .reveal, .finish, .failure: return .easeOut
        case .disclosure, .copy, .symbolReplace, .change, .panel, .screen: return .easeInOut
        case .progress: return .linear
        }
    }

    /// The longest any state change takes, in seconds.
    static let longestDuration: TimeInterval = 0.2

    /// How long a copy or save keeps its check mark before the control goes back.
    static let copiedHold: TimeInterval = 1.0

    /// How long the recorder keeps the check mark or the error symbol that ends a take before it
    /// hides. Short on purpose: nobody waits for it, and a new recording replaces it at once.
    static let outcomeHold: TimeInterval = 0.6

    /// The system Reduce Motion setting.
    static var systemReducesMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    func duration(reduceMotion: Bool = Motion.systemReducesMotion) -> TimeInterval {
        reduceMotion ? 0 : baseDuration
    }

    /// The animation for this moment; `nil` under Reduce Motion, so the change is immediate.
    func animation(reduceMotion: Bool = Motion.systemReducesMotion) -> Animation? {
        if reduceMotion { return nil }
        switch curve {
        case .easeInOut: return .easeInOut(duration: baseDuration)
        case .easeOut: return .easeOut(duration: baseDuration)
        case .linear: return .linear(duration: baseDuration)
        }
    }

    /// `withAnimation` for a moment.
    @discardableResult
    static func animate<Result>(
        _ moment: Motion, reduceMotion: Bool = Motion.systemReducesMotion, _ body: () throws -> Result
    ) rethrows -> Result {
        try withAnimation(moment.animation(reduceMotion: reduceMotion), body)
    }

    /// The animation of a loop (spinner, pulse): runs only while `isActive`, and never under
    /// Reduce Motion.
    static func loop(
        period: TimeInterval, isActive: Bool, reduceMotion: Bool = Motion.systemReducesMotion
    ) -> Animation? {
        loopRuns(isActive: isActive, reduceMotion: reduceMotion)
            ? .linear(duration: period).repeatForever(autoreverses: false) : nil
    }

    static func loopRuns(isActive: Bool, reduceMotion: Bool) -> Bool {
        isActive && !reduceMotion
    }

    /// Whether an element that turns while the pointer is over it is turning: only while the
    /// pointer is over it, and never under Reduce Motion (it stays still).
    static func hoverTurns(pointerInside: Bool, reduceMotion: Bool) -> Bool {
        loopRuns(isActive: pointerInside, reduceMotion: reduceMotion)
    }

    /// The AppKit timing function of this moment, for window and layer animation.
    var timingFunction: CAMediaTimingFunction {
        switch curve {
        case .easeInOut: return CAMediaTimingFunction(name: .easeInEaseOut)
        case .easeOut: return CAMediaTimingFunction(name: .easeOut)
        case .linear: return CAMediaTimingFunction(name: .linear)
        }
    }

    /// `NSAnimationContext.runAnimationGroup` with the duration and curve of a moment (a duration
    /// of zero under Reduce Motion, so the change is immediate and the completion still runs).
    @MainActor
    static func animateWindow(
        _ moment: Motion, reduceMotion: Bool = Motion.systemReducesMotion,
        changes: @escaping (NSAnimationContext) -> Void, completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = moment.duration(reduceMotion: reduceMotion)
                context.timingFunction = moment.timingFunction
                changes(context)
            },
            completionHandler: completion.map { done in
                { @Sendable in MainActor.assumeIsolated { done() } }
            })
    }
}

// MARK: - State → effect table

/// Where a job is: the states the symbol effects follow.
enum MotionPhase: Equatable, Sendable {
    case idle
    case running
    case finished
    case failed
}

/// The SF Symbol effect a phase plays.
enum MotionSymbolEffect: Equatable, Sendable {
    case none
    /// Loops while the job runs.
    case pulse
    /// Plays once when the job finishes.
    case bounce
    /// Plays once when the job fails.
    case wiggle
}

extension Motion {
    /// The effect for a phase. A loop only while `running`; one pass for a finish or a failure;
    /// nothing at idle and nothing under Reduce Motion.
    static func symbolEffect(for phase: MotionPhase, reduceMotion: Bool = Motion.systemReducesMotion)
        -> MotionSymbolEffect
    {
        if reduceMotion { return .none }
        switch phase {
        case .idle: return .none
        case .running: return .pulse
        case .finished: return .bounce
        case .failed: return .wiggle
        }
    }

    /// The symbol a job shows: its own while idle or running, a check mark when it finished, the
    /// error symbol when it failed.
    static func symbol(for phase: MotionPhase, idle: String, running: String? = nil) -> String {
        switch phase {
        case .idle: return idle
        case .running: return running ?? idle
        case .finished: return "checkmark"
        case .failed: return "exclamationmark.triangle"
        }
    }

    /// The symbol of a copy or save control.
    static func copySymbol(copied: Bool, idle: String = "doc.on.doc") -> String {
        copied ? "checkmark" : idle
    }

    /// The symbol of an on/off control whose two symbols share a shape (eye and eye.slash).
    static func toggleSymbol(isOn: Bool, on: String, off: String) -> String {
        isOn ? on : off
    }
}

// MARK: - Hold

/// The check mark of a copy or save: on for `Motion.copiedHold`, then back. A new `hold` restarts the
/// wait (cancelling the earlier one), so a second copy keeps its check for a full hold, and `cancel`
/// (a view going away) stops the pending reset.
@MainActor
final class MotionHold: ObservableObject {
    @Published private(set) var isHeld = false
    private var reset: Task<Void, Never>?

    func hold(
        for duration: TimeInterval = Motion.copiedHold, reduceMotion: Bool = Motion.systemReducesMotion
    ) {
        reset?.cancel()
        Motion.animate(.copy, reduceMotion: reduceMotion) { isHeld = true }
        reset = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            Motion.animate(.copy, reduceMotion: reduceMotion) { self.isHeld = false }
            self.reset = nil
        }
    }

    func cancel() {
        reset?.cancel()
        reset = nil
        isHeld = false
    }
}

// MARK: - Transitions

extension AnyTransition {
    /// A row, chip or hint appearing or going away.
    static var motionFade: AnyTransition { .opacity }

    /// A panel or a disclosed block: fades and moves a little from its edge.
    static func motionPanel(edge: Edge = .top) -> AnyTransition {
        .opacity.combined(with: .move(edge: edge))
    }
}

// MARK: - View helpers

extension View {
    /// Animates the changes of `value` with the timing of `moment` (none under Reduce Motion).
    func motion<Value: Equatable>(_ moment: Motion, value: Value) -> some View {
        modifier(MotionValueModifier(moment: moment, value: value))
    }

    /// A row, chip or hint fades in and out.
    func motionFade() -> some View {
        transition(.motionFade)
    }

    /// A panel or a disclosed block fades in with a small move from `edge`.
    func motionPanel(edge: Edge = .top) -> some View {
        transition(.motionPanel(edge: edge))
    }

    /// A symbol that changes into another one (`value` is whatever picks the symbol) replaces in
    /// place; two symbols that share a shape (eye and eye.slash) morph.
    func motionSymbolReplace<Value: Equatable>(value: Value) -> some View {
        modifier(MotionSymbolReplaceModifier(value: value))
    }

    /// The symbol effects of a job: pulses while it runs, bounces once when it finishes,
    /// wiggles once when it fails.
    func motionJobSymbol(_ phase: MotionPhase) -> some View {
        modifier(MotionJobSymbolModifier(phase: phase))
    }

    /// A one-pass bounce each time `condition` turns true, and once when the view appears with it
    /// already true (a chip that shows up because its job just finished).
    func motionBounce(when condition: Bool) -> some View {
        modifier(MotionOnceModifier(effect: .bounce, condition: condition))
    }

    /// A one-pass wiggle each time `condition` turns true, and once when the view appears with it
    /// already true.
    func motionWiggle(when condition: Bool) -> some View {
        modifier(MotionOnceModifier(effect: .wiggle, condition: condition))
    }

    /// A rotation that turns once per `period` while `isActive` and rests at zero otherwise.
    func motionSpin(isActive: Bool, period: TimeInterval = 1) -> some View {
        modifier(MotionSpinModifier(isActive: isActive, period: period))
    }

    /// A pointer highlight: about a 10 % fill over the view, faded in, with no size jump. Put it
    /// on the clickable control itself, outside the button, not inside its label. A disabled
    /// control shows none, and so does one that is `suppressed` (already selected, or off); the
    /// highlight clears when the control is disabled or goes away.
    /// `outset` grows the highlight past the view's bounds (drawing only, no layout change), for rows
    /// whose text would otherwise touch the edge of the fill.
    func motionHover(cornerRadius: CGFloat = 8, outset: CGFloat = 0, suppressed: Bool = false) -> some View {
        modifier(MotionHoverModifier(cornerRadius: cornerRadius, outset: outset, suppressed: suppressed))
    }
}

private struct MotionValueModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let moment: Motion
    let value: Value

    func body(content: Content) -> some View {
        content.animation(moment.animation(reduceMotion: reduceMotion), value: value)
    }
}

private struct MotionSymbolReplaceModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: Value

    func body(content: Content) -> some View {
        content
            .contentTransition(.symbolEffect(.replace.magic(fallback: .replace)))
            .animation(Motion.symbolReplace.animation(reduceMotion: reduceMotion), value: value)
    }
}

private struct MotionJobSymbolModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let phase: MotionPhase
    @State private var finishes = 0
    @State private var failures = 0

    func body(content: Content) -> some View {
        content
            .contentTransition(.symbolEffect(.replace.magic(fallback: .replace)))
            .animation(Motion.symbolReplace.animation(reduceMotion: reduceMotion), value: phase)
            .symbolEffect(
                .pulse, options: .repeating,
                isActive: Motion.symbolEffect(for: phase, reduceMotion: reduceMotion) == .pulse
            )
            .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion ? 0 : finishes)
            .symbolEffect(.wiggle, options: .nonRepeating, value: reduceMotion ? 0 : failures)
            .onChange(of: phase) { _, newPhase in
                if newPhase == .finished { finishes += 1 }
                if newPhase == .failed { failures += 1 }
            }
    }
}

private struct MotionOnceModifier: ViewModifier {
    enum Effect { case bounce, wiggle }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let effect: Effect
    let condition: Bool
    @State private var passes = 0

    func body(content: Content) -> some View {
        switch effect {
        case .bounce:
            content
                .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion ? 0 : passes)
                .onChange(of: condition) { _, now in if now { passes += 1 } }
                .onAppear { if condition { passes += 1 } }
        case .wiggle:
            content
                .symbolEffect(.wiggle, options: .nonRepeating, value: reduceMotion ? 0 : passes)
                .onChange(of: condition) { _, now in if now { passes += 1 } }
                .onAppear { if condition { passes += 1 } }
        }
    }
}

private struct MotionSpinModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isActive: Bool
    let period: TimeInterval
    @State private var angle = 0.0

    private var runs: Bool { Motion.loopRuns(isActive: isActive, reduceMotion: reduceMotion) }

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(angle))
            .onAppear(perform: update)
            .onChange(of: runs) { _, _ in update() }
    }

    private func update() {
        if runs {
            withAnimation(Motion.loop(period: period, isActive: true, reduceMotion: false)) { angle = 360 }
        } else {
            // A zero-length animation replaces the repeating one, so the spinner stops.
            withAnimation(.linear(duration: 0)) { angle = 0 }
        }
    }
}

// MARK: - Turning

/// The angle of something that turns at a steady speed while it is active and eases to a stop when it
/// is not (and eases back up to speed when it turns again), as a pure function of time. The speed
/// changes at a constant rate over `rampDuration`, so the angle never jumps. No view, no clock: the
/// caller passes the time.
struct MotionTurn: Equatable, Sendable {
    /// Degrees per second at full speed.
    let speed: Double
    /// Seconds to go from rest to full speed, or back.
    let rampDuration: TimeInterval

    private var angle0: Double
    private var speed0 = 0.0
    private var time0 = 0.0
    private var target = 0.0

    init(rest angle: Double = 0, period: TimeInterval, rampDuration: TimeInterval = Motion.hover.baseDuration) {
        speed = 360 / period
        self.rampDuration = rampDuration
        angle0 = angle
    }

    /// The angle at `time` (seconds, any fixed origin), in degrees, not wrapped.
    func angle(at time: TimeInterval) -> Double {
        let elapsed = max(0, time - time0)
        let change = target - speed0
        let rampTime = rampDuration > 0 && speed > 0 ? abs(change) / speed * rampDuration : 0
        if elapsed >= rampTime {
            let rampAngle = rampTime > 0 ? speed0 * rampTime + 0.5 * change * rampTime : 0
            return angle0 + rampAngle + target * (elapsed - rampTime)
        }
        return angle0 + speed0 * elapsed + 0.5 * (change / rampTime) * elapsed * elapsed
    }

    /// The speed at `time`, degrees per second.
    func currentSpeed(at time: TimeInterval) -> Double {
        let elapsed = max(0, time - time0)
        let change = target - speed0
        let rampTime = rampDuration > 0 && speed > 0 ? abs(change) / speed * rampDuration : 0
        return elapsed >= rampTime ? target : speed0 + change * (elapsed / rampTime)
    }

    /// Whether the angle still moves at `time`.
    func isMoving(at time: TimeInterval) -> Bool {
        target != 0 || currentSpeed(at: time) != 0
    }

    /// Stops at once, where the angle is at `time` (Reduce Motion).
    mutating func stop(at time: TimeInterval) {
        angle0 = angle(at: time)
        speed0 = 0
        time0 = time
        target = 0
    }

    /// Starts turning (`true`) or eases to a stop (`false`) from where the angle is at `time`.
    mutating func setTurning(_ turning: Bool, at time: TimeInterval) {
        let newTarget = turning ? speed : 0
        guard newTarget != target else { return }
        let now = angle(at: time)
        let nowSpeed = currentSpeed(at: time)
        angle0 = now
        speed0 = nowSpeed
        time0 = time
        target = newTarget
    }
}

/// A view that hands its content an angle which turns while `isActive` and eases to a stop when it
/// goes false; it rests at `rest` degrees. Gate `isActive` on the real state (a pointer over the
/// view) and it never loops on its own. Redraws only while the angle moves, and never turns under
/// Reduce Motion.
struct MotionTurning<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isActive: Bool
    let period: TimeInterval
    let content: (Angle) -> Content
    @State private var turn: MotionTurn
    @State private var redraws = false
    @State private var settle: Task<Void, Never>?

    init(
        isActive: Bool, period: TimeInterval = 2.6, rest: Angle = .zero,
        @ViewBuilder content: @escaping (Angle) -> Content
    ) {
        self.isActive = isActive
        self.period = period
        self.content = content
        _turn = State(initialValue: MotionTurn(rest: rest.degrees, period: period))
    }

    private var turns: Bool { Motion.hoverTurns(pointerInside: isActive, reduceMotion: reduceMotion) }

    var body: some View {
        TimelineView(.animation(paused: !redraws)) { context in
            content(.degrees(turn.angle(at: context.date.timeIntervalSinceReferenceDate)))
        }
        .onChange(of: turns) { _, _ in update() }
        .onDisappear {
            settle?.cancel()
            turn.stop(at: Date.timeIntervalSinceReferenceDate)
            redraws = false
        }
    }

    private func update() {
        let now = Date.timeIntervalSinceReferenceDate
        settle?.cancel()
        if reduceMotion {
            // Nothing turns under Reduce Motion, so there is no ease: the angle stops where it is.
            turn.stop(at: now)
            redraws = false
            return
        }
        turn.setTurning(turns, at: now)
        if turns {
            redraws = true
        } else {
            settle = Task {
                try? await Task.sleep(nanoseconds: UInt64((turn.rampDuration + 0.05) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                redraws = false
            }
        }
    }
}

extension EnvironmentValues {
    /// Forces the pointer highlight on or off, for offscreen renders that cannot move a pointer.
    /// `nil` (the default) follows the real pointer.
    @Entry var motionHoverOverride: Bool? = nil
}

/// Whether a control shows its pointer highlight: the pointer is over it, it is enabled and it is
/// not already selected.
extension Motion {
    static func hoverIsLit(pointerInside: Bool, isEnabled: Bool, suppressed: Bool) -> Bool {
        pointerInside && isEnabled && !suppressed
    }
}

private struct MotionHoverModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.motionHoverOverride) private var hoverOverride
    let cornerRadius: CGFloat
    let outset: CGFloat
    let suppressed: Bool
    @State private var isHovered = false

    private var isLit: Bool {
        Motion.hoverIsLit(pointerInside: hoverOverride ?? isHovered, isEnabled: isEnabled, suppressed: suppressed)
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(isLit ? 0.1 : 0))
                    .padding(-outset)
                    .allowsHitTesting(false)
            }
            .onHover { isHovered = $0 }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { isHovered = false }
            }
            .onDisappear { isHovered = false }
            .animation(Motion.hover.animation(reduceMotion: reduceMotion), value: isLit)
    }
}
