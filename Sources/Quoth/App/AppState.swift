import Foundation
import QuothCore

enum Phase: Equatable {
    case idle
    case recording(handsFree: Bool)
    case processing
    case message(String, isError: Bool)
}

/// Observable state shared by the Earshot pill, menu bar and Hub.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var phase: Phase = .idle
    /// Recent input levels (0…1) for the waveform, newest last.
    @Published var levels: [Float] = Array(repeating: 0, count: 24)
    @Published var settings: QuothCore.Settings = SettingsStore.load() {
        didSet { if settings != oldValue { SettingsStore.save(settings); onSettingsChanged?(oldValue) } }
    }
    @Published var history: [DictationRecord] = []
    /// Dictionary, snippets, styles, transforms.
    @Published var personal: PersonalData = PersonalStore.load() {
        didSet { if personal != oldValue { PersonalStore.save(personal) } }
    }
    @Published var whisperStatus: String = "Starting…"
    /// The built-in language model engine (llama-server), or "Ollama"/"Cloud".
    @Published var textEngineStatus: String = "Starting…"
    @Published var lastLatency: String = ""
    /// Recording a Command Mode instruction (the Earshot pill turns orange).
    @Published var commandActive = false
    /// Selected Hub tab (rawValue of HubSection).
    @Published var hubSection: String?

    /// The last successful dictation, for "Paste last transcript" and "Undo AI edit".
    var last: DictationRecord?
    var onSettingsChanged: ((QuothCore.Settings) -> Void)?

    func pushLevel(_ v: Float) {
        levels.removeFirst()
        levels.append(min(1, v * 12))
    }

    func resetLevels() { levels = Array(repeating: 0, count: levels.count) }
}
