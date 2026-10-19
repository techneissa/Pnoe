import Darwin
import Dispatch
import FormatterXPC
import Foundation
import MLXRuntime

// The MLX model lives in this process, not in the app and not in the llama.cpp service: a crash or a memory
// spike here ends this service and the app pastes the plain transcript. The process ends when the app asks for
// it (idle, toggle off, memory pressure) or when the last connection closes, which frees every Metal buffer.
private func endProcess() {
    // Let the reply to the shutdown request leave first.
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { exit(EXIT_SUCCESS) }
}

let runtime = MLXRuntime()
let delegate = FormatterXPCListenerDelegate(
    runtime: runtime,
    onLastConnectionClosed: { exit(EXIT_SUCCESS) },
    onShutdownRequested: endProcess
)
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
