import Darwin
import Dispatch
import FormatterXPC
import Foundation
import LlamaRuntime

// The model lives in this process, not in the app: a crash or a memory spike here ends the service and the
// app pastes the plain transcript. The process ends when the app asks for it (idle, toggle off, memory
// pressure) or when the last connection closes, which frees every Metal buffer.
private func endProcess() {
    // Let the reply to the shutdown request leave first.
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { exit(EXIT_SUCCESS) }
}

let runtime = LlamaRuntime()
let delegate = FormatterXPCListenerDelegate(
    runtime: runtime,
    onLastConnectionClosed: { exit(EXIT_SUCCESS) },
    onShutdownRequested: endProcess
)
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
