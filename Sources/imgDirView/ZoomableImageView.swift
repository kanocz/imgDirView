import AppKit

final class ZoomableImageView: NSView {

    // Called whenever the zoom level changes so the status bar can update
    var onZoomChanged: (() -> Void)?

    // MARK: - State

    private var image: NSImage?
    private var fitScale: CGFloat = 1.0   // scale that fits image into current bounds
    private var userScale: CGFloat = 1.0  // user-set zoom level (1.0 = original pixels)
    private var isFitMode: Bool = true    // true → always show at fitScale
    private var panOffset: CGPoint = .zero // offset from center when not in fit mode

    private var lastDragPoint: NSPoint?

    // MARK: - Public interface

    var currentScaleInfo: String {
        if isFitMode {
            return String(format: "Fit (%.0f%%)", fitScale * 100)
        } else {
            return String(format: "%.0f%%", userScale * 100)
        }
    }

    /// Load a new image. Pass fitToWindow = true to reset zoom/pan (navigation).
    func setImage(_ image: NSImage, fitToWindow: Bool) {
        self.image = image
        if fitToWindow {
            isFitMode = true
            panOffset = .zero
        }
        recalcFitScale()
        needsDisplay = true
    }

    // MARK: - Zoom actions (called from key handler)

    func zoomIn() {
        enterUserZoom()
        userScale *= 1.25
        clampOffset()
        needsDisplay = true
        onZoomChanged?()
    }

    func zoomOut() {
        enterUserZoom()
        userScale /= 1.25
        // Snap back to fit mode when zoomed out past fit scale
        if userScale <= fitScale {
            isFitMode = true
            panOffset = .zero
        }
        needsDisplay = true
        onZoomChanged?()
    }

    /// Restore fit-to-window mode (key "f")
    func resetToFit() {
        isFitMode = true
        panOffset = .zero
        needsDisplay = true
        onZoomChanged?()
    }

    /// Reset to 1:1 pixel mapping (key "o")
    func resetToOriginalSize() {
        userScale = 1.0
        isFitMode = false
        panOffset = .zero
        clampOffset()
        needsDisplay = true
        onZoomChanged?()
    }

    // MARK: - Pan actions (called from key handler)

    func pan(dx: CGFloat, dy: CGFloat) {
        guard !isFitMode else { return }
        panOffset.x += dx
        panOffset.y += dy
        clampOffset()
        needsDisplay = true
    }

    // MARK: - NSView overrides

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        recalcFitScale()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()

        guard let image, image.size.width > 0, image.size.height > 0 else { return }

        let scale = isFitMode ? fitScale : userScale
        let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        let x = (bounds.width  - drawSize.width)  / 2 + (isFitMode ? 0 : panOffset.x)
        let y = (bounds.height - drawSize.height) / 2 + (isFitMode ? 0 : panOffset.y)

        let drawRect = CGRect(origin: CGPoint(x: x, y: y), size: drawSize)

        // Opaque images skip the checkerboard: it would show as a light fringe on antialiased edges.
        if image.representations.contains(where: { $0.hasAlpha }) {
            NSColor.checkerboard.setFill()
            drawRect.intersection(bounds).fill()
        }

        NSGraphicsContext.current?.imageInterpolation = scale < 1 ? .high : .default
        image.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
    }

    // MARK: - Mouse dragging

    override func mouseDown(with event: NSEvent) {
        if !isFitMode {
            lastDragPoint = convert(event.locationInWindow, from: nil)
            NSCursor.closedHand.set()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isFitMode, let last = lastDragPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        panOffset.x += point.x - last.x
        panOffset.y += point.y - last.y
        clampOffset()
        lastDragPoint = point
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        lastDragPoint = nil
        resetCursorIfNeeded()
    }

    override func resetCursorRects() {
        let cursor: NSCursor = (!isFitMode && imageIsLargerThanView) ? .openHand : .arrow
        addCursorRect(bounds, cursor: cursor)
    }

    // MARK: - Trackpad pinch-to-zoom

    override func magnify(with event: NSEvent) {
        enterUserZoom()
        userScale *= (1.0 + event.magnification)
        if userScale <= fitScale {
            isFitMode = true
            panOffset = .zero
        }
        clampOffset()
        needsDisplay = true
        onZoomChanged?()
    }

    // MARK: - Private helpers

    private func recalcFitScale() {
        guard let image, image.size.width > 0, image.size.height > 0 else { return }
        let sx = bounds.width  / image.size.width
        let sy = bounds.height / image.size.height
        fitScale = min(sx, sy)
        // If currently in fit mode, nothing else to update; if in user mode leave userScale alone.
    }

    private func enterUserZoom() {
        if isFitMode {
            userScale = fitScale
            isFitMode = false
        }
    }

    private func clampOffset() {
        guard let image else { return }
        let scale = isFitMode ? fitScale : userScale
        let drawW = image.size.width  * scale
        let drawH = image.size.height * scale
        let maxX = max(0, (drawW - bounds.width)  / 2)
        let maxY = max(0, (drawH - bounds.height) / 2)
        panOffset.x = panOffset.x.clamped(to: -maxX...maxX)
        panOffset.y = panOffset.y.clamped(to: -maxY...maxY)
    }

    private var imageIsLargerThanView: Bool {
        guard let image else { return false }
        let scale = isFitMode ? fitScale : userScale
        return image.size.width * scale > bounds.width || image.size.height * scale > bounds.height
    }

    private func resetCursorIfNeeded() {
        window?.invalidateCursorRects(for: self)
    }
}

// MARK: - Transparency checkerboard

extension NSColor {
    /// 16pt tile of 8pt white and light-gray squares, drawn under images that have an alpha channel.
    static let checkerboard: NSColor = {
        let s: CGFloat = 8
        let tile = NSImage(size: NSSize(width: s * 2, height: s * 2), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            NSColor(white: 0.8, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: s, height: s).fill()
            NSRect(x: s, y: s, width: s, height: s).fill()
            return true
        }
        return NSColor(patternImage: tile)
    }()
}

// MARK: - Comparable clamping helper

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
