import FormatterCore
import Foundation

/// The service side: one exported object per connection that forwards to a `FormatterRuntime`. The XPC
/// service target hosts a `LlamaRuntime` behind it, the tests host a `FakeRuntime`.
///
/// Every method returns at once and replies from a task, so a `cancel` arriving while `generate` runs is
/// delivered and not queued behind it.
public final class FormatterXPCService: NSObject, FormatterXPCProtocol, @unchecked Sendable {
    private let router: FormatterServiceRouter
    private let onShutdown: @Sendable () -> Void

    public init(runtime: any FormatterRuntime, onShutdown: @escaping @Sendable () -> Void = {}) {
        router = FormatterServiceRouter(runtime: runtime)
        self.onShutdown = onShutdown
    }

    init(router: FormatterServiceRouter, onShutdown: @escaping @Sendable () -> Void = {}) {
        self.router = router
        self.onShutdown = onShutdown
    }

    public func prepare(_ request: NSData, withReply reply: @escaping (NSError?) -> Void) {
        let reply = ReplyBox(reply)
        guard let decoded = try? JSONDecoder().decode(XPCPrepareRequest.self, from: request as Data) else {
            reply.call(makeInvalidRequestError("Unreadable prepare request."))
            return
        }
        let router = self.router
        Task {
            do {
                try await router.prepare(decoded.spec, prefix: decoded.promptPrefix)
                reply.call(nil)
            } catch let error as FormatterRuntimeError {
                reply.call(makeFormatterXPCError(error))
            } catch {
                reply.call(makeFormatterXPCError(.failed(String(describing: type(of: error)))))
            }
        }
    }

    public func generate(_ request: NSData, withReply reply: @escaping (NSData?, NSError?) -> Void) {
        let reply = ReplyBox(reply)
        guard let decoded = try? JSONDecoder().decode(XPCGenerateRequest.self, from: request as Data) else {
            reply.call(nil, makeInvalidRequestError("Unreadable generate request."))
            return
        }
        let router = self.router
        Task {
            let generation = GenerationRequest(
                id: decoded.id,
                suffix: decoded.suffix,
                maxTokens: decoded.maxTokens,
                deadline: .now + .seconds(max(0, decoded.secondsLeft)),
                temperature: decoded.temperature,
                prefixKey: decoded.prefixKey
            )
            do {
                let result = try await router.generate(generation)
                let response = XPCGenerateResponse(
                    text: result.text, stopReason: result.stopReason,
                    promptTokens: result.promptTokens, generatedTokens: result.generatedTokens)
                reply.call(try JSONEncoder().encode(response) as NSData, nil)
            } catch let error as FormatterRuntimeError {
                reply.call(nil, makeFormatterXPCError(error))
            } catch is CancellationError {
                reply.call(nil, makeFormatterXPCError(.cancelled))
            } catch {
                reply.call(nil, makeFormatterXPCError(.failed(String(describing: type(of: error)))))
            }
        }
    }

    public func cancel(_ requestID: String) {
        guard let id = UUID(uuidString: requestID) else { return }
        let router = self.router
        Task { await router.cancel(id) }
    }

    public func shutdown(withReply reply: @escaping () -> Void) {
        let reply = ReplyBox(reply)
        let router = self.router
        let onShutdown = self.onShutdown
        Task {
            await router.unload()
            reply.call()
            onShutdown()
        }
    }

    /// The connection closed (the app quit or crashed): free the model.
    public func connectionInvalidated() async {
        await router.unload()
    }
}

/// XPC reply blocks are not `Sendable`; each is called exactly once, from one task.
private final class ReplyBox<Arguments>: @unchecked Sendable {
    private let block: Arguments
    init(_ block: Arguments) { self.block = block }
}

extension ReplyBox where Arguments == (NSError?) -> Void {
    func call(_ error: NSError?) { block(error) }
}

extension ReplyBox where Arguments == (NSData?, NSError?) -> Void {
    func call(_ data: NSData?, _ error: NSError?) { block(data, error) }
}

extension ReplyBox where Arguments == () -> Void {
    func call() { block() }
}

/// Accepts connections for the service process and ends the process when the last one closes. The runtime
/// is shared by all connections, so a second connection never loads a second copy of the model.
public final class FormatterXPCListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let router: FormatterServiceRouter
    private let onLastConnectionClosed: @Sendable () -> Void
    private let onShutdownRequested: @Sendable () -> Void
    private let lock = NSLock()
    private var openConnections = 0

    /// `onLastConnectionClosed` runs after the model is freed; the service passes `{ exit(0) }`.
    public init(
        runtime: any FormatterRuntime,
        onLastConnectionClosed: @escaping @Sendable () -> Void = {},
        onShutdownRequested: @escaping @Sendable () -> Void = {}
    ) {
        router = FormatterServiceRouter(runtime: runtime)
        self.onLastConnectionClosed = onLastConnectionClosed
        self.onShutdownRequested = onShutdownRequested
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        let service = FormatterXPCService(router: router, onShutdown: onShutdownRequested)
        newConnection.exportedInterface = NSXPCInterface(with: FormatterXPCProtocol.self)
        newConnection.exportedObject = service
        lock.lock()
        openConnections += 1
        lock.unlock()
        newConnection.invalidationHandler = { [weak self] in
            Task { await self?.connectionClosed(service) }
        }
        newConnection.resume()
        return true
    }

    private func closeOne() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        openConnections -= 1
        return openConnections <= 0
    }

    private func connectionClosed(_ service: FormatterXPCService) async {
        guard closeOne() else { return }
        await service.connectionInvalidated()
        onLastConnectionClosed()
    }
}
