import SwiftUI

// Presentational parts of the recording indicator: theme, buttons, level meter, live
// transcript line. They take plain values, so the unit tests can render them offscreen.

/// Colors the recorder components draw with. `ink` replaces the white the recorder used on its
/// black background: it is white on the dark and translucent themes and near-black on the light one.
struct RecorderPalette: Equatable {
    let ink: Color
    let inkInverse: Color
    let border: Color
    /// `nil` leaves the system scheme alone, which is what the recorder always did in dark.
    let colorScheme: ColorScheme?

    static let dark = RecorderPalette(
        ink: .white, inkInverse: .black, border: .clear, colorScheme: nil)
    static let translucent = RecorderPalette(
        ink: .white, inkInverse: .black, border: Color.white.opacity(0.16), colorScheme: .dark)
    static let light = RecorderPalette(
        ink: Color(white: 0.1), inkInverse: .white, border: Color.black.opacity(0.14), colorScheme: .light)
}

extension RecorderTheme {
    var palette: RecorderPalette {
        switch self {
        case .dark: return .dark
        case .translucent: return .translucent
        case .light: return .light
        }
    }
}

private struct RecorderPaletteKey: EnvironmentKey {
    static let defaultValue = RecorderPalette.dark
}

extension EnvironmentValues {
    var recorderPalette: RecorderPalette {
        get { self[RecorderPaletteKey.self] }
        set { self[RecorderPaletteKey.self] = newValue }
    }
}

/// The fill behind a recorder, per theme. The dark theme is the plain black the recorder
/// always had.
struct RecorderThemeBackground: View {
    let theme: RecorderTheme

    var body: some View {
        switch theme {
        case .dark:
            Color.black
        case .translucent:
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Color.black.opacity(0.45)
            }
        case .light:
            Color(white: 0.97)
        }
    }
}

extension View {
    @ViewBuilder
    fileprivate func applyingColorScheme(_ scheme: ColorScheme?) -> some View {
        if let scheme {
            environment(\.colorScheme, scheme)
        } else {
            self
        }
    }

    /// Applies a recorder theme: palette for the components, a matching color scheme for system
    /// controls, then the background clipped to `shape` with the theme's hairline border.
    func recorderThemed<S: Shape>(_ theme: RecorderTheme, shape: S) -> some View {
        let palette = theme.palette
        return self
            .environment(\.recorderPalette, palette)
            .applyingColorScheme(palette.colorScheme)
            .background(RecorderThemeBackground(theme: theme))
            .clipShape(shape)
            .overlay(shape.stroke(palette.border, lineWidth: 0.5))
    }
}

struct NotchShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    init(topCornerRadius: CGFloat = 6, bottomCornerRadius: CGFloat = 20) {
        self.topCornerRadius = topCornerRadius
        self.bottomCornerRadius = bottomCornerRadius
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()

        // Top-left: flat against physical notch, small outward curve
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY + topCornerRadius),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY)
        )

        // Left side down to bottom-left corner
        path.addLine(to: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY - bottomCornerRadius))

        // Bottom-left corner: rounded outward
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius + bottomCornerRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY)
        )

        // Bottom edge
        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius - bottomCornerRadius, y: rect.maxY))

        // Bottom-right corner: rounded outward
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY - bottomCornerRadius),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY)
        )

        // Right side up to top-right corner
        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY + topCornerRadius))

        // Top-right: flat against physical notch, small outward curve
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY)
        )

        // Top edge back to start
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))

        return path
    }
}

/// The live input level while recording: Bars or Wave, drawn from the recorder's level history
/// with one `Canvas`. With Reduce Motion on it is a single level bar that does not scroll.
struct AudioVisualizer: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    let levelHistoryProvider: () -> LevelHistory
    let color: Color
    let display: RecorderLevelDisplay
    /// Replaces the system Reduce Motion setting. The environment value cannot be set from outside,
    /// so offscreen renders use this to draw the Reduce Motion form.
    let reduceMotionOverride: Bool?

    // 30 bars come to 74 pt, the width the Notch layout leaves beside its edge padding.
    static let barWidth: CGFloat = 1.5
    static let barSpacing: CGFloat = 1
    static let minHeight: CGFloat = 4
    static let maxHeight: CGFloat = 28
    static let width = CGFloat(RecorderLevelMetrics.barCount) * (barWidth + barSpacing) - barSpacing

    init(
        levelHistoryProvider: @escaping () -> LevelHistory,
        color: Color,
        display: RecorderLevelDisplay = .bars,
        reduceMotionOverride: Bool? = nil
    ) {
        self.levelHistoryProvider = levelHistoryProvider
        self.color = color
        self.display = display
        self.reduceMotionOverride = reduceMotionOverride
    }

    private var reducesMotion: Bool { reduceMotionOverride ?? systemReduceMotion }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / RecorderLevelMetrics.samplesPerSecond)) { _ in
            let history = levelHistoryProvider()
            Canvas { context, size in
                if reducesMotion {
                    Self.drawMeter(history: history, color: color, in: &context, size: size)
                } else {
                    switch display {
                    case .bars: Self.drawBars(history: history, color: color, in: &context, size: size)
                    case .wave: Self.drawWave(history: history, color: color, in: &context, size: size)
                    }
                }
            }
            .frame(width: Self.width, height: Self.maxHeight)
        }
        .accessibilityHidden(true)
    }

    private static func drawBars(
        history: LevelHistory, color: Color, in context: inout GraphicsContext, size: CGSize
    ) {
        let heights = LevelDisplayGeometry.barHeights(
            history: history, barCount: RecorderLevelMetrics.barCount, minHeight: minHeight, maxHeight: maxHeight)
        for (index, height) in heights.enumerated() {
            let rect = CGRect(
                x: CGFloat(index) * (barWidth + barSpacing), y: (size.height - height) / 2,
                width: barWidth, height: height)
            context.fill(
                Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(color.opacity(0.85)))
        }
    }

    private static func drawWave(
        history: LevelHistory, color: Color, in context: inout GraphicsContext, size: CGSize
    ) {
        let halves = LevelDisplayGeometry.waveHalfHeights(
            history: history, pointCount: RecorderLevelMetrics.waveSampleCount,
            minHalfHeight: minHeight / 2, maxHalfHeight: maxHeight / 2)
        guard halves.count > 1 else { return }
        let midY = size.height / 2
        let step = size.width / CGFloat(halves.count - 1)
        let top = halves.enumerated().map { CGPoint(x: CGFloat($0.offset) * step, y: midY - $0.element) }
        let bottom = halves.enumerated().map { CGPoint(x: CGFloat($0.offset) * step, y: midY + $0.element) }

        var path = Path()
        path.move(to: top[0])
        addSmoothedEdge(to: &path, points: top)
        path.addLine(to: bottom[bottom.count - 1])
        addSmoothedEdge(to: &path, points: bottom.reversed())
        path.closeSubpath()

        // Older levels fade out toward the leading edge.
        context.fill(
            path,
            with: .linearGradient(
                Gradient(colors: [color.opacity(0.15), color.opacity(0.9)]),
                startPoint: CGPoint(x: 0, y: midY), endPoint: CGPoint(x: size.width, y: midY)))
    }

    /// Continues `path` through `points` with quadratic curves that pass through the midpoints
    /// between neighbours, which rounds the corners without overshooting the data.
    private static func addSmoothedEdge(to path: inout Path, points: [CGPoint]) {
        guard points.count > 1 else { return }
        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            let mid = CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2)
            path.addQuadCurve(to: mid, control: previous)
        }
        path.addLine(to: points[points.count - 1])
    }

    private static func drawMeter(
        history: LevelHistory, color: Color, in context: inout GraphicsContext, size: CGSize
    ) {
        let thickness: CGFloat = 6
        let track = CGRect(x: 0, y: (size.height - thickness) / 2, width: size.width, height: thickness)
        context.fill(Path(roundedRect: track, cornerRadius: thickness / 2), with: .color(color.opacity(0.2)))
        let fraction = LevelDisplayGeometry.meterFraction(history: history)
        let filled = CGRect(x: 0, y: track.minY, width: max(thickness, size.width * fraction), height: thickness)
        context.fill(Path(roundedRect: filled, cornerRadius: thickness / 2), with: .color(color.opacity(0.85)))
    }
}

// Flat bars shown when the recorder is idle (no audio input)
struct StaticVisualizer: View {
    private let barCount = 15
    private let barWidth: CGFloat = 3
    private let barHeight: CGFloat = 4
    private let barSpacing: CGFloat = 2
    let color: Color

    var body: some View {
        HStack(spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { _ in
                RoundedRectangle(cornerRadius: barWidth / 2)
                    .fill(color.opacity(0.5))
                    .frame(width: barWidth, height: barHeight)
            }
        }
    }
}

// MARK: - Processing Status Display

struct ProcessingStatusDisplay: View {
    enum Mode {
        case transcribing
        case enhancing
    }

    let mode: Mode
    let color: Color

    private var label: LocalizedStringKey {
        switch mode {
        case .transcribing: return "Transcribing"
        case .enhancing: return "Enhancing"
        }
    }

    private var animationSpeed: Double {
        switch mode {
        case .transcribing: return 0.18
        case .enhancing: return 0.22
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(label)
                .foregroundColor(color)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.5)

            ProgressAnimation(color: color, animationSpeed: animationSpeed)
        }
        .frame(height: 28)  // matches AudioVisualizer maxHeight to prevent layout shift
    }
}

// MARK: - Outcome Icon

/// The check mark (one bounce, in `color`) or the error symbol (one wiggle, system red) that replaces
/// the processing indicator when a take ends. The effect plays when the view appears, which is when the outcome
/// is reached, and not at all under Reduce Motion.
struct RecorderOutcomeIcon: View {
    let outcome: RecorderOutcome
    let color: Color
    var size: CGFloat = 16

    var body: some View {
        switch outcome {
        case .done:
            symbol.motionBounce(when: true)
        case .failed:
            symbol.motionWiggle(when: true)
        }
    }

    private var symbol: some View {
        Image(systemName: Motion.symbol(for: outcome.phase, idle: ""))
            .symbolVariant(outcome == .failed ? .fill : .none)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(outcome == .failed ? Color(nsColor: .systemRed) : color)
            .frame(height: 28)  // matches the processing display and the level meter
            .accessibilityLabel(outcome == .done ? Text("Done") : Text("Failed"))
    }
}

// MARK: - Record Button

extension RecordingState {
    /// Whether the record button (or the dot, which is one) reacts to a click.
    var allowsRecordButton: Bool {
        switch self {
        case .idle, .recording, .pasting, .done, .failed:
            return true
        case .starting, .transcribing, .enhancing, .busy:
            return false
        }
    }

    var recordButtonLabel: String {
        switch self {
        case .idle, .pasting, .done, .failed:
            return String(localized: "Start recording")
        case .starting:
            return String(localized: "Starting recording")
        case .recording:
            return String(localized: "Stop recording")
        case .transcribing:
            return String(localized: "Transcribing recording")
        case .enhancing:
            return String(localized: "Enhancing recording")
        case .busy:
            return String(localized: "Recorder unavailable")
        }
    }
}

struct RecorderRecordButton: View {
    @Environment(\.recorderPalette) private var palette
    let recordingState: RecordingState
    let action: () -> Void

    private var visualState: VisualState {
        switch recordingState {
        case .idle, .starting, .busy:
            return .ready
        case .recording:
            return .recording
        case .transcribing, .enhancing, .pasting:
            return .processing
        case .done:
            return .outcome(.done)
        case .failed:
            return .outcome(.failed)
        }
    }

    private var isDisabled: Bool { !recordingState.allowsRecordButton }

    var body: some View {
        Button(action: action) {
            buttonFace
        }
        .focusEffectDisabled()
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(accessibilityLabel)
        .accessibilityLabel(Text(accessibilityLabel))
    }

    private var buttonFace: some View {
        ZStack {
            Circle()
                .fill(colors.surface)
                .overlay(
                    Circle()
                        .strokeBorder(colors.border, lineWidth: 0.6)
                )

            stateMark
        }
        .frame(width: 21, height: 21)
        .contentShape(Circle())
        .motion(.change, value: visualState)
    }

    private var colors: StateColors {
        switch visualState {
        case .ready:
            return StateColors(
                surface: Color(red: 0.30, green: 0.30, blue: 0.32),
                border: Color(red: 0.42, green: 0.42, blue: 0.44),
                mark: Color(red: 0.78, green: 0.78, blue: 0.80)
            )
        case .recording:
            let red = Color(nsColor: .systemRed)
            return StateColors(
                surface: red.opacity(0.92),
                border: red.opacity(0.98),
                mark: .white
            )
        case .processing, .outcome:
            return StateColors(
                surface: palette.ink.opacity(0.13),
                border: palette.ink.opacity(0.18),
                mark: palette.ink.opacity(0.86)
            )
        }
    }

    @ViewBuilder
    private var stateMark: some View {
        switch visualState {
        case .ready, .recording:
            Image(systemName: "stop.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(colors.mark)
                .frame(width: 8, height: 8)
                .motionJobSymbol(visualState == .recording ? .running : .idle)
        case .processing:
            ProcessingIndicator(color: colors.mark, isActive: visualState == .processing)
        case .outcome(let outcome):
            RecorderOutcomeIcon(outcome: outcome, color: colors.mark, size: 10)
                .frame(width: 12, height: 12)
        }
    }

    private var accessibilityLabel: String { recordingState.recordButtonLabel }

    private enum VisualState: Equatable {
        case ready
        case recording
        case processing
        case outcome(RecorderOutcome)
    }

    private struct StateColors {
        let surface: Color
        let border: Color
        let mark: Color
    }
}

// MARK: - Close Button

struct RecorderCloseButton: View {
    @Environment(\.recorderPalette) private var palette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(palette.ink.opacity(0.13))
                    .overlay(
                        Circle()
                            .strokeBorder(palette.ink.opacity(0.18), lineWidth: 0.6)
                    )

                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(palette.ink.opacity(0.86))
            }
            .frame(width: 21, height: 21)
            .contentShape(Circle())
        }
        .focusEffectDisabled()
        .buttonStyle(.plain)
        .help("Close")
    }
}

// MARK: - Processing Indicator

/// The ring that turns while a recording is processed. It turns only while `isActive`.
struct ProcessingIndicator: View {
    let color: Color
    let isActive: Bool

    var body: some View {
        Circle()
            .trim(from: 0.1, to: 0.9)
            .stroke(color, lineWidth: 1.5)
            .frame(width: 12, height: 12)
            .motionSpin(isActive: isActive)
    }
}

// MARK: - Progress Dot Animation

struct ProgressAnimation: View {
    let color: Color
    let animationSpeed: Double

    private let dotCount = 5
    private let dotSize: CGFloat = 3
    private let dotSpacing: CGFloat = 2

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var currentDot = 0
    @State private var timer: Timer?

    init(color: Color = .white, animationSpeed: Double = 0.3) {
        self.color = color
        self.animationSpeed = animationSpeed
    }

    var body: some View {
        HStack(spacing: dotSpacing) {
            ForEach(0..<dotCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: dotSize / 2)
                    .fill(color.opacity(index <= currentDot ? 0.85 : 0.25))
                    .frame(width: dotSize, height: dotSize)
            }
        }
        .onAppear { startAnimation() }
        .onChange(of: reduceMotion) { _, _ in startAnimation() }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }

    private func startAnimation() {
        timer?.invalidate()
        currentDot = 0
        // The dots sweep only while a job runs, and rest half lit under Reduce Motion.
        guard Motion.loopRuns(isActive: true, reduceMotion: reduceMotion) else {
            currentDot = dotCount / 2
            return
        }
        timer = Timer.scheduledTimer(withTimeInterval: animationSpeed, repeats: true) { _ in
            currentDot = (currentDot + 1) % (dotCount + 2)
            if currentDot > dotCount { currentDot = -1 }
        }
    }
}

// MARK: - Live Transcript View

struct LiveTranscriptView: View {
    @Environment(\.recorderPalette) private var palette
    let content: LiveTranscriptContent
    let size: LiveTranscriptSize
    /// Width available to the text, without padding.
    let textWidth: CGFloat

    private var displayText: String {
        switch content {
        case .text(let text):
            return LiveTranscriptFormatter.tail(
                text, fontSize: size.fontSize, width: textWidth, maxLines: LiveTranscriptMetrics.maxLines)
        case .listening:
            return String(localized: "Listening…")
        }
    }

    var body: some View {
        Text(displayText)
            .font(.system(size: size.fontSize))
            .foregroundColor(palette.ink.opacity(content == .listening ? 0.45 : 0.8))
            .lineLimit(LiveTranscriptMetrics.maxLines)
            .multilineTextAlignment(.leading)
            .frame(width: textWidth, height: LiveTranscriptMetrics.height(for: size), alignment: .leading)
            .frame(maxWidth: .infinity)
            .transaction { $0.disablesAnimations = true }
    }
}

// MARK: - Recorder Status Display

struct RecorderStatusDisplay: View {
    @Environment(\.recorderPalette) private var palette
    let currentState: RecordingState
    let levelHistoryProvider: () -> LevelHistory
    let levelDisplay: RecorderLevelDisplay
    let menuBarHeight: CGFloat?

    init(
        currentState: RecordingState,
        levelHistoryProvider: @escaping () -> LevelHistory,
        levelDisplay: RecorderLevelDisplay = .bars,
        menuBarHeight: CGFloat? = nil
    ) {
        self.currentState = currentState
        self.levelHistoryProvider = levelHistoryProvider
        self.levelDisplay = levelDisplay
        self.menuBarHeight = menuBarHeight
    }

    var body: some View {
        Group {
            if currentState == .enhancing {
                ProcessingStatusDisplay(mode: .enhancing, color: palette.ink).motionFade()
            } else if currentState == .transcribing || currentState == .pasting {
                ProcessingStatusDisplay(mode: .transcribing, color: palette.ink).motionFade()
            } else if currentState.isOutcome {
                // The outcome shows on the record button (the Dot has its own); the centre stays empty.
                Color.clear.frame(height: 28).motionFade()
            } else if currentState == .recording {
                AudioVisualizer(
                    levelHistoryProvider: levelHistoryProvider,
                    color: palette.ink,
                    display: levelDisplay
                )
                    .scaleEffect(y: menuBarHeight != nil ? min(1.0, (menuBarHeight! - 8) / 25) : 1.0, anchor: .center)
                    .motionFade()
            } else {
                StaticVisualizer(color: palette.ink)
                    .scaleEffect(y: menuBarHeight != nil ? min(1.0, (menuBarHeight! - 8) / 25) : 1.0, anchor: .center)
                    .motionFade()
            }
        }
        .motion(.change, value: currentState)
    }
}

// MARK: - Side Slots

/// The recording time, `m:ss`: it ticks while recording, and is plain text otherwise (frozen at
/// the length of the take while the recording is processed, 0:00 when idle), so an idle bar
/// that stays on screen schedules nothing.
struct RecorderTimerLabel: View {
    @Environment(\.recorderPalette) private var palette
    let recordingState: RecordingState
    let clockProvider: () -> RecordingClock
    var width: CGFloat = RecorderSlotContent.timer.width

    var body: some View {
        Group {
            if recordingState == .recording {
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in text }
            } else {
                text
            }
        }
        .accessibilityLabel(Text("Recording time"))
    }

    private var text: some View {
        Text(RecordingClock.format(clockProvider().elapsed(at: RecordingClock.now)))
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .foregroundColor(palette.ink.opacity(recordingState == .recording ? 0.9 : 0.55))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: width)
    }
}

/// One side slot of a bar: what `RecorderSlotContent` names.
struct RecorderSlotView: View {
    @Environment(\.recorderPalette) private var palette
    let content: RecorderSlotContent
    let recordingState: RecordingState
    let levelHistoryProvider: () -> LevelHistory
    let levelDisplay: RecorderLevelDisplay
    let clockProvider: () -> RecordingClock
    let modeName: String
    var menuBarHeight: CGFloat? = nil

    @ViewBuilder
    var body: some View {
        switch content {
        case .none:
            EmptyView()
        case .timer:
            RecorderTimerLabel(recordingState: recordingState, clockProvider: clockProvider)
        case .level:
            RecorderStatusDisplay(
                currentState: recordingState,
                levelHistoryProvider: levelHistoryProvider,
                levelDisplay: levelDisplay,
                menuBarHeight: menuBarHeight)
        case .modeName:
            Text(modeName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(palette.ink.opacity(0.75))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: content.width)
        }
    }
}

// MARK: - Dot

/// The dot style's face: a small dot that is red while recording, with a halo that swells with
/// the real input level, and the recording time beside it. Processing shows a slowly pulsing
/// neutral dot; idle (visibility "Always") a still grey one.
///
/// The time is a small label beside the dot rather than a hover reveal: the panel never becomes
/// the key window, and hover tracking in such a panel is not reliable, so a label is the version
/// that always works.
struct RecorderDotView: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.recorderPalette) private var palette
    let recordingState: RecordingState
    let levelHistoryProvider: () -> LevelHistory
    let clockProvider: () -> RecordingClock
    let reduceMotionOverride: Bool?

    init(
        recordingState: RecordingState,
        levelHistoryProvider: @escaping () -> LevelHistory,
        clockProvider: @escaping () -> RecordingClock,
        reduceMotionOverride: Bool? = nil
    ) {
        self.recordingState = recordingState
        self.levelHistoryProvider = levelHistoryProvider
        self.clockProvider = clockProvider
        self.reduceMotionOverride = reduceMotionOverride
    }

    private var reducesMotion: Bool { reduceMotionOverride ?? systemReduceMotion }

    static func showsTimer(for state: RecordingState) -> Bool {
        switch state {
        case .recording, .transcribing, .enhancing, .pasting, .done, .failed: return true
        case .idle, .starting, .busy: return false
        }
    }

    /// Only a recording or a processing dot moves; an idle dot is still, and its timeline is
    /// paused. With Reduce Motion the processing dot is still too.
    private var isAnimated: Bool {
        switch recordingState {
        case .recording: return true
        case .transcribing, .enhancing, .pasting: return !reducesMotion
        case .idle, .starting, .busy, .done, .failed: return false
        }
    }

    var body: some View {
        let showsTimer = Self.showsTimer(for: recordingState)
        HStack(spacing: RecorderDotMetrics.spacing) {
            TimelineView(.animation(minimumInterval: 1 / RecorderLevelMetrics.samplesPerSecond, paused: !isAnimated)) { context in
                dot(at: context.date)
            }
            .frame(width: RecorderDotMetrics.areaSize, height: RecorderDotMetrics.areaSize)

            if showsTimer {
                RecorderTimerLabel(
                    recordingState: recordingState, clockProvider: clockProvider,
                    width: RecorderDotMetrics.timerWidth)
            }
        }
        .padding(.leading, showsTimer ? 4 : 0)
        .frame(
            width: RecorderDotMetrics.width(showsTimer: showsTimer), height: RecorderDotMetrics.capsuleHeight,
            alignment: showsTimer ? .leading : .center)
        .contentShape(Capsule())
    }

    private func dot(at date: Date) -> some View {
        let diameter = RecorderDotMetrics.diameter
        switch recordingState {
        case .recording:
            let level = levelHistoryProvider().latest ?? 0
            let red = Color(nsColor: .systemRed)
            let halo = reducesMotion ? 1.5 : RecorderDotMetrics.haloScale(level: level)
            let haloOpacity = reducesMotion ? 0.1 + 0.3 * Double(level) : 0.3
            return AnyView(
                ZStack {
                    Circle().fill(red.opacity(haloOpacity)).frame(width: diameter, height: diameter).scaleEffect(halo)
                    Circle().fill(red).frame(width: diameter, height: diameter)
                })
        case .transcribing, .enhancing, .pasting:
            let pulse = reducesMotion ? 0.7 : 0.45 + 0.4 * (0.5 + 0.5 * sin(date.timeIntervalSinceReferenceDate * 2 * .pi / 1.2))
            return AnyView(Circle().fill(palette.ink.opacity(pulse)).frame(width: diameter, height: diameter))
        case .done:
            return AnyView(RecorderOutcomeIcon(outcome: .done, color: palette.ink, size: diameter + 4))
        case .failed:
            return AnyView(RecorderOutcomeIcon(outcome: .failed, color: palette.ink, size: diameter + 4))
        case .idle, .starting, .busy:
            return AnyView(Circle().fill(palette.ink.opacity(0.45)).frame(width: diameter, height: diameter))
        }
    }
}
