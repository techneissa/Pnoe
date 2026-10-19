import FormatterCore
import Foundation

/// The mach service name of the embedded XPC service that hosts the model.
public let formatterXPCServiceName = "com.techneissa.Pnoe.PnoeFormatterXPC"
public let formatterXPCErrorDomain = "com.techneissa.Pnoe.FormatterXPC"

/// What travels over the connection, as JSON in `NSData`: plain `Codable` values, no object graphs, so a
/// reply can never carry anything the other side did not expect to decode.
struct XPCPrepareRequest: Codable, Sendable {
    var identifier: String
    var modelPath: String?
    var endpoint: String?
    var contextLength: Int
    var prefix: [ChatMessage]

    init(spec: RuntimeModelSpec, prefix: PromptPrefix) {
        identifier = spec.identifier
        modelPath = spec.modelURL?.path
        endpoint = spec.endpoint?.absoluteString
        contextLength = spec.contextLength
        self.prefix = prefix.messages
    }

    var spec: RuntimeModelSpec {
        RuntimeModelSpec(
            identifier: identifier,
            modelURL: modelPath.map { URL(fileURLWithPath: $0) },
            endpoint: endpoint.flatMap(URL.init(string:)),
            contextLength: contextLength
        )
    }

    var promptPrefix: PromptPrefix { PromptPrefix(messages: prefix) }
}

struct XPCGenerateRequest: Codable, Sendable {
    var id: UUID
    var suffix: [ChatMessage]
    var maxTokens: Int
    /// Seconds left when the app sent the request. A `ContinuousClock` instant means nothing in another
    /// process, so the service builds its own deadline from this.
    var secondsLeft: Double
    var temperature: Double
    var prefixKey: String?
}

struct XPCGenerateResponse: Codable, Sendable {
    var text: String
    var stopReason: StopReason
    var promptTokens: Int
    var generatedTokens: Int
}

enum FormatterXPCErrorCode: Int {
    case invalidRequest = 1
    case notReady = 2
    case modelLoading = 3
    case cancelled = 4
    case failed = 5
}

func makeFormatterXPCError(_ error: FormatterRuntimeError) -> NSError {
    let code: FormatterXPCErrorCode
    var message = ""
    switch error {
    case .modelLoading: code = .modelLoading
    case .notReady: code = .notReady
    case .cancelled: code = .cancelled
    // A crash is what the connection reports when the service dies; a runtime never sends it.
    case .crashed: code = .failed
    case .failed(let text):
        code = .failed
        message = text
    }
    return NSError(domain: formatterXPCErrorDomain, code: code.rawValue, userInfo: [NSLocalizedDescriptionKey: message])
}

func makeInvalidRequestError(_ message: String) -> NSError {
    NSError(
        domain: formatterXPCErrorDomain, code: FormatterXPCErrorCode.invalidRequest.rawValue,
        userInfo: [NSLocalizedDescriptionKey: message])
}

/// Maps what came back over the wire to what `FormatterRuntime` callers know. A connection that was
/// interrupted or invalidated means the service died (a crash, a kill, a Metal fault): `.crashed`.
func runtimeError(fromXPC error: Error) -> FormatterRuntimeError {
    let nsError = error as NSError
    if nsError.domain == formatterXPCErrorDomain, let code = FormatterXPCErrorCode(rawValue: nsError.code) {
        switch code {
        case .modelLoading: return .modelLoading
        case .notReady: return .notReady
        case .cancelled: return .cancelled
        case .invalidRequest, .failed: return .failed(nsError.localizedDescription)
        }
    }
    if nsError.domain == NSCocoaErrorDomain {
        switch nsError.code {
        case NSXPCConnectionInterrupted, NSXPCConnectionInvalid, NSXPCConnectionReplyInvalid:
            return .crashed
        default: break
        }
    }
    return .failed(nsError.localizedDescription)
}

@objc public protocol FormatterXPCProtocol {
    func prepare(_ request: NSData, withReply reply: @escaping (NSError?) -> Void)
    func generate(_ request: NSData, withReply reply: @escaping (NSData?, NSError?) -> Void)
    func cancel(_ requestID: String)
    /// Unloads the model and, in the real service, ends the process.
    func shutdown(withReply reply: @escaping () -> Void)
}
