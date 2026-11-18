import Foundation

/// Cases are in Settings picker order.
public enum AIProvider: String, CaseIterable, Identifiable, Sendable {
    case appleIntelligence
    case chatGPT
    case ollama
    case lmStudio
    case claude
    case openAI
    case gemini
    case openRouter
    case custom

    public enum Access: Sendable, Equatable {
        case onDevice
        case signIn
        case apiKey(getKeyURL: URL)
        case localServer(downloadURL: URL)
        case customEndpoint
    }

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .appleIntelligence: "Apple Intelligence"
        case .chatGPT: "ChatGPT"
        case .claude: "Claude"
        case .openAI: "OpenAI API"
        case .openRouter: "OpenRouter"
        case .gemini: "Gemini"
        case .ollama: "Ollama"
        case .lmStudio: "LM Studio"
        case .custom: "Custom"
        }
    }

    public var access: Access {
        switch self {
        case .appleIntelligence: .onDevice
        case .chatGPT, .openRouter: .signIn
        case .claude: .apiKey(getKeyURL: URL(string: "https://platform.claude.com/settings/keys")!)
        case .openAI: .apiKey(getKeyURL: URL(string: "https://platform.openai.com/api-keys")!)
        case .gemini: .apiKey(getKeyURL: URL(string: "https://aistudio.google.com/apikey")!)
        case .ollama: .localServer(downloadURL: URL(string: "https://ollama.com/download")!)
        case .lmStudio: .localServer(downloadURL: URL(string: "https://lmstudio.ai")!)
        case .custom: .customEndpoint
        }
    }

    /// Nil for the on-device model, and for `.custom`, whose URL the user enters.
    public var baseURL: URL? {
        switch self {
        case .appleIntelligence: nil
        case .chatGPT, .openAI: URL(string: "https://api.openai.com/v1")
        case .claude: URL(string: "https://api.anthropic.com/v1")
        case .openRouter: URL(string: "https://openrouter.ai/api/v1")
        case .gemini: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai")
        case .ollama: URL(string: "http://127.0.0.1:11434/v1")
        case .lmStudio: URL(string: "http://127.0.0.1:1234/v1")
        case .custom: nil
        }
    }

    public var isOnDevice: Bool { access == .onDevice }

    public var dialect: LLMDialect {
        switch self {
        case .chatGPT: .responses
        case .claude: .anthropic
        default: .chatCompletions
        }
    }

    public var defaultModel: String {
        self == .claude ? "claude-haiku-5-5" : ""
    }

    /// The newest model matching the provider's cheap, image-capable family; one call per active minute rewards a small model.
    public func preferredModel(from available: [String]) -> String? {
        let newestFirst = available.sorted { $0.localizedStandardCompare($1) == .orderedDescending }
        let matches: (String) -> Bool = switch self {
        case .claude: { $0.contains("haiku") }
        case .openAI: { $0.hasPrefix("gpt") && $0.contains("mini") && !$0.contains("audio") && !$0.contains("realtime") && !$0.contains("transcribe") && !$0.contains("tts") }
        case .chatGPT: { $0.contains("mini") }
        case .openRouter: { $0.hasPrefix("anthropic/claude-haiku") }
        case .gemini: { $0.contains("flash") && !$0.contains("image") && !$0.contains("tts") && !$0.contains("live") }
        case .ollama, .lmStudio: { name in ["vl", "vision", "llava", "gemma3", "gemma4", "minicpm-v"].contains { name.contains($0) } }
        case .appleIntelligence, .custom: { _ in false }
        }
        // ChatGPT lists models in its own recommended order.
        if self == .chatGPT { return available.first(where: matches) ?? available.first }
        return newestFirst.first(where: matches) ?? available.first
    }
}
