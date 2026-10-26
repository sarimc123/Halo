import SwiftUI
import FoundationModels
import Combine

extension HaloAction {
    /// Actions whose output is meant to replace the highlighted text.
    var replacesSelection: Bool {
        switch self {
        case .rewrite, .grammar, .custom: true
        case .explain, .summarize, .reply: false
        }
    }
}

@MainActor
final class CardModel: ObservableObject {
    let action: HaloAction
    let input: String
    let source: TextSource
    let notice: String?

    @Published var output = ""
    @Published var customPrompt = ""
    @Published var isRunning = false
    @Published var hasStarted = false
    @Published var error: String?

    private var task: Task<Void, Never>?

    init(action: HaloAction, input: String, source: TextSource, notice: String?) {
        self.action = action
        self.input = input
        self.source = source
        self.notice = notice
    }

    func run() {
        guard !isRunning else { return }
        if action == .custom && customPrompt.trimmingCharacters(in: .whitespaces).isEmpty { return }
        hasStarted = true
        if let reason = AIEngine.unavailableReason {
            error = reason
            return
        }

        isRunning = true
        output = ""
        error = nil
        let prompt = action.prompt(for: AIEngine.clip(input), custom: customPrompt)

        task = Task {
            defer { isRunning = false }
            do {
                let session = LanguageModelSession(instructions: AIEngine.instructions)
                for try await snapshot in session.streamResponse(to: prompt) {
                    output = snapshot.content
                }
            } catch is CancellationError {
            } catch let generationError as LanguageModelSession.GenerationError {
                error = Self.message(for: generationError)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func cancel() { task?.cancel() }

    private static func message(for error: LanguageModelSession.GenerationError) -> String {
        switch error {
        case .exceededContextWindowSize:
            return "That’s too much text for the on-device model. Try a shorter selection."
        case .guardrailViolation:
            return "The on-device model declined this request."
        case .unsupportedLanguageOrLocale:
            return "That language isn’t supported by the on-device model."
        default:
            return error.localizedDescription
        }
    }
}

struct ResultCardView: View {
    static let cardSize = CGSize(width: 340, height: 220)
    static let shadowPadding: CGFloat = 16
    static var panelSize: CGSize {
        CGSize(width: cardSize.width + shadowPadding * 2, height: cardSize.height + shadowPadding * 2)
    }

    @ObservedObject var model: CardModel
    let onApply: () -> Void
    let onClose: () -> Void
    @FocusState private var promptFocused: Bool

    private var canReplace: Bool {
        model.notice == nil && model.source == .selection && model.action.replacesSelection
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if model.action == .custom && !model.hasStarted && model.notice == nil {
                TextField("What should I do with this text?", text: $model.customPrompt)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($promptFocused)
                    .onSubmit { model.run() }
                Divider()
            }

            content
        }
        .padding(14)
        .frame(width: Self.cardSize.width, height: Self.cardSize.height, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .padding(Self.shadowPadding)
        .onAppear { promptFocused = true }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: model.notice == nil ? model.action.symbol : "info.circle")
            Text(model.notice == nil ? model.action.title : "Halo")
            if model.isRunning {
                ProgressView().controlSize(.mini).padding(.leading, 2)
            }
            Spacer()
            if canReplace {
                Button("Replace", action: onApply)
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.accentColor)
                    .disabled(model.output.isEmpty || model.isRunning)
                    .help("Replace the highlighted text with this result")
            }
            if !model.output.isEmpty {
                Button { Clipboard.copy(model.output) } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .help("Copy")
            }
            DotButton(color: .red, help: "Close", action: onClose)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var content: some View {
        if let message = model.notice ?? model.error {
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        } else if model.hasStarted {
            ScrollView {
                Text(model.output.isEmpty ? "Thinking…" : model.output)
                    .font(.system(size: 13))
                    .foregroundStyle(model.output.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text(model.input)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .lineLimit(6)
        }
    }
}

struct DotButton: View {
    let color: Color
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
                .scaleEffect(hovering ? 1.2 : 1)
                .contentShape(Circle().inset(by: -4))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

struct SelectionDotView: View {
    let action: () -> Void
    @State private var hovering = false
    @State private var appeared = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(.regularMaterial)
                Circle().fill(Color.accentColor).padding(4)
            }
            .frame(width: 16, height: 16)
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            .scaleEffect(appeared ? (hovering ? 1.25 : 1) : 0.3)
        }
        .buttonStyle(.plain)
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onAppear { withAnimation(.spring(duration: 0.25)) { appeared = true } }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
