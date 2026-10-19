import FormatterCore
import FormatterEvalKit
import FormatterOllama
import Foundation

let usage = """
Usage: pnoe-format-eval --backend replay|ollama|llama-server [options]

  --backend replay        Round 1's stored outputs through the guards (tier 1 gate). Runs no model.
  --backend ollama        Local Ollama (/api/chat). Needs --model <tag>.
  --backend llama-server  Local llama-server (/v1/chat/completions). Start it first.

Options:
  --model <name>        Ollama tag, or the model name sent to llama-server.
  --endpoint <url>      Server URL (defaults: http://localhost:11434, http://127.0.0.1:8080).
  --extra-testset <file>  Also score the pairs in this JSONL file (the format of testset.jsonl), such as the file
                        the app's Workflow playground saves. Lines it cannot read are skipped and counted.
  --only-extra          With --extra-testset, score only those pairs and leave out the built-in set.
  --data-dir <dir>      The Eval folder with testset.jsonl (default: found from the working directory).
  --out-dir <dir>       Where results go (default: <data-dir>/results).
  --run <name>          Run name, the result file name (default: <backend>[-<model>]-<timestamp>).
  --ids a,b,c           Only these case ids.
  --context <name>      Only this context (email, chat, notes, agent, plain).
  --limit <n>           First n cases after filtering.
  --keep-alive <v>      Ollama keep_alive (default 10m).
  --no-think            Send think=false (Ollama) or enable_thinking=false (llama-server).
  --no-warmup           Skip the warm-up request at prepare.
  --context-length <n>  Context window to request (default 4096).
  --help
"""

struct Options {
    var backend = ""
    var model: String?
    var endpoint: URL?
    var dataDir: String?
    var extraTestset: String?
    var onlyExtra = false
    var outDir: String?
    var run: String?
    var ids: Set<String>?
    var context: FormatterContext?
    var limit: Int?
    var keepAlive = "10m"
    var noThink = false
    var warmUp = true
    var contextLength = 4096
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

func parse(_ args: [String]) -> Options {
    var options = Options()
    var iterator = args.makeIterator()
    func value(_ flag: String) -> String {
        guard let next = iterator.next() else { fail("\(flag) needs a value") }
        return next
    }
    while let arg = iterator.next() {
        switch arg {
        case "--backend": options.backend = value(arg)
        case "--model": options.model = value(arg)
        case "--endpoint":
            guard let url = URL(string: value(arg)), url.scheme != nil else { fail("--endpoint needs a URL") }
            options.endpoint = url
        case "--extra-testset": options.extraTestset = value(arg)
        case "--only-extra": options.onlyExtra = true
        case "--data-dir": options.dataDir = value(arg)
        case "--out-dir": options.outDir = value(arg)
        case "--run": options.run = value(arg)
        case "--ids": options.ids = Set(value(arg).split(separator: ",").map(String.init))
        case "--context":
            guard let context = FormatterContext(rawValue: value(arg)) else { fail("unknown context") }
            options.context = context
        case "--limit":
            guard let limit = Int(value(arg)), limit > 0 else { fail("--limit needs a positive number") }
            options.limit = limit
        case "--keep-alive": options.keepAlive = value(arg)
        case "--no-think": options.noThink = true
        case "--no-warmup": options.warmUp = false
        case "--context-length":
            guard let n = Int(value(arg)), n > 0 else { fail("--context-length needs a positive number") }
            options.contextLength = n
        case "--help", "-h":
            print(usage)
            exit(0)
        default: fail("unknown option \(arg)\n\n\(usage)")
        }
    }
    return options
}

func timestamp() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: Date())
}

func slug(_ text: String) -> String {
    String(text.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" })
}

let options = parse(Array(CommandLine.arguments.dropFirst()))
guard ["replay", "ollama", "llama-server"].contains(options.backend) else { fail("pick a backend\n\n\(usage)") }
if options.onlyExtra && options.extraTestset == nil { fail("--only-extra needs --extra-testset <file>") }

do {
    let data = try EvalData.locate(explicit: options.dataDir)
    var cases = options.onlyExtra ? [] : try TestSet.load(from: data.testsetURL)
    if let extraPath = options.extraTestset {
        let personal = try PersonalSet.load(from: URL(fileURLWithPath: extraPath))
        cases = try PersonalSet.merge(cases, with: personal.cases)
        var notes = ["\(personal.cases.count) pairs from \(extraPath)"]
        if personal.skippedOtherWorkflows > 0 { notes.append("\(personal.skippedOtherWorkflows) from other workflows left out") }
        if personal.unreadableLines > 0 { notes.append("\(personal.unreadableLines) unreadable lines skipped") }
        FileHandle.standardError.write(Data((notes.joined(separator: ", ") + "\n").utf8))
    }
    if let ids = options.ids { cases = cases.filter { ids.contains($0.id) } }
    if let context = options.context { cases = cases.filter { $0.context == context } }
    if let limit = options.limit { cases = Array(cases.prefix(limit)) }
    guard !cases.isEmpty else { fail("no cases selected") }
    let promptBuilder = try PromptBuilder.bundled()
    let outDir = options.outDir.map { URL(fileURLWithPath: $0) } ?? data.resultsDirectory
    let run = options.run ?? (options.backend == "replay" ? "replay" : [options.backend, options.model.map(slug), timestamp()].compactMap { $0 }.joined(separator: "-"))

    var file: RunFile
    switch options.backend {
    case "replay":
        let replay = try ReplayFile.load(from: data.round1OutputsURL)
        let gate = await ReplayGate.evaluate(cases: cases, replay: replay, promptBuilder: promptBuilder)
        let ideal = await EvalRunner.runOracle(cases: cases, promptBuilder: promptBuilder)
        file = RunFile(summary: RunSummary(run: run, backend: "replay", model: nil, results: ideal), gate: gate, results: ideal)
    default:
        guard let model = options.model else { fail("--backend \(options.backend) needs --model") }
        let spec = RuntimeModelSpec(identifier: model, endpoint: options.endpoint, contextLength: options.contextLength)
        let runtime: any FormatterRuntime
        if options.backend == "ollama" {
            var configuration = OllamaRuntime.Configuration(keepAlive: options.keepAlive, think: options.noThink ? false : nil, warmUp: options.warmUp)
            if let endpoint = options.endpoint { configuration.defaultEndpoint = endpoint }
            runtime = OllamaRuntime(configuration: configuration)
        } else {
            var configuration = LlamaServerRuntime.Configuration(enableThinking: options.noThink ? false : nil, warmUp: options.warmUp)
            if let endpoint = options.endpoint { configuration.defaultEndpoint = endpoint }
            runtime = LlamaServerRuntime(configuration: configuration)
        }
        try await runtime.prepare(spec, prefix: FormatterPipeline(runtime: runtime, promptBuilder: promptBuilder).prefix)
        let results = await EvalRunner.run(cases: cases, runtime: runtime, promptBuilder: promptBuilder) { done, total in
            if done % 20 == 0 || done == total { FileHandle.standardError.write(Data("\(done)/\(total)\n".utf8)) }
        }
        await runtime.unload()
        file = RunFile(summary: RunSummary(run: run, backend: options.backend, model: model, results: results), gate: nil, results: results)
    }

    let written = try Report.write(file, to: outDir)
    print(Report.markdownText(file))
    print("Wrote \(written.json.lastPathComponent) and \(written.markdown.lastPathComponent) to \(outDir.path)")
    if let gate = file.gate, !gate.pass { exit(1) }
} catch let error as FormatterRuntimeError {
    fail("runtime error: \(error)")
} catch {
    fail("error: \(error)")
}
