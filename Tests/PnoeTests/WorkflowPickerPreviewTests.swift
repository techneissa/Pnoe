import AppKit
import SwiftUI
import XCTest

/// Renders the template picker and an editor section with an open info popover offscreen, with a
/// window-less `NSHostingView` and `cacheDisplay(in:to:)` so native controls draw. Nothing is shown
/// on screen. The folder comes from `PNOE_WORKFLOW_PNG_DIR` (pass it to xcodebuild as
/// `TEST_RUNNER_PNOE_WORKFLOW_PNG_DIR`) and defaults to a temporary folder.
@MainActor
final class WorkflowPickerPreviewTests: XCTestCase {
    private static let options = [
        WorkflowTemplateOption(
            id: UUID(), title: "Dictation", icon: "mic.fill",
            summary: "Fast transcription with no AI enhancement.",
            detail: "Use this when you want the quickest possible voice-to-text result."),
        WorkflowTemplateOption(
            id: UUID(), title: "Enhancement", icon: "sparkles",
            summary: "Clean up dictated text while preserving your meaning.",
            detail: "Use this for everyday writing when you want grammar, flow, and light formatting improved."),
        WorkflowTemplateOption(
            id: UUID(), title: "Email", icon: "envelope.fill",
            summary: "Turn a rough thought into a clean email.",
            detail: "Use this after selecting relevant text or opening the related window."),
        WorkflowTemplateOption(
            id: UUID(), title: "Rewrite", icon: "quote.bubble.fill",
            summary: "Rewrite selected or dictated text with better clarity.",
            detail: "Use this when you have text selected and want a stronger version."),
        WorkflowTemplateOption(
            id: UUID(), title: "Assistant", icon: "bubble.left.and.bubble.right.fill",
            summary: "Ask a question and keep the answer in the recorder.",
            detail: "Use this for answers, summaries, and follow-ups."),
    ]

    private var outputDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["PNOE_WORKFLOW_PNG_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pnoe-workflow-png")
    }

    private func render<V: View>(_ view: V, size: CGSize, name: String, dark: Bool = false) throws {
        _ = NSApplication.shared
        let host = NSHostingView(
            rootView: view
                .frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)

        var distinctColors = Set<UInt32>()
        for x in stride(from: 0, to: rep.pixelsWide, by: 7) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 7) {
                let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                let r = UInt32((c?.redComponent ?? 0) * 255)
                let g = UInt32((c?.greenComponent ?? 0) * 255)
                let b = UInt32((c?.blueComponent ?? 0) * 255)
                distinctColors.insert(r << 16 | g << 8 | b)
            }
        }
        XCTAssertGreaterThan(distinctColors.count, 8, "\(name) rendered blank")

        let directory = outputDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("\(name).png"))
    }

    private func popoverCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.15)))
    }

    func testRenderTemplatePicker() throws {
        let picker = WorkflowTemplatePickerView(options: Self.options, onSelect: { _ in }, onDismiss: {})
        try render(picker, size: CGSize(width: 400, height: 260), name: "template-picker")
        try render(picker, size: CGSize(width: 400, height: 260), name: "template-picker-dark", dark: true)
    }

    func testRenderTemplateInfoPopover() throws {
        let option = Self.options[2]
        let view = VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: option.icon).frame(width: 28, height: 28)
                Text(option.title).font(.system(size: 13, weight: .semibold))
                Image(systemName: "info.circle").fontWeight(.semibold)
            }
            popoverCard {
                InfoTipContent(message: LocalizedStringKey(option.summary), detail: LocalizedStringKey(option.detail ?? ""))
            }
        }
        .padding(20)
        try render(view, size: CGSize(width: 340, height: 200), name: "template-info-popover")
    }

    func testRenderEditorSectionWithInfoPopover() throws {
        let message: LocalizedStringKey = "The speech model and language that turn your voice into text."
        let form = Form {
            Section {
                LabeledContent("Model") { Text("Parakeet v3") }
                Toggle("Real-time", isOn: .constant(true))
            } header: {
                HStack(spacing: 4) {
                    Text("Transcription")
                    InfoTip(message, accessibilityLabel: "About Transcription")
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)

        let view = VStack(alignment: .leading, spacing: 0) {
            form.frame(height: 150)
            popoverCard { InfoTipContent(message: message) }
                .padding(.leading, 60)
        }
        try render(view, size: CGSize(width: 400, height: 240), name: "editor-section-info-popover")
    }
}
