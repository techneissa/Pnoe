import FormatterModels
import Foundation

// Prints the installed models the formatter could use. Read-only: one GET /api/tags to Ollama and a directory
// listing of the Hugging Face cache and LM Studio's folder. Usage: pnoe-list-models [--ollama <url>] [--path <file-or-folder>]...

var configuration = FormatterModelCatalog.Configuration()
var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
    switch argument {
    case "--ollama":
        if let value = arguments.popFirst(), let url = URL(string: value) { configuration.ollamaEndpoint = url }
    case "--path":
        if let value = arguments.popFirst() { configuration.userChosenPaths.append(URL(fileURLWithPath: value)) }
    default:
        FileHandle.standardError.write(Data("unknown argument \(argument)\n".utf8))
        exit(2)
    }
}

let entries = await FormatterModelCatalog(configuration: configuration).installedModels()
if entries.isEmpty {
    print("no installed models found")
}
for entry in entries {
    let size = entry.sizeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "?"
    print("\(entry.kind.rawValue)\t\(entry.source.rawValue)\t\(size)\t\(entry.quantization ?? "-")\t\(entry.displayName)")
}
