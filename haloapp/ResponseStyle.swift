import Foundation

enum ResponseLength: String, CaseIterable, Identifiable {
    case short, medium, detailed
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var rule: String {
        switch self {
        case .short: "Keep answers very short: one to three sentences, or a few bullets."
        case .medium: "Keep answers fairly brief: about one short paragraph, or up to six bullets."
        case .detailed: "Give thorough answers with relevant detail and examples."
        }
    }

    /// Portion of the original text a summary should use. Raise these if summaries feel too short.
    private var summaryShare: Double {
        switch self {
        case .short: 0.20
        case .medium: 0.30
        case .detailed: 0.45
        }
    }

    /// Word range for a summary of a text with `words` words. Scales with the input; no fixed maximum.
    /// A range works better than "at most N", which small models treat as a reason to undershoot.
    func summaryRange(forWords words: Int) -> (low: Int, high: Int) {
        let target = max(Double(words) * summaryShare, 15)
        return (Int((target * 0.8).rounded()), Int((target * 1.2).rounded()))
    }
}

enum ResponseFormat: String, CaseIterable, Identifiable {
    case auto, sentences, bullets
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: "Auto"
        case .sentences: "Prefer sentences"
        case .bullets: "Prefer bullet points"
        }
    }
    var detail: String {
        switch self {
        case .auto: "Halo picks whatever fits the answer."
        case .sentences: "Short paragraphs; lists only for steps or many items."
        case .bullets: "Lists by default; a sentence only for one-point answers."
        }
    }
    var rule: String? {
        switch self {
        case .auto:
            nil
        case .sentences:
            "Prefer full sentences and short paragraphs. Only use a list when the content is a set of steps or many separate items."
        case .bullets:
            "Prefer bulleted lists, starting each line with \"- \". Use a plain sentence only for very short, single-point answers."
        }
    }
}

enum ResponseTone: String, CaseIterable, Identifiable {
    case casual, neutral, technical
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var rule: String {
        switch self {
        case .casual: "Use a friendly, casual, conversational tone."
        case .neutral: "Use a clear, neutral tone."
        case .technical: "Use a precise, technical tone with correct terminology; assume an expert reader."
        }
    }
}

enum StyleKeys {
    static let length = "responseLength"
    static let format = "responseFormat"
    static let tone = "responseTone"
    static let customInstructions = "customInstructions"
    /// Keeps custom instructions small; the on-device context is only ~4K tokens.
    static let customLimit = 500
}

struct ResponseStyle {
    var length: ResponseLength
    var format: ResponseFormat
    var tone: ResponseTone
    var custom: String

    /// Defaults here must match the @AppStorage defaults in SettingsView.
    static var current: ResponseStyle {
        let d = UserDefaults.standard
        let custom = (d.string(forKey: StyleKeys.customInstructions) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ResponseStyle(
            length: d.string(forKey: StyleKeys.length).flatMap(ResponseLength.init) ?? .medium,
            format: d.string(forKey: StyleKeys.format).flatMap(ResponseFormat.init) ?? .auto,
            tone: d.string(forKey: StyleKeys.tone).flatMap(ResponseTone.init) ?? .neutral,
            custom: String(custom.prefix(StyleKeys.customLimit))
        )
    }
}

extension HaloAction {
    /// Summarize is left out: it gets a word range in its prompt instead of the general length rule.
    var usesLength: Bool {
        switch self {
        case .explain, .reply, .custom: true
        case .summarize, .rewrite, .grammar: false
        }
    }
    var usesFormat: Bool {
        switch self {
        case .explain, .summarize, .custom: true
        case .rewrite, .grammar, .reply: false
        }
    }
    var usesTone: Bool { self != .grammar }
}
