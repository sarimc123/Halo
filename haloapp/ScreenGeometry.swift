import AppKit

enum ScreenGeometry {
    static func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
    }

    /// Moves `point` so a circle of `radius` around it stays inside its display's visible area.
    static func clampCenter(_ point: NSPoint, radius: CGFloat) -> NSPoint {
        guard let visible = screen(containing: point)?.visibleFrame else { return point }
        return NSPoint(
            x: min(max(point.x, visible.minX + radius), visible.maxX - radius),
            y: min(max(point.y, visible.minY + radius), visible.maxY - radius)
        )
    }

    /// Moves `origin` so a rect of `size` stays inside the visible area of the display containing `point`.
    static func clampOrigin(_ origin: NSPoint, size: CGSize, near point: NSPoint) -> NSPoint {
        guard let visible = screen(containing: point)?.visibleFrame else { return origin }
        return NSPoint(
            x: min(max(origin.x, visible.minX), visible.maxX - size.width),
            y: min(max(origin.y, visible.minY), visible.maxY - size.height)
        )
    }
}
