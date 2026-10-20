import AppKit
import Foundation
import os

@MainActor
final class TranscriptionDelivery {
    private let logger = Logger(subsystem: "com.techneissa.pnoe", category: "TranscriptionDelivery")

    struct Request {
        let transcription: Transcription
        let text: String?
        let output: OutputRuntimeConfiguration
        let responseConfig: EnhancementRuntimeConfiguration?
        let responseError: String?
        let isAssistantFollowUp: Bool
        let sendAfterPaste: Bool
    }

    struct Actions {
        let setState: (RecordingState) -> Void
        let sendFollowUp: (String, Transcription) async -> Void
        let showResponse: (String, String?) async -> Void
        let failResponse: (String) async -> Void
    }

    func deliver(_ request: Request, actions: Actions) async {
        guard request.transcription.transcriptionStatus == TranscriptionStatus.completed.rawValue else {
            actions.setState(.failed)
            return
        }

        if request.isAssistantFollowUp {
            await deliverFollowUp(request, actions: actions)
            return
        }

        if request.output.outputMode == .respond,
            request.responseConfig != nil || request.responseError != nil
        {
            await deliverResponse(request, actions: actions)
            return
        }

        if request.output.outputMode == .customCommand {
            await deliverCustomCommand(request, actions: actions)
            return
        }

        if let text = request.text, RecorderOutcomeFlow.hasText(text) {
            let sendKey = request.sendAfterPaste ? FinishAndSendSettings.selectedKey : request.output.autoSendKey
            await paste(text, sendKey: sendKey, takeHadError: request.responseError != nil, actions: actions)
        } else {
            // Nothing was said: there is nothing to paste.
            SoundManager.shared.play(.stop)
            actions.setState(.failed)
        }
    }

    private func deliverFollowUp(_ item: Request, actions: Actions) async {
        SoundManager.shared.play(.stop)

        guard let text = item.text?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else {
            // Nothing was said: back to idle, which keeps the conversation open, with no error icon.
            actions.setState(.idle)
            return
        }

        actions.setState(.enhancing)
        await actions.sendFollowUp(text, item.transcription)
    }

    private func deliverResponse(_ item: Request, actions: Actions) async {
        SoundManager.shared.play(.stop)

        if let responseError = item.responseError {
            await actions.failResponse("Enhancement failed: \(responseError)")
        } else if let text = item.text,
            item.responseConfig != nil
        {
            await actions.showResponse(text, item.transcription.aiRequestSystemMessage)
        } else {
            await actions.failResponse("No response was generated.")
        }
    }

    private func deliverCustomCommand(_ item: Request, actions: Actions) async {
        guard let text = item.text, RecorderOutcomeFlow.hasText(text) else {
            notifyCustomCommandFailure(CustomCommandDeliveryError.noTextToDeliver)
            SoundManager.shared.play(.stop)
            actions.setState(.failed)
            return
        }

        guard let customCommand = item.output.customCommand,
            let command = customCommand.trimmedCommand
        else {
            notifyCustomCommandFailure(CustomCommandDeliveryError.commandNotConfigured)
            SoundManager.shared.play(.stop)
            actions.setState(.failed)
            return
        }

        let finishAndSendKey: FinishAndSendKey = item.sendAfterPaste ? FinishAndSendSettings.selectedKey : .none
        SoundManager.shared.play(.stop)
        actions.setState(.pasting)

        // The check mark waits for the command to succeed; a failure shows the red error.
        let takeHadError = item.responseError != nil
        Task { @MainActor in
            _ = await RecorderOutcomeFlow.report(
                afterCommand: {
                    Task { @MainActor in
                        await self.runCustomCommand(
                            command: command, commandText: text, finishAndSendKey: finishAndSendKey)
                    }
                },
                takeHadError: takeHadError,
                into: { actions.setState($0.state) })
        }
    }

    /// Runs the command; true when it succeeded.
    private func runCustomCommand(command: String, commandText: String, finishAndSendKey: FinishAndSendKey) async -> Bool {
        let startTime = Date()
        logger.notice("Custom command started")

        do {
            let result = try await CustomCommandDeliveryRunner.run(
                command: command,
                timeout: 10,
                context: CustomCommandDeliveryContext(transcript: commandText)
            )

            let duration = Date().timeIntervalSince(startTime)
            let stdoutBytes = result.stdout.utf8.count
            let stderrBytes = result.stderr.utf8.count

            if !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                logger.notice(
                    "Custom command stdout bytes=\(stdoutBytes, privacy: .public): \(result.stdout, privacy: .public)")
            }

            if !result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                logger.notice(
                    "Custom command succeeded with stderr duration=\(Self.formattedDuration(duration), privacy: .public)s stdoutBytes=\(stdoutBytes, privacy: .public) stderrBytes=\(stderrBytes, privacy: .public): \(result.stderr, privacy: .public)"
                )
            } else {
                logger.notice(
                    "Custom command succeeded duration=\(Self.formattedDuration(duration), privacy: .public)s stdoutBytes=\(stdoutBytes, privacy: .public) stderrBytes=\(stderrBytes, privacy: .public)"
                )
            }

            if finishAndSendKey.isEnabled {
                // Let the target app finish pasting before sending.
                try await Task.sleep(nanoseconds: 150_000_000)
                CursorPaster.performSendKey(finishAndSendKey)
            }
            return true
        } catch {
            notifyCustomCommandFailure(error, duration: Date().timeIntervalSince(startTime))
            return false
        }
    }

    private func notifyCustomCommandFailure(_ error: Error, duration: TimeInterval? = nil) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if let duration {
            logger.error(
                "Custom command failed duration=\(Self.formattedDuration(duration), privacy: .public)s: \(message, privacy: .public)"
            )
        } else {
            logger.error("Custom command failed: \(message, privacy: .public)")
        }
    }

    private static func formattedDuration(_ duration: TimeInterval) -> String {
        String(format: "%.3f", duration)
    }

    /// Starts the paste, and shows the check mark (or the error symbol when it did not land or the AI
    /// step failed) once it has landed. Nothing waits for the paste: this returns at once, so the
    /// history save and the completion notice run as before, and a new recording can start while the
    /// paste lands; its outcome is then dropped by the engine.
    private func paste(_ text: String, sendKey: FinishAndSendKey, takeHadError: Bool, actions: Actions) async {
        let appendSpace = UserDefaults.standard.bool(forKey: "AppendTrailingSpace")
        let pastedText = text + (appendSpace ? " " : "")
        SoundManager.shared.play(.stop)
        actions.setState(.pasting)

        let pasteTask = CursorPaster.startPasteAtCursor(pastedText)

        Task { @MainActor in
            let pasteOutcome = await RecorderOutcomeFlow.report(
                afterPaste: { pasteTask },
                landed: { $0.result.didPostPasteCommand },
                takeHadError: takeHadError,
                into: { actions.setState($0.state) })

            if sendKey.isEnabled, let pasteOutcome, pasteOutcome.result.didPostPasteCommand {
                try? await Task.sleep(nanoseconds: 150_000_000)
                if let generation = pasteOutcome.autoLearnGeneration {
                    await AutoLearnService.shared.cancelForAutoSend(generation: generation)
                }
                CursorPaster.performSendKey(sendKey)
            }
        }
    }
}
