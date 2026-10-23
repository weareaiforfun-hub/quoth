import Foundation

public enum CleanupLevel: String, Codable, CaseIterable, Sendable {
    /// Raw transcript; only deterministic spoken punctuation is applied.
    case none
    /// Remove fillers, fix grammar, punctuation and capitalisation.
    case light
    /// May also reword for clarity and brevity, meaning preserved.
    case medium

    public var title: String {
        switch self {
        case .none: "None"
        case .light: "Light"
        case .medium: "Medium"
        }
    }
}

public enum ProviderKind: String, Codable, CaseIterable, Sendable {
    /// Engines on this Mac (whisper.cpp; llama.cpp or Ollama). Free, private.
    case local
    /// Any OpenAI-compatible API (Groq, OpenAI…) with your own key.
    case cloud
}

/// Which engine runs language models when text is processed on this Mac.
public enum LocalTextEngine: String, Codable, CaseIterable, Sendable {
    /// llama.cpp's `llama-server`, shipped inside Quoth.app, with a GGUF model file.
    case builtIn
    /// A separately installed Ollama (power users; allows a different model per job).
    case ollama
}

public enum HotkeyChoice: String, Codable, CaseIterable, Sendable {
    case fn
    case rightOption
    case rightCommand

    public var title: String {
        switch self {
        case .fn: "Fn (🌐)"
        case .rightOption: "Right Option"
        case .rightCommand: "Right Command"
        }
    }
}

public enum Retention: String, Codable, CaseIterable, Sendable {
    /// Keep history; audio is deleted after 14 days.
    case normal
    /// Delete history and audio after 24 hours.
    case day
    /// Never write history or audio to disk.
    case never

    public var title: String {
        switch self {
        case .normal: "Keep (audio for 14 days)"
        case .day: "Delete after 24 hours"
        case .never: "Never store"
        }
    }
}

public struct Settings: Codable, Equatable, Sendable {
    public var cleanupLevel: CleanupLevel = .light
    /// Who turns audio into text, and who rewrites text. Mixing is fine (e.g. local Whisper + cloud LLM).
    public var speechProvider: ProviderKind = .local
    public var textProvider: ProviderKind = .local

    public var whisperModelPath: String = AppPaths.models.appendingPathComponent("ggml-large-v3-turbo-q5_0.bin").path
    public var whisperPort: Int = 8178
    public var localTextEngine: LocalTextEngine = .builtIn
    /// GGUF model run by the built-in llama-server (one model serves every text job).
    public var llamaModelPath: String = AppPaths.models.appendingPathComponent(ModelCatalog.defaultGGUF.file).path
    public var llamaPort: Int = 8179
    public var ollamaBaseURL: String = "http://127.0.0.1:11434"
    public var ollamaModel: String = "qwen2.5:14b-instruct"

    public var cloudBaseURL: String = "https://api.groq.com/openai/v1"
    public var cloudASRModel: String = "whisper-large-v3-turbo"
    public var cloudLLMModel: String = "llama-3.3-70b-versatile"

    /// Spoken languages (ISO 639-1). Empty = auto-detect any language; one = pinned;
    /// several = auto-detect restricted to this set.
    public var languages: [String] = []
    public var languageVariant: LanguageVariant = .none
    public var hotkey: HotkeyChoice = .fn
    public var handsFreeEnabled: Bool = true
    public var playSounds: Bool = true
    public var retention: Retention = .normal
    /// CoreAudio device UIDs in the user's order of preference.
    public var preferredMicUIDs: [String] = []
    public var earshotAlwaysVisible: Bool = true
    public var hideEarshotFromScreenCapture: Bool = false
    /// Seconds to wait for the cleanup LLM before pasting the raw transcript.
    public var llmTimeoutLocal: Double = 4.0
    public var llmTimeoutCloud: Double = 2.0
    /// Read the focused field (via Accessibility) to match continuation and code identifiers.
    public var contextAwareness: Bool = true
    public var commandModeEnabled: Bool = true
    /// Ollama model for Command Mode and Transforms (blank = same as cleanup).
    public var commandModel: String = ""
    /// Ollama model for meeting summaries and Q&A (blank = same as cleanup).
    public var meetingModel: String = ""
    public var transformHotkeys: Bool = true
    public var scratchpadHotkey: Bool = true
    /// Thumb Talk: 0 off, 2 middle, 3 back, 4 forward.
    public var mouseDictateButton: Int = 0
    public var mouseEnterButton: Int = 0
    /// Lets MCP clients (Claude, ChatGPT…) read meeting and Scratchpad notes via quoth-mcp.
    public var mcpEnabled: Bool = true

    public init() {}

    /// Both jobs at once (the menu bar's quick switch). Reads `.local` when they differ.
    public var provider: ProviderKind {
        get { speechProvider == .cloud && textProvider == .cloud ? .cloud : .local }
        set { speechProvider = newValue; textProvider = newValue }
    }

    public var llmTimeout: Double { textProvider == .local ? llmTimeoutLocal : llmTimeoutCloud }

    /// The model name shown for the cleanup job, whichever engine runs it.
    public var textModelName: String {
        switch (textProvider, localTextEngine) {
        case (.cloud, _): cloudLLMModel
        case (.local, .builtIn): ModelCatalog.ggufInfo(forPath: llamaModelPath)?.name ?? (llamaModelPath as NSString).lastPathComponent
        case (.local, .ollama): ollamaModel
        }
    }

    /// The Ollama model used for a text role.
    public func ollamaModel(for role: ModelRole) -> String {
        let m = switch role {
        case .commands: commandModel
        case .meetings: meetingModel
        default: ""
        }
        return m.trimmingCharacters(in: .whitespaces).isEmpty ? ollamaModel : m
    }

    // Decode tolerantly so adding a field never wipes a user's settings file.
    private enum LegacyKeys: String, CodingKey { case language, provider }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        cleanupLevel = try c.decodeIfPresent(CleanupLevel.self, forKey: .cleanupLevel) ?? d.cleanupLevel
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        let oldProvider = try legacy.decodeIfPresent(ProviderKind.self, forKey: .provider)
        speechProvider = try c.decodeIfPresent(ProviderKind.self, forKey: .speechProvider) ?? oldProvider ?? d.speechProvider
        textProvider = try c.decodeIfPresent(ProviderKind.self, forKey: .textProvider) ?? oldProvider ?? d.textProvider
        whisperModelPath = try c.decodeIfPresent(String.self, forKey: .whisperModelPath) ?? d.whisperModelPath
        whisperPort = try c.decodeIfPresent(Int.self, forKey: .whisperPort) ?? d.whisperPort
        // Settings written before the built-in engine existed were using Ollama: keep it that way.
        localTextEngine = try c.decodeIfPresent(LocalTextEngine.self, forKey: .localTextEngine) ?? .ollama
        llamaModelPath = try c.decodeIfPresent(String.self, forKey: .llamaModelPath) ?? d.llamaModelPath
        llamaPort = try c.decodeIfPresent(Int.self, forKey: .llamaPort) ?? d.llamaPort
        ollamaBaseURL = try c.decodeIfPresent(String.self, forKey: .ollamaBaseURL) ?? d.ollamaBaseURL
        ollamaModel = try c.decodeIfPresent(String.self, forKey: .ollamaModel) ?? d.ollamaModel
        cloudBaseURL = try c.decodeIfPresent(String.self, forKey: .cloudBaseURL) ?? d.cloudBaseURL
        cloudASRModel = try c.decodeIfPresent(String.self, forKey: .cloudASRModel) ?? d.cloudASRModel
        cloudLLMModel = try c.decodeIfPresent(String.self, forKey: .cloudLLMModel) ?? d.cloudLLMModel
        languages = try c.decodeIfPresent([String].self, forKey: .languages)
            ?? (try legacy.decodeIfPresent(String.self, forKey: .language)).map { [$0] } ?? []
        languageVariant = try c.decodeIfPresent(LanguageVariant.self, forKey: .languageVariant) ?? d.languageVariant
        hotkey = try c.decodeIfPresent(HotkeyChoice.self, forKey: .hotkey) ?? d.hotkey
        handsFreeEnabled = try c.decodeIfPresent(Bool.self, forKey: .handsFreeEnabled) ?? d.handsFreeEnabled
        playSounds = try c.decodeIfPresent(Bool.self, forKey: .playSounds) ?? d.playSounds
        retention = try c.decodeIfPresent(Retention.self, forKey: .retention) ?? d.retention
        preferredMicUIDs = try c.decodeIfPresent([String].self, forKey: .preferredMicUIDs) ?? d.preferredMicUIDs
        earshotAlwaysVisible = try c.decodeIfPresent(Bool.self, forKey: .earshotAlwaysVisible) ?? d.earshotAlwaysVisible
        hideEarshotFromScreenCapture = try c.decodeIfPresent(Bool.self, forKey: .hideEarshotFromScreenCapture) ?? d.hideEarshotFromScreenCapture
        llmTimeoutLocal = try c.decodeIfPresent(Double.self, forKey: .llmTimeoutLocal) ?? d.llmTimeoutLocal
        llmTimeoutCloud = try c.decodeIfPresent(Double.self, forKey: .llmTimeoutCloud) ?? d.llmTimeoutCloud
        contextAwareness = try c.decodeIfPresent(Bool.self, forKey: .contextAwareness) ?? d.contextAwareness
        commandModeEnabled = try c.decodeIfPresent(Bool.self, forKey: .commandModeEnabled) ?? d.commandModeEnabled
        commandModel = try c.decodeIfPresent(String.self, forKey: .commandModel) ?? d.commandModel
        meetingModel = try c.decodeIfPresent(String.self, forKey: .meetingModel) ?? d.meetingModel
        transformHotkeys = try c.decodeIfPresent(Bool.self, forKey: .transformHotkeys) ?? d.transformHotkeys
        scratchpadHotkey = try c.decodeIfPresent(Bool.self, forKey: .scratchpadHotkey) ?? d.scratchpadHotkey
        mouseDictateButton = try c.decodeIfPresent(Int.self, forKey: .mouseDictateButton) ?? d.mouseDictateButton
        mouseEnterButton = try c.decodeIfPresent(Int.self, forKey: .mouseEnterButton) ?? d.mouseEnterButton
        mcpEnabled = try c.decodeIfPresent(Bool.self, forKey: .mcpEnabled) ?? d.mcpEnabled
    }
}

public enum SettingsStore {
    public static var url: URL { AppPaths.support.appendingPathComponent("settings.json") }

    public static func load() -> Settings {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        return s
    }

    public static func save(_ settings: Settings) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(settings) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Regional variants.
public enum LanguageVariant: String, Codable, CaseIterable, Sendable {
    case none, enGB, enCA, deCH, hinglish, zhHans, zhHant

    public var title: String {
        switch self {
        case .none: "Default"
        case .enGB: "English (UK spelling)"
        case .enCA: "English (Canadian spelling)"
        case .deCH: "Swiss German (ss for ß)"
        case .hinglish: "Hinglish (Hindi in Latin script)"
        case .zhHans: "Chinese (Simplified)"
        case .zhHant: "Chinese (Traditional)"
        }
    }

    /// Instruction for the cleanup model.
    public var instruction: String? {
        switch self {
        case .none: nil
        case .enGB: "Use British English spelling (colour, organise, travelled)."
        case .enCA: "Use Canadian English spelling (colour, organize, travelled)."
        case .deCH: "Write Swiss Standard German: always \"ss\", never \"ß\"."
        case .hinglish: "The speaker mixes Hindi and English (Hinglish). Write Hindi words in Latin script, never Devanagari."
        case .zhHans: "Write Chinese in Simplified characters."
        case .zhHant: "Write Chinese in Traditional characters."
        }
    }
}
