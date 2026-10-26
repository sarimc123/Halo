import AppKit
import SwiftUI
import Combine

@MainActor
final class WheelModel: ObservableObject {
    @Published var hovered: HaloAction?
    let actions = HaloAction.allCases
}

@MainActor
final class WheelController {
    enum Mode { case hold, click }

    static let size: CGFloat = 240
    static let outerRadius: CGFloat = 110
    static let innerRadius: CGFloat = 40

    let mode: Mode
    let model = WheelModel()
    var onPick: ((HaloAction?) -> Void)?

    private let center: NSPoint   // where the wheel is drawn
    private let anchor: NSPoint   // where hover distance/angle is measured from
    private let panel: FloatingPanel
    private var timer: Timer?
    private var monitors: [Any] = []

    init(center requested: NSPoint, mode: Mode) {
        let clamped = ScreenGeometry.clampCenter(requested, radius: Self.outerRadius + 8)
        self.center = clamped
        self.anchor = mode == .hold ? requested : clamped
        self.mode = mode
        panel = FloatingPanel(size: CGSize(width: Self.size, height: Self.size))
        panel.setContent(RadialWheelView(model: model))
        panel.setFrameOrigin(NSPoint(x: clamped.x - Self.size / 2, y: clamped.y - Self.size / 2))
        panel.ignoresMouseEvents = (mode == .hold)
        panel.orderFrontRegardless()

        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHover() }
        }
        if mode == .click { installClickMonitors() }
    }

    func close() {
        timer?.invalidate()
        timer = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        panel.orderOut(nil)
    }

    private func updateHover() {
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - anchor.x
        let dy = mouse.y - anchor.y
        let distance = hypot(dx, dy)

        // Dead zone in the middle; in click mode, ignore points far outside the ring.
        let inRange = distance > Self.innerRadius - 12 && (mode == .hold || distance < Self.outerRadius + 20)
        guard inRange else {
            if model.hovered != nil { model.hovered = nil }
            return
        }

        let count = model.actions.count
        var angle = Double(atan2(dx, dy)) // 0 = up, clockwise
        if angle < 0 { angle += 2 * .pi }
        let sliceWidth = 2 * Double.pi / Double(count)
        let index = Int((angle + sliceWidth / 2) / sliceWidth) % count
        let action = model.actions[index]
        if model.hovered != action { model.hovered = action }
    }

    private func installClickMonitors() {
        if let m = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.onPick?(self?.model.hovered) }
            return nil
        }) { monitors.append(m) }

        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.onPick?(nil) }
        }) { monitors.append(m) }

        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return }
            MainActor.assumeIsolated { self?.onPick?(nil) }
        }) { monitors.append(m) }
    }
}

struct RadialWheelView: View {
    @ObservedObject var model: WheelModel
    @State private var appeared = false

    private let outer = WheelController.outerRadius
    private let inner = WheelController.innerRadius

    var body: some View {
        let count = model.actions.count
        let labelRadius = (outer + inner) / 2

        ZStack {
            Donut(innerRatio: inner / outer)
                .fill(.regularMaterial, style: FillStyle(eoFill: true))
                .overlay(Donut(innerRatio: inner / outer).stroke(Color.primary.opacity(0.08), lineWidth: 1))
                .shadow(color: .black.opacity(0.22), radius: 12, y: 4)

            if let hovered = model.hovered, let index = model.actions.firstIndex(of: hovered) {
                WheelSlice(index: index, count: count, innerRatio: inner / outer)
                    .fill(Color.accentColor.opacity(0.9))
            }

            ForEach(Array(model.actions.enumerated()), id: \.element) { index, action in
                let angle = Double(index) * 2 * .pi / Double(count)
                VStack(spacing: 3) {
                    Image(systemName: action.symbol)
                        .font(.system(size: 15, weight: .medium))
                    Text(action.title)
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(model.hovered == action ? Color.white : Color.primary)
                .offset(x: labelRadius * CGFloat(sin(angle)), y: -labelRadius * CGFloat(cos(angle)))
            }

            Circle()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 6, height: 6)
        }
        .frame(width: outer * 2, height: outer * 2)
        .frame(width: WheelController.size, height: WheelController.size)
        .scaleEffect(appeared ? 1 : 0.85)
        .opacity(appeared ? 1 : 0)
        .animation(.easeOut(duration: 0.1), value: model.hovered)
        .onAppear { withAnimation(.spring(duration: 0.2)) { appeared = true } }
    }
}

struct Donut: Shape {
    var innerRatio: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addEllipse(in: rect)
        let inset = rect.width * (1 - innerRatio) / 2
        path.addEllipse(in: rect.insetBy(dx: inset, dy: inset))
        return path
    }
}

struct WheelSlice: Shape {
    let index: Int
    let count: Int
    let innerRatio: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * innerRatio
        let width = 2 * Double.pi / Double(count)
        let start = Double(index) * width - width / 2

        func point(_ angle: Double, _ radius: CGFloat) -> CGPoint {
            CGPoint(x: center.x + radius * CGFloat(sin(angle)), y: center.y - radius * CGFloat(cos(angle)))
        }

        let steps = 24
        var path = Path()
        path.move(to: point(start, outer))
        for s in 1...steps {
            path.addLine(to: point(start + width * Double(s) / Double(steps), outer))
        }
        for s in stride(from: steps, through: 0, by: -1) {
            path.addLine(to: point(start + width * Double(s) / Double(steps), inner))
        }
        path.closeSubpath()
        return path
    }
}
