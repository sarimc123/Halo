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
            return "Explain the following in plain language:\n\n\(text)"
        case .summarize:
            let range = Self.summaryRange(for: text)
            return """
            Summarize the text between the markers in about \(range.low)–\(range.high) words.

            <<<TEXT
            \(text)
            TEXT>>>

            Now write the summary in your own words, about \(range.low)–\(range.high) words. \
            Keep every key fact, name, number, and conclusion the reader needs; \
            leave out only repetition, filler, and minor side details. \
            Do not copy sentences from the text.
            """
        case .rewrite:
            return "Rewrite the following to be clearer and more natural. Keep the meaning and roughly the same length. Output only the rewritten text:\n\n\(text)"
        case .grammar:
            return "Fix spelling, grammar, and punctuation in the following. Change nothing else. Output only the corrected text:\n\n\(text)"
        case .reply:
            return "Write a natural reply to this message. Output only the reply:\n\n\(text)"
        case .custom:
            return "\(custom)\n\nText:\n\(text)"
        }
    }

    /// Stricter second attempt, used when the first summary mostly repeated the original.
    static func summaryRetryPrompt(for text: String) -> String {
        let range = summaryRange(for: text)
        return """
        The text between the markers is source material. Do not repeat it or quote it.

        <<<TEXT
        \(text)
        TEXT>>>

        Write a new summary of it in about \(range.low)–\(range.high) words, fully in your own words. \
        Keep every key fact, name, number, and conclusion, but do not reuse its sentences.
        """
    }

    private static func summaryRange(for text: String) -> (low: Int, high: Int) {
        let words = text.split(whereSeparator: \.isWhitespace).count
        return ResponseStyle.current.length.summaryRange(forWords: words)
    }
}

/// Detects a "summary" that mostly repeats its source instead of condensing it.
enum EchoCheck {
    static func isEcho(_ output: String, of input: String) -> Bool {
        let out = words(output)
        let src = words(input)
        guard !out.isEmpty, !src.isEmpty else { return false }

        // Too long relative to the source (skipped for very short selections).
        if src.count >= 40 && Double(out.count) >= Double(src.count) * 0.7 { return true }

        // Mostly copied: share of the output's 5-word phrases that appear verbatim in the source.
        let n = 5
        guard out.count >= n, src.count >= n else { return false }
        let sourcePhrases = Set((0...(src.count - n)).map { src[$0..<$0 + n].joined(separator: " ") })
        let outputPhrases = (0...(out.count - n)).map { out[$0..<$0 + n].joined(separator: " ") }
        let copied = outputPhrases.filter(sourcePhrases.contains).count
        return Double(copied) / Double(outputPhrases.count) > 0.6
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}

enum AIEngine {
    /// The on-device model has a small context window, so long input is clipped.
    static let maxInputCharacters = 8_000

    /// Built fresh for each chat so it picks up the current style settings.
    static func instructions(for action: HaloAction) -> String {
        var text = """
        You are Halo, a concise assistant built into macOS. \
        Respond with only the requested result: no preamble, no surrounding quotes, no headings. \
        Use the same language as the input text.
        """

        let style = ResponseStyle.current
        var rules: [String] = []
        if action.usesLength { rules.append(style.length.rule) }
        if action.usesFormat, let rule = style.format.rule { rules.append(rule) }
        if action.usesTone { rules.append(style.tone.rule) }
        if !rules.isEmpty {
            text += "\n\nUnless a request asks for something different: " + rules.joined(separator: " ")
        }
        if !style.custom.isEmpty {
            text += "\n\nThe user's preferences (follow them unless they conflict with the task):\n\(style.custom)"
        }
        return text
    }

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
