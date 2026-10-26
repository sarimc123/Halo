import Foundation
import FoundationModels

enum HaloAction: String, CaseIterable, Identifiable {
    case explain, summarize, rewrite, grammar, reply, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .explain: "Explain"
        case .summarize: "Summarize"
        case .rewrite: "Rewrite"
        case .grammar: "Fix Grammar"
        case .reply: "Reply"
        case .custom: "Custom"
        }
    }

    var symbol: String {
        switch self {
        case .explain: "lightbulb"
        case .summarize: "text.alignleft"
        case .rewrite: "pencil.line"
        case .grammar: "checkmark.circle"
        case .reply: "arrowshape.turn.up.left"
        case .custom: "sparkles"
        }
    }

    func prompt(for text: String, custom: String) -> String {
        switch self {
        case .explain:
            "Explain the following clearly and briefly in plain language:\n\n\(text)"
        case .summarize:
            "Summarize the following in 2–4 short sentences:\n\n\(text)"
        case .rewrite:
            "Rewrite the following to be clearer and more natural. Keep the meaning and roughly the same length. Output only the rewritten text:\n\n\(text)"
        case .grammar:
            "Fix spelling, grammar, and punctuation in the following. Change nothing else. Output only the corrected text:\n\n\(text)"
        case .reply:
            "Write a short, natural reply to this message. Output only the reply:\n\n\(text)"
        case .custom:
            "\(custom)\n\nText:\n\(text)"
        }
    }
}

enum AIEngine {
    /// The on-device model has a small context window, so long input is clipped.
    static let maxInputCharacters = 8_000

    static let instructions = """
    You are Halo, a concise assistant built into macOS. \
    Respond with only the requested result: no preamble, no surrounding quotes, no headings. \
    Use the same language as the input text.
    """

    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This Mac doesn’t support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in System Settings."
        case .unavailable(.modelNotReady):
            return "The on-device model is still downloading."
        default:
            return "The on-device model is unavailable."
        }
    }

    static func clip(_ text: String) -> String {
        guard text.count > maxInputCharacters else { return text }
        return String(text.prefix(maxInputCharacters)) + "\n…[truncated]"
    }
}
