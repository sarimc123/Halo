import AppKit
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

struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
}

@MainActor
final class CardModel: ObservableObject {
    /// Apple's on-device model holds about this many tokens per session.
    static let contextLimit = 4_096

    let action: HaloAction
    let input: String
    let source: TextSource
    let notice: String?

    @Published var messages: [ChatMessage] = []
    @Published var draft = ""
    @Published var isRunning = false
    @Published var error: String?

    /// One session per card so follow-ups remember the selected text and earlier replies.
    private var session: LanguageModelSession?
    private var sessionInstructions = ""
    private var task: Task<Void, Never>?
    private var runID = UUID()
    /// Set once a copied summary has been retried, so it's only retried one time.
    private var retriedEcho = false
    @Published private var sentChars = 0

    init(action: HaloAction, input: String, source: TextSource, notice: String?) {
        self.action = action
        self.input = input
        self.source = source
        self.notice = notice
    }

    var hasStarted: Bool { !messages.isEmpty }

    /// Latest assistant reply; used by Replace.
    var output: String { messages.last { $0.role == .assistant }?.text ?? "" }

    var canSend: Bool {
        notice == nil && !isRunning && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Changes whenever a message is added or a reply grows, to drive auto-scroll.
    var scrollKey: Int { messages.count &* 100_003 &+ (messages.last?.text.count ?? 0) }

    /// Rough token estimate (~4 characters per token) for everything the session has seen.
    var estimatedTokens: Int {
        let replies = messages.filter { $0.role == .assistant }.reduce(0) { $0 + $1.text.count }
        return (sessionInstructions.count + sentChars + replies) / 4
    }

    /// Runs the wheel action as the first turn. Custom waits for the user's instruction.
    func run() {
        guard notice == nil, messages.isEmpty, !isRunning, action != .custom else { return }
        send(prompt: action.prompt(for: AIEngine.clip(input), custom: ""), shownAsUser: nil)
    }

    func submitDraft() {
        guard canSend else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        // The first Custom turn wraps the instruction around the selected text; later turns are plain follow-ups.
        let prompt = messages.isEmpty ? action.prompt(for: AIEngine.clip(input), custom: text) : text
        send(prompt: prompt, shownAsUser: text)
    }

    func stop() {
        task?.cancel()
        task = nil
        runID = UUID()
        isRunning = false
    }

    func clear() {
        stop()
        session = nil
        sessionInstructions = ""
        messages = []
        error = nil
        draft = ""
        sentChars = 0
        retriedEcho = false
        run()
    }

    func cancel() { stop() }

    private func send(prompt: String, shownAsUser: String?, freshSession: Bool = false) {
        if let reason = AIEngine.unavailableReason {
            error = reason
            return
        }
        if freshSession {
            session = nil
            sentChars = 0
        }
        if let shownAsUser { messages.append(ChatMessage(role: .user, text: shownAsUser)) }
        let reply = ChatMessage(role: .assistant, text: "")
        messages.append(reply)
        sentChars += prompt.count

        let session: LanguageModelSession
        if let existing = self.session {
            session = existing
        } else {
            sessionInstructions = AIEngine.instructions(for: action)
            session = LanguageModelSession(instructions: sessionInstructions)
            self.session = session
        }
        let id = UUID()
        runID = id
        isRunning = true
        error = nil

        task = Task {
            do {
                for try await snapshot in session.streamResponse(to: prompt) {
                    guard runID == id else { break }
                    update(reply.id, text: snapshot.content)
                }
            } catch is CancellationError {
            } catch let generationError as LanguageModelSession.GenerationError {
                if runID == id { error = Self.message(for: generationError) }
            } catch {
                if runID == id { self.error = error.localizedDescription }
            }
            messages.removeAll { $0.id == reply.id && $0.text.isEmpty }
            guard runID == id else { return }

            if handleCopiedSummary(replyID: reply.id) { return }
            isRunning = false
        }
    }

    /// If the first summary mostly repeats the original, retries once with a stricter prompt.
    /// Returns true when a retry was started.
    private func handleCopiedSummary(replyID: UUID) -> Bool {
        guard action == .summarize,
              messages.count == 1,
              let text = messages.first(where: { $0.id == replyID })?.text,
              EchoCheck.isEcho(text, of: input)
        else { return false }

        if retriedEcho {
            error = "This summary is still close to the original. Try Short length, or ask for a shorter version."
            return false
        }
        retriedEcho = true
        messages.removeAll { $0.id == replyID }
        send(prompt: HaloAction.summaryRetryPrompt(for: AIEngine.clip(input)), shownAsUser: nil, freshSession: true)
        return true
    }

    private func update(_ id: UUID, text: String) {
        if let i = messages.firstIndex(where: { $0.id == id }) { messages[i].text = text }
    }

    private static func message(for error: LanguageModelSession.GenerationError) -> String {
        switch error {
        case .exceededContextWindowSize:
            return "This chat is too long for the on-device model. Press ↺ to clear it and keep going."
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
    static let defaultCardSize = CGSize(width: 380, height: 360)
    static let minCardSize = CGSize(width: 300, height: 240)
    static let maxCardSize = CGSize(width: 900, height: 1000)
    static let shadowPadding: CGFloat = 16
    private static let sizeKey = "cardSize"
    private static let bottomID = "bottom"

    /// Last size the user resized a card to, or the default.
    static var cardSize: CGSize {
        guard let saved = UserDefaults.standard.string(forKey: sizeKey) else { return defaultCardSize }
        let size = NSSizeFromString(saved)
        return size.width > 0 && size.height > 0 ? size : defaultCardSize
    }

    static var panelSize: CGSize {
        CGSize(width: cardSize.width + shadowPadding * 2, height: cardSize.height + shadowPadding * 2)
    }

    private static func saveCardSize(fromPanel size: CGSize) {
        let card = CGSize(width: size.width - shadowPadding * 2, height: size.height - shadowPadding * 2)
        UserDefaults.standard.set(NSStringFromSize(card), forKey: sizeKey)
    }

    @ObservedObject var model: CardModel
    let onApply: () -> Void
    let onClose: () -> Void
    @FocusState private var inputFocused: Bool
    @State private var windowRef = WindowRef()
    @State private var dragStart: (mouse: NSPoint, origin: NSPoint)?
    @State private var resizeStart: (mouse: NSPoint, frame: NSRect)?

    private var canReplace: Bool {
        model.notice == nil && model.source == .selection && model.action.replacesSelection
    }

    private var placeholder: String {
        model.messages.isEmpty && model.action == .custom ? "What should I do with this text?" : "Ask a follow-up…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let notice = model.notice {
                Text(notice)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                if !model.input.isEmpty {
                    Text(model.input)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(model.hasStarted ? 2 : 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                conversation
                VStack(spacing: 4) {
                    inputBar
                    if model.hasStarted { contextUsage }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .overlay(alignment: .bottomTrailing) { resizeGrip }
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .padding(Self.shadowPadding)
        .background(WindowReader(ref: windowRef))
        .onAppear { inputFocused = true }
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
                    .help("Replace the highlighted text with the latest reply")
            }
            if model.hasStarted && model.notice == nil {
                Button { model.clear() } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.plain)
                .help("Clear chat")
            }
            DotButton(color: .red, help: "Close", action: onClose)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
        .gesture(moveGesture)
    }

    /// Drags the whole card by its header. Uses the global mouse position so the moving window doesn't jitter.
    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { _ in
                guard let window = windowRef.window else { return }
                let mouse = NSEvent.mouseLocation
                if dragStart == nil { dragStart = (mouse, window.frame.origin) }
                guard let start = dragStart else { return }
                window.setFrameOrigin(NSPoint(
                    x: start.origin.x + mouse.x - start.mouse.x,
                    y: start.origin.y + mouse.y - start.mouse.y
                ))
            }
            .onEnded { _ in dragStart = nil }
    }

    private var resizeGrip: some View {
        ResizeGripShape()
            .stroke(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            .frame(width: 9, height: 9)
            .padding(7)
            .contentShape(Rectangle())
            .pointerStyle(.frameResize(position: .bottomTrailing))
            .gesture(resizeGesture)
            .help("Drag to resize")
    }

    /// Resizes from the bottom-right corner while keeping the top-left corner in place.
    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { _ in
                guard let window = windowRef.window else { return }
                let mouse = NSEvent.mouseLocation
                if resizeStart == nil { resizeStart = (mouse, window.frame) }
                guard let start = resizeStart else { return }
                let pad = Self.shadowPadding * 2
                let width = min(max(start.frame.width + mouse.x - start.mouse.x, Self.minCardSize.width + pad),
                                Self.maxCardSize.width + pad)
                let height = min(max(start.frame.height + start.mouse.y - mouse.y, Self.minCardSize.height + pad),
                                 Self.maxCardSize.height + pad)
                window.setFrame(
                    NSRect(x: start.frame.minX, y: start.frame.maxY - height, width: width, height: height),
                    display: false
                )
            }
            .onEnded { _ in
                if let window = windowRef.window { Self.saveCardSize(fromPanel: window.frame.size) }
                resizeStart = nil
            }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.messages) { message in
                        ChatMessageRow(
                            message: message,
                            isStreaming: model.isRunning && message.id == model.messages.last?.id
                        )
                    }
                    if let error = model.error {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(.orange)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            .onChange(of: model.scrollKey) {
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $model.draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($inputFocused)
                .onSubmit { model.submitDraft() }

            if model.isRunning {
                Button { model.stop() } label: {
                    Image(systemName: "stop.circle.fill").font(.system(size: 18))
                }
                .foregroundStyle(.secondary)
                .help("Stop")
            } else {
                Button { model.submitDraft() } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 18))
                }
                .foregroundStyle(model.canSend ? Color.accentColor : Color.secondary)
                .disabled(!model.canSend)
                .help("Send (Return)")
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var contextUsage: some View {
        let used = model.estimatedTokens
        let limit = CardModel.contextLimit
        let percent = min(100, used * 100 / limit)
        return Text("~\(used.formatted()) / \(limit.formatted()) tokens (\(percent)%)")
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help("Estimated from text length. The on-device model holds about 4,096 tokens per chat.")
    }
}

/// Two diagonal lines, like the resize corner on a macOS window.
struct ResizeGripShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.move(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}

/// Weak reference to the panel a SwiftUI view lives in.
final class WindowRef {
    weak var window: NSWindow?
}

/// Invisible view that reports which window it's in.
struct WindowReader: NSViewRepresentable {
    let ref: WindowRef

    func makeNSView(context: Context) -> NSView { ReaderView(ref: ref) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class ReaderView: NSView {
        let ref: WindowRef

        init(ref: WindowRef) {
            self.ref = ref
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            ref.window = window
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

struct ChatMessageRow: View {
    let message: ChatMessage
    let isStreaming: Bool
    @State private var copied = false

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 4) {
                Text(message.text.isEmpty ? "Thinking…" : message.text)
                    .font(.system(size: 13))
                    .foregroundStyle(message.text.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !isStreaming && !message.text.isEmpty {
                    Button {
                        Clipboard.copy(message.text)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.2))
                            copied = false
                        }
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
            }
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
