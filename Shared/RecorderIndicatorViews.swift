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

// MARK: - Record Button

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
        case .transcribing, .enhancing:
            return .processing
        }
    }

    private var isDisabled: Bool {
        switch recordingState {
        case .idle, .recording:
            return false
        case .starting, .transcribing, .enhancing, .busy:
            return true
        }
    }

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
        .animation(.easeOut(duration: 0.16), value: visualState)
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
        case .processing:
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
            RoundedRectangle(cornerRadius: 2.2, style: .continuous)
                .fill(colors.mark)
                .frame(width: 8, height: 8)
        case .processing:
            ProcessingIndicator(color: colors.mark)
        }
    }

    private var accessibilityLabel: String {
        switch recordingState {
        case .idle:
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

    private enum VisualState: Equatable {
        case ready
        case recording
        case processing
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

struct ProcessingIndicator: View {
    @State private var rotation: Double = 0
    let color: Color

    var body: some View {
        Circle()
            .trim(from: 0.1, to: 0.9)
            .stroke(color, lineWidth: 1.5)
            .frame(width: 12, height: 12)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}

// MARK: - Progress Dot Animation

struct ProgressAnimation: View {
    let color: Color
    let animationSpeed: Double

    private let dotCount = 5
    private let dotSize: CGFloat = 3
    private let dotSpacing: CGFloat = 2

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
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }

    private func startAnimation() {
        timer?.invalidate()
        currentDot = 0
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
                ProcessingStatusDisplay(mode: .enhancing, color: palette.ink).transition(.opacity)
            } else if currentState == .transcribing {
                ProcessingStatusDisplay(mode: .transcribing, color: palette.ink).transition(.opacity)
            } else if currentState == .recording {
                AudioVisualizer(
                    levelHistoryProvider: levelHistoryProvider,
                    color: palette.ink,
                    display: levelDisplay
                )
                    .scaleEffect(y: menuBarHeight != nil ? min(1.0, (menuBarHeight! - 8) / 25) : 1.0, anchor: .center)
                    .transition(.opacity)
            } else {
                StaticVisualizer(color: palette.ink)
                    .scaleEffect(y: menuBarHeight != nil ? min(1.0, (menuBarHeight! - 8) / 25) : 1.0, anchor: .center)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: currentState)
    }
}
