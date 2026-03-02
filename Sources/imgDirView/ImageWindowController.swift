import AppKit

/// Manages the image viewer window. Plain NSObject — avoids NSWindowController quirks
/// when launched from a terminal without an app bundle.
final class ImageWindowController: NSObject {

    let window: NSWindow

    private var imageView: ZoomableImageView!
    private var statusBar: StatusBarView!
    private var thumbnailBrowser: ThumbnailBrowserView!
    private var navigator: ImageNavigator!
    private var keyMonitor: Any?
    private let terminalKeys = TerminalKeyReader()

    private enum ViewMode { case single, grid }
    private var viewMode: ViewMode = .single

    // Retained for status bar refresh on zoom change
    private var currentIndex: Int = 0
    private var currentTotal: Int = 1
    private var currentURL: URL?

    // MARK: - Init

    init(imageURL: URL, rawPath: String) {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        // visibleFrame excludes menu bar + Dock — fills the usable desktop
        let frame = screen.visibleFrame

        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = .black
        window.title = "imgDirView"
        // Keep window alive when closed via NSWindowController is gone
        window.isReleasedWhenClosed = false

        super.init()

        window.delegate = self
        buildUI()
        setupNavigator(startURL: imageURL, rawPath: rawPath)
        installKeyHandler()
        installTerminalKeyHandler()
    }

    deinit {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        terminalKeys.stop()
    }

    /// Show and focus the window. Must be called AFTER NSApp is active.
    func show() {
        // orderFrontRegardless is the reliable way to surface a window from a
        // CLI-launched process that has no app bundle (works on macOS 12-15).
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    // MARK: - UI Setup

    private func buildUI() {
        guard let content = window.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor

        imageView = ZoomableImageView(frame: content.bounds)
        imageView.autoresizingMask = [.width, .height]
        content.addSubview(imageView)

        let barHeight: CGFloat = 26
        statusBar = StatusBarView(frame: NSRect(x: 0, y: 0, width: content.bounds.width, height: barHeight))
        statusBar.autoresizingMask = [.width, .maxYMargin]
        content.addSubview(statusBar)

        thumbnailBrowser = ThumbnailBrowserView(frame: content.bounds)
        thumbnailBrowser.autoresizingMask = [.width, .height]
        thumbnailBrowser.alphaValue = 0
        thumbnailBrowser.isHidden = true
        content.addSubview(thumbnailBrowser)

        thumbnailBrowser.onOpen    = { [weak self] index in self?.openFromGrid(index: index) }
        thumbnailBrowser.onDismiss = { [weak self] in self?.hideGrid() }
        thumbnailBrowser.onDelete  = { [weak self] index in self?.confirmAndMoveToTrashFromGrid(index: index) }

        imageView.onZoomChanged = { [weak self] in
            self?.refreshStatus()
        }
    }

    // MARK: - Navigator

    private func setupNavigator(startURL: URL, rawPath: String) {
        navigator = ImageNavigator(startURL: startURL, rawPath: rawPath)
        navigator.delegate = self
        navigator.loadCurrent()
    }

    // MARK: - Status

    private func refreshStatus() {
        let name = currentURL?.lastPathComponent ?? ""
        statusBar.update(index: currentIndex, total: currentTotal,
                         filename: name, zoom: imageView.currentScaleInfo)
    }

    // MARK: - Grid show / hide

    private func showGrid() {
        viewMode = .grid
        thumbnailBrowser.isHidden = false
        thumbnailBrowser.load(rawPaths: navigator.allRawPaths, selectedIndex: navigator.index)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            thumbnailBrowser.animator().alphaValue = 1.0
        }
    }

    private func hideGrid() {
        viewMode = .single
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.10
            thumbnailBrowser.animator().alphaValue = 0.0
        }, completionHandler: {
            self.thumbnailBrowser.isHidden = true
        })
    }

    private func openFromGrid(index: Int) {
        navigator.jumpTo(index: index)
        navigator.loadCurrent()
        hideGrid()
    }

    // MARK: - Terminal Key Handling (works when GUI focus is elsewhere)

    private func installTerminalKeyHandler() {
        terminalKeys.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .quit:
                NSApp.terminate(nil)
            case .toggleGrid:
                // Up arrow: show grid in single mode, navigate up in grid mode
                if self.viewMode == .single { self.showGrid() }
                else { self.thumbnailBrowser.handleKey(126, shift: false) }
            case .navigateDown:
                if self.viewMode == .grid {
                    self.thumbnailBrowser.handleKey(125, shift: false)
                }
            case .confirmSelect:
                if self.viewMode == .grid {
                    self.openFromGrid(index: self.thumbnailBrowser.currentSelectedIndex)
                }
            case .previousImage:
                if self.viewMode == .single { self.navigator.goToPrevious() }
                else { self.thumbnailBrowser.handleKey(123, shift: false) }
            case .nextImage:
                if self.viewMode == .single { self.navigator.goToNext() }
                else { self.thumbnailBrowser.handleKey(124, shift: false) }
            case .zoomIn:
                if self.viewMode == .single { self.imageView.zoomIn() }
                else { self.thumbnailBrowser.handleKey(24, shift: false) }
            case .zoomOut:
                if self.viewMode == .single { self.imageView.zoomOut() }
                else { self.thumbnailBrowser.handleKey(27, shift: false) }
            case .resetZoom:
                if self.viewMode == .single { self.imageView.resetToOriginalSize() }
            case .fitToWindow:
                if self.viewMode == .single { self.imageView.resetToFit() }
            case .deleteFile:
                if self.viewMode == .single { self.confirmAndMoveToTrash() }
                else { self.confirmAndMoveToTrashFromGrid(index: self.thumbnailBrowser.currentSelectedIndex) }
            case .pan(let dx, let dy):
                if self.viewMode == .single { self.imageView.pan(dx: dx, dy: dy) }
            }
        }
        terminalKeys.start()
    }

    // MARK: - GUI Key Handling (when window is key)

    private func installKeyHandler() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    @discardableResult
    private func handleKey(_ event: NSEvent) -> Bool {
        // Let modal dialogs (alerts) handle their own key events (Return, Esc, Space…)
        if NSApp.modalWindow != nil { return false }
        // Let Command+key combos through (Cmd+Q, Cmd+W handled by AppKit/menu)
        if event.modifierFlags.contains(.command) { return false }

        // Esc always quits regardless of mode
        if event.keyCode == 53 { NSApp.terminate(nil); return true }

        let shift = event.modifierFlags.contains(.shift)

        switch viewMode {
        case .single: return handleSingleKey(keyCode: event.keyCode, shift: shift)
        case .grid:   return thumbnailBrowser.handleKey(event.keyCode, shift: shift)
        }
    }

    @discardableResult
    private func handleSingleKey(keyCode: UInt16, shift: Bool) -> Bool {
        switch keyCode {
        case 49: // Space → open grid
            showGrid()
            return true

        case 123: // ← Left arrow
            if shift { imageView.pan(dx: 40, dy: 0) }
            else { navigator.goToPrevious() }
            return true

        case 124: // → Right arrow
            if shift { imageView.pan(dx: -40, dy: 0) }
            else { navigator.goToNext() }
            return true

        case 126: // ↑ Up arrow
            if shift { imageView.pan(dx: 0, dy: -40) }
            else { showGrid() }
            return true

        case 125: // ↓ Down arrow
            if shift { imageView.pan(dx: 0, dy: 40) }
            return true

        case 24: // = / + (zoom in)
            imageView.zoomIn()
            return true

        case 27: // - (zoom out)
            imageView.zoomOut()
            return true

        case 31: // o / щ — 1:1 original size
            imageView.resetToOriginalSize()
            return true

        case 3: // f / а — fit to window
            imageView.resetToFit()
            return true

        case 51,  // ⌫ Backspace
             117: // ⌦ Forward Delete
            confirmAndMoveToTrash()
            return true

        default:
            return false
        }
    }

    // MARK: - Delete / Trash (single-image mode)

    private func confirmAndMoveToTrash() {
        guard let rawPath = navigator.currentRawPath else { return }
        let filename = (rawPath as NSString).lastPathComponent

        let alert = NSAlert()
        alert.messageText = "Move to Trash?"
        alert.informativeText = filename
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Try standard macOS Trash first (works on local volumes)
        let url = URL(fileURLWithPath: rawPath)
        if (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil {
            advanceAfterDelete()
            return
        }

        // Fallback for network drives (NFS, SMB) where Trash is unavailable:
        // offer permanent deletion using a raw POSIX unlink() to bypass
        // Foundation's NFD normalisation that would cause ENOENT on NFS.
        let fallback = NSAlert()
        fallback.messageText = "Cannot Move to Trash"
        fallback.informativeText = "The file may be on a network drive. Permanently delete \"\(filename)\"?"
        fallback.addButton(withTitle: "Delete Permanently")
        fallback.addButton(withTitle: "Cancel")
        fallback.alertStyle = .critical
        guard fallback.runModal() == .alertFirstButtonReturn else { return }

        let result = rawPath.withCString { Darwin.unlink($0) }
        if result == 0 {
            advanceAfterDelete()
        } else {
            let err = NSAlert()
            err.messageText = "Cannot Delete File"
            err.informativeText = String(cString: strerror(errno))
            err.runModal()
        }
    }

    private func advanceAfterDelete() {
        if !navigator.removeCurrentAndLoad() {
            // No more images in directory
            NSApp.terminate(nil)
        }
    }

    // MARK: - Delete / Trash (grid mode)

    private func confirmAndMoveToTrashFromGrid(index: Int) {
        let paths = navigator.allRawPaths
        guard index >= 0, index < paths.count else { return }
        let rawPath = paths[index]
        let filename = (rawPath as NSString).lastPathComponent

        let alert = NSAlert()
        alert.messageText = "Move to Trash?"
        alert.informativeText = filename
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let url = URL(fileURLWithPath: rawPath)
        if (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil {
            removeFromGrid(index: index)
            return
        }

        let fallback = NSAlert()
        fallback.messageText = "Cannot Move to Trash"
        fallback.informativeText = "The file may be on a network drive. Permanently delete \"\(filename)\"?"
        fallback.addButton(withTitle: "Delete Permanently")
        fallback.addButton(withTitle: "Cancel")
        fallback.alertStyle = .critical
        guard fallback.runModal() == .alertFirstButtonReturn else { return }

        let result = rawPath.withCString { Darwin.unlink($0) }
        if result == 0 {
            removeFromGrid(index: index)
        } else {
            let err = NSAlert()
            err.messageText = "Cannot Delete File"
            err.informativeText = String(cString: strerror(errno))
            err.runModal()
        }
    }

    private func removeFromGrid(index: Int) {
        navigator.removeAt(index: index)
        thumbnailBrowser.removeItem(at: index)
        if navigator.count == 0 { NSApp.terminate(nil) }
    }
}

// MARK: - NSWindowDelegate

extension ImageWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }
}

// MARK: - ImageNavigatorDelegate

extension ImageWindowController: ImageNavigatorDelegate {
    func navigator(didLoad image: NSImage, index: Int, total: Int, url: URL) {
        currentIndex = index
        currentTotal = total
        currentURL = url
        imageView.setImage(image, fitToWindow: true)
        window.title = url.lastPathComponent
        refreshStatus()
    }

    func navigator(didFailAt index: Int, total: Int, url: URL) {
        currentIndex = index
        currentTotal = total
        currentURL = url
        window.title = url.lastPathComponent
        statusBar.update(index: index, total: total,
                         filename: url.lastPathComponent, zoom: "— Error loading image —")
    }
}

// MARK: - StatusBarView

private final class StatusBarView: NSView {
    private let label = NSTextField()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.55).cgColor

        label.isEditable = false
        label.isSelectable = false
        label.isBezeled = false
        label.drawsBackground = false
        label.textColor = NSColor(white: 0.9, alpha: 1)
        label.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        label.alignment = .center
        label.autoresizingMask = [.width, .height]
        label.frame = bounds
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(index: Int, total: Int, filename: String, zoom: String) {
        label.stringValue = "[\(index + 1) / \(total)]  \(filename)  —  \(zoom)"
    }
}
