import Darwin
import Foundation

/// Reads keypresses from stdin in raw terminal mode.
/// Useful when the GUI window has not stolen focus (e.g. launched from MC).
/// Works alongside the GUI key monitor — whichever fires first wins.
final class TerminalKeyReader {

    enum Action {
        case quit
        case previousImage, nextImage
        case zoomIn, zoomOut, resetZoom, fitToWindow
        case deleteFile
        case toggleGrid
        case navigateUp, navigateDown
        case confirmSelect
        case pan(dx: CGFloat, dy: CGFloat)
    }

    /// Called on the main thread.
    var onAction: ((Action) -> Void)?

    private static let fatalSignals = [SIGINT, SIGTERM, SIGQUIT]

    private var savedTermios = termios()
    private var source: DispatchSourceRead?
    private var signalSources: [DispatchSourceSignal] = []
    private var rawModeEnabled = false

    // Parser state, touched only on `queue`
    private let queue = DispatchQueue(label: "imgdirview.tty", qos: .userInteractive)
    private var pending: [UInt8] = []
    private var flushTimer: DispatchWorkItem?

    func start() {
        guard isatty(STDIN_FILENO) != 0 else { return } // skip if not a real TTY
        // A background job that calls tcsetattr is stopped by SIGTTOU
        guard tcgetpgrp(STDIN_FILENO) == getpgrp() else { return }
        guard tcgetattr(STDIN_FILENO, &savedTermios) == 0 else { return }
        var raw = savedTermios

        // Disable canonical mode (line buffering) and echo
        raw.c_lflag &= ~(tcflag_t(ICANON) | tcflag_t(ECHO))

        // VMIN=1: return as soon as 1 byte available; VTIME=0: no timeout
        // c_cc is a 20-element UInt8 tuple; use raw pointer to index by VMIN/VTIME
        withUnsafeMutablePointer(to: &raw.c_cc) { ptr in
            let cc = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: UInt8.self)
            cc[Int(VMIN)]  = 1
            cc[Int(VTIME)] = 0
        }

        guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else { return }
        rawModeEnabled = true
        installSignalHandlers()

        let src = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: queue)
        src.setEventHandler { [weak self, weak src] in
            var buf = [UInt8](repeating: 0, count: 64)
            let n = Darwin.read(STDIN_FILENO, &buf, buf.count)
            if n > 0 {
                self?.pending += buf.prefix(n)
                self?.drain()
            } else if n == 0 || (errno != EINTR && errno != EAGAIN) {
                // EOF or a dead terminal: the source would otherwise fire forever
                src?.cancel()
            }
        }
        src.resume()
        source = src
    }

    /// Restore the terminal. Call on the main thread before the process exits.
    func stop() {
        source?.cancel()
        source = nil
        for src in signalSources { src.cancel() }
        signalSources = []
        if rawModeEnabled {
            for sig in Self.fatalSignals { signal(sig, SIG_DFL) }
            tcsetattr(STDIN_FILENO, TCSANOW, &savedTermios)
            rawModeEnabled = false
        }
    }

    deinit { stop() }

    /// Ctrl+C and kill skip applicationWillTerminate, so the terminal is restored here
    /// and the process then dies from the same signal with its default action.
    private func installSignalHandlers() {
        let saved = savedTermios
        for sig in Self.fatalSignals {
            signal(sig, SIG_IGN) // required for a dispatch signal source to receive it
            let src = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            src.setEventHandler {
                var t = saved
                tcsetattr(STDIN_FILENO, TCSANOW, &t)
                signal(sig, SIG_DFL)
                kill(getpid(), sig)
            }
            src.resume()
            signalSources.append(src)
        }
    }

    // MARK: - Parsing

    /// Split `pending` into keys. An incomplete tail (a lone ESC, half a sequence) waits
    /// 50 ms for the rest, because a terminal or ssh can deliver one sequence in two reads.
    private func drain() {
        flushTimer?.cancel()
        while let first = pending.first {
            var len = 1
            if first == 0x1B {
                guard pending.count >= 2 else { break }
                if pending[1] == 0x5B {
                    // CSI: ESC [ parameters final-byte, where the final byte is 0x40...0x7E
                    guard let end = pending.dropFirst(2).firstIndex(where: { (0x40...0x7E).contains($0) })
                    else { break }
                    len = end + 1
                } else if pending[1] == 0x4F {
                    // SS3: ESC O final-byte, sent for arrows, Home and End in application cursor mode
                    guard pending.count >= 3 else { break }
                    len = 3
                } else {
                    len = 2 // Alt+key
                }
            } else if first >= 0xC0 {
                len = first >= 0xF0 ? 4 : first >= 0xE0 ? 3 : 2 // UTF-8 lead byte
                guard pending.count >= len else { break }
            }
            let key = Array(pending.prefix(len))
            pending.removeFirst(len)
            if let action = parse(key) { emit(action) }
        }
        guard !pending.isEmpty else { return }

        let timer = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Nothing followed: a lone ESC is the Esc key, anything else is discarded
            if self.pending == [0x1B] { self.emit(.quit) }
            self.pending.removeAll()
        }
        flushTimer = timer
        queue.asyncAfter(deadline: .now() + .milliseconds(50), execute: timer)
    }

    private func emit(_ action: Action) {
        // Deliver through the run loop, not DispatchQueue.main. A handler may open a modal
        // alert; inside a main-queue block that would stall the main queue until the alert
        // closes, and every key typed meanwhile would run afterwards. Through the run loop
        // those keys arrive while the alert is up, and the handler drops them. A key already
        // queued when the alert opened (same batch as the key that opened it) still runs
        // after the alert closes.
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { [weak self] in
            self?.onAction?(action)
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    private func parse(_ key: [UInt8]) -> Action? {
        // ESC [ … and ESC O … sequences
        if key.count >= 3, key[0] == 0x1B {
            switch String(decoding: key.dropFirst(2), as: UTF8.self) {
            case "C":    return .nextImage             // → right
            case "D":    return .previousImage         // ← left
            case "A":    return .navigateUp            // ↑ up
            case "B":    return .navigateDown          // ↓ down
            case "3~":   return .deleteFile            // Forward Delete (fn+Backspace)
            case "1;2A": return .pan(dx:   0, dy: -40) // Shift+↑
            case "1;2B": return .pan(dx:   0, dy:  40) // Shift+↓
            case "1;2C": return .pan(dx: -40, dy:   0) // Shift+→
            case "1;2D": return .pan(dx:  40, dy:   0) // Shift+←
            default:     return nil
            }
        }

        switch key {
        case [0x7F]:                       return .deleteFile     // Backspace (DEL in terminal)
        case [0x20]:                       return .toggleGrid     // Space
        case [0x0D], [0x0A]:               return .confirmSelect  // Enter / Return
        case [0x2B], [0x3D]:               return .zoomIn         // + or =
        case [0x2D]:                       return .zoomOut        // -
        // o / O, and щ / Щ: the same physical key in the Russian layout (keyCode 31 in the GUI)
        case [0x6F], [0x4F], [0xD1, 0x89], [0xD0, 0xA9]: return .resetZoom
        // f / F, and а / А: the same physical key in the Russian layout (keyCode 3 in the GUI)
        case [0x66], [0x46], [0xD0, 0xB0], [0xD0, 0x90]: return .fitToWindow
        default:                           return nil
        }
    }
}
