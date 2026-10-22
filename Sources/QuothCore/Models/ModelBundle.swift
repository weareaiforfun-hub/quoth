import Foundation

/// The speech + language model pairs offered on first run, sized to the Mac's memory.
public enum ModelBundle: String, CaseIterable, Identifiable, Sendable {
    case lite, standard, best

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .lite: "Lite"
        case .standard: "Standard"
        case .best: "Best"
        }
    }

    /// Memory the bundle is meant for (it runs alongside your other apps).
    public var minRAMGB: Int {
        switch self {
        case .lite: 8
        case .standard: 16
        case .best: 32
        }
    }

    public var summary: String {
        switch self {
        case .lite: "Quick and small. Cleanup is simpler and makes more mistakes."
        case .standard: "Accurate speech, good cleanup, about twice as fast as Best."
        case .best: "Most accurate cleanup: corrections, lists and questions handled best."
        }
    }

    public var speech: SpeechModelInfo {
        let file = self == .lite ? "ggml-small.bin" : "ggml-large-v3-turbo-q5_0.bin"
        return ModelCatalog.speech.first { $0.file == file }!
    }

    public var text: GGUFModelInfo {
        let file = switch self {
        case .lite: "Qwen_Qwen3-4B-Instruct-2507-Q4_K_M.gguf"
        case .standard: "Qwen2.5-7B-Instruct-Q4_K_M.gguf"
        case .best: "Qwen2.5-14B-Instruct-Q4_K_M.gguf"
        }
        return ModelCatalog.gguf.first { $0.file == file }!
    }

    public var downloads: [DownloadItem] { [speech.download, text.download] }
    public var bytes: Int64 { speech.bytes + text.bytes }

    /// The largest bundle this much memory runs comfortably.
    public static func recommended(ramGB: Int) -> ModelBundle {
        allCases.last { ramGB >= $0.minRAMGB } ?? .lite
    }

    /// The bundle the settings currently point at, if any.
    public static func matching(_ s: Settings) -> ModelBundle? {
        allCases.first {
            $0.speech.file == (s.whisperModelPath as NSString).lastPathComponent
                && $0.text.file == LlamaServer.alias(forModelPath: s.llamaModelPath)
        }
    }

    /// Installed RAM in GB (8, 16, 32…).
    public static var thisMacRAMGB: Int { Int(ProcessInfo.processInfo.physicalMemory >> 30) }
}

extension Settings {
    /// Model files the chosen local engines need but that aren't on disk yet. Empty when ready to dictate.
    /// (Ollama manages its own models, and cloud needs none.)
    public var missingLocalModels: [String] {
        var missing: [String] = []
        let fm = FileManager.default
        if speechProvider == .local && !fm.fileExists(atPath: whisperModelPath) { missing.append(whisperModelPath) }
        if textProvider == .local && localTextEngine == .builtIn && !fm.fileExists(atPath: llamaModelPath) { missing.append(llamaModelPath) }
        return missing
    }

    /// Points both jobs at a bundle's files, run on this Mac by the built-in engines.
    public mutating func use(_ bundle: ModelBundle, in dir: URL = AppPaths.models) {
        speechProvider = .local
        textProvider = .local
        localTextEngine = .builtIn
        whisperModelPath = dir.appendingPathComponent(bundle.speech.file).path
        llamaModelPath = dir.appendingPathComponent(bundle.text.file).path
    }
}
