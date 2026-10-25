import XCTest

/// The Ollama requests, answered by a stub: nothing reaches the network, and no Ollama needs to run.
final class OllamaSpeechServiceTests: XCTestCase {
    private let base = URL(string: "http://ollama.test:11434")!

    override func tearDown() {
        StubDownloadServer.stop()
        super.tearDown()
    }

    private func service() -> OllamaSpeechService {
        OllamaSpeechService(baseURL: base, configuration: StubDownloadServer.configuration())
    }

    private func jsonBody(of request: URLRequest) -> [String: Any]? {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var collected = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                collected.append(buffer, count: count)
            }
            data = collected
        }
        return data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    // MARK: Request

    func testRequestBodyAsksForPCMWithModelInputAndVoice() throws {
        let body = OllamaSpeechRequest.body(model: "phonon", input: "Hello, \"world\".", voice: "emma")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(object, ["model": "phonon", "input": "Hello, \"world\".", "voice": "emma", "response_format": "pcm"])
    }

    func testRequestGoesToTheSpeechEndpointAsJSON() {
        let request = OllamaSpeechRequest.urlRequest(baseURL: base, model: "phonon", input: "Hi.", voice: "default")
        XCTAssertEqual(request.url?.absoluteString, "http://ollama.test:11434/v1/audio/speech")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testRequestKeepsTheBaseAddressPath() {
        let proxied = URL(string: "http://proxy.test/ollama")!
        let request = OllamaSpeechRequest.urlRequest(baseURL: proxied, model: "m", input: "i", voice: "v")
        XCTAssertEqual(request.url?.absoluteString, "http://proxy.test/ollama/v1/audio/speech")
    }

    // MARK: Discovery

    func testFindsOnlyModelsWithTheSpeechCapabilityAndTheirVoices() async throws {
        StubDownloadServer.serve { request in
            switch request.url?.path {
            case "/api/tags":
                return .init(status: 200, body: Data(#"{"models":[{"name":"llama3.2:3b"},{"name":"phonon"}]}"#.utf8))
            case "/api/show":
                let model = self.jsonBody(of: request)?["model"] as? String
                if model == "phonon" {
                    return .init(
                        status: 200,
                        body: Data(#"{"capabilities":["speech"],"voices":["default","emma"]}"#.utf8))
                }
                return .init(status: 200, body: Data(#"{"capabilities":["completion"]}"#.utf8))
            default:
                return .init(status: 404)
            }
        }
        let models = await service().speechModels()
        XCTAssertEqual(models, [OllamaSpeechModel(name: "phonon", voices: ["default", "emma"])])
    }

    func testSpeechModelWithoutAVoiceListGetsTheDefaultVoice() async throws {
        StubDownloadServer.serve { request in
            if request.url?.path == "/api/tags" {
                return .init(status: 200, body: Data(#"{"models":[{"name":"phonon"}]}"#.utf8))
            }
            return .init(status: 200, body: Data(#"{"capabilities":["speech"]}"#.utf8))
        }
        let models = await service().speechModels()
        XCTAssertEqual(models.first?.voices, ["default"])
    }

    func testDaemonNotRunningMeansNoSpeechModels() async {
        StubDownloadServer.serve { _ in .init(status: 200, error: URLError(.cannotConnectToHost)) }
        let models = await service().speechModels()
        XCTAssertEqual(models, [])
    }

    func testPhononComesFirst() {
        let models = [
            OllamaSpeechModel(name: "phonon-de", voices: ["default"]),
            OllamaSpeechModel(name: "phonon", voices: ["default"]),
        ]
        XCTAssertEqual(OllamaSpeechService.ordered(models).map(\.name), ["phonon", "phonon-de"])
    }

    // MARK: Audio

    func testAudioStreamDeliversTheBytesTheServerSends() async throws {
        let pcm = Data((0..<10_000).map { UInt8($0 % 251) })
        StubDownloadServer.serve { request in
            XCTAssertEqual(request.url?.path, "/v1/audio/speech")
            return .init(status: 200, body: pcm)
        }
        var received = Data()
        var blocks = 0
        for try await block in service().audio(model: "phonon", input: "Hi.", voice: "default") {
            received.append(block)
            blocks += 1
        }
        XCTAssertEqual(received, pcm)
        XCTAssertGreaterThan(blocks, 1, "audio is handed on in blocks, not as one piece")
        let sent = try XCTUnwrap(StubDownloadServer.receivedRequests.first)
        XCTAssertEqual(jsonBody(of: sent)?["response_format"] as? String, "pcm")
        XCTAssertEqual(jsonBody(of: sent)?["input"] as? String, "Hi.")
    }

    func testUnknownVoiceIsAnErrorWithTheServersMessage() async {
        StubDownloadServer.serve { _ in
            .init(status: 400, body: Data(#"{"error":"unknown voice \"zed\"; available: default, emma"}"#.utf8))
        }
        do {
            for try await _ in service().audio(model: "phonon", input: "Hi.", voice: "zed") {}
            XCTFail("expected an error")
        } catch let error as OllamaSpeechError {
            XCTAssertEqual(error, .http(status: 400, message: "unknown voice \"zed\"; available: default, emma"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}
