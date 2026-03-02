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
        case pan(dx: CGFloat, dy: CGFloat)
    }

    var onAction: ((Action) -> Void)?

    private var savedTermios = termios()
    private var source: DispatchSourceRead?
    private var rawModeEnabled = false

    func start() {
        guard isatty(STDIN_FILENO) != 0 else { return } // skip if not a real TTY

        tcgetattr(STDIN_FILENO, &savedTermios)
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

        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        rawModeEnabled = true

        // Watch stdin on a high-priority background queue
        source = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO,
                                               queue: .global(qos: .userInteractive))
        source?.setEventHandler { [weak self] in
            var buf = [UInt8](repeating: 0, count: 32)
            let n = Darwin.read(STDIN_FILENO, &buf, 32)
            guard n > 0 else { return }
            self?.dispatch(bytes: Array(buf.prefix(n)))
        }
        source?.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
        if rawModeEnabled {
            tcsetattr(STDIN_FILENO, TCSANOW, &savedTermios)
            rawModeEnabled = false
        }
    }

    deinit { stop() }

    // MARK: - Parsing

    private func dispatch(bytes: [UInt8]) {
        guard let action = parse(bytes: bytes) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onAction?(action)
        }
    }

    private func parse(bytes: [UInt8]) -> Action? {
        // Single-byte keys
        if bytes.count == 1 {
            switch bytes[0] {
            case 0x1B:        return .quit         // Esc (lone — not part of a sequence)
            case 0x7F:        return .deleteFile   // Backspace (DEL in terminal)
            case 0x2B, 0x3D:  return .zoomIn       // + or =
            case 0x2D:        return .zoomOut       // -
            case 0x6F, 0x4F:  return .resetZoom    // o / O
            case 0x66, 0x46:  return .fitToWindow  // f / F
            default:          return nil
            }
        }

        // ESC [ … sequences (arrow keys)
        if bytes.count >= 3, bytes[0] == 0x1B, bytes[1] == 0x5B {
            // Plain arrows: ESC [ A/B/C/D
            if bytes.count == 3 {
                switch bytes[2] {
                case 0x43: return .nextImage           // → right
                case 0x44: return .previousImage       // ← left
                case 0x41: return nil                  // ↑ up  (no action without shift)
                case 0x42: return nil                  // ↓ down
                default:   return nil
                }
            }
            // Forward Delete: ESC [ 3 ~  (fn+Backspace)
            if bytes.count == 4, bytes[2] == 0x33, bytes[3] == 0x7E { return .deleteFile }
            // Shift+arrows: ESC [ 1 ; 2 A/B/C/D
            if bytes.count >= 6,
               bytes[2] == 0x31, bytes[3] == 0x3B, bytes[4] == 0x32 {
                switch bytes[5] {
                case 0x41: return .pan(dx:   0, dy: -40) // Shift+↑
                case 0x42: return .pan(dx:   0, dy:  40) // Shift+↓
                case 0x43: return .pan(dx: -40, dy:   0) // Shift+→
                case 0x44: return .pan(dx:  40, dy:   0) // Shift+←
                default:   return nil
                }
            }
        }

        // Russian 'о' (U+043E, UTF-8 0xD0 0xBE) — same physical key as 'o'
        if bytes.count == 2, bytes[0] == 0xD0, bytes[1] == 0xBE { return .resetZoom }
        // Russian 'а' (U+0430, UTF-8 0xD0 0xB0) — same physical key as 'f'
        if bytes.count == 2, bytes[0] == 0xD0, bytes[1] == 0xB0 { return .fitToWindow }

        return nil
    }
}
