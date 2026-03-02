import AppKit
import Darwin

guard CommandLine.arguments.count > 1 else {
    fputs("Usage: imgDirView <image-file>\n", stderr)
    exit(1)
}

let inputPath = CommandLine.arguments[1]

// Build absolute path as a plain Swift String — preserves the original NFC UTF-8 bytes
// from the shell (the bytes that NFS/kernel actually understands).
// Never pass through Foundation URL / NSString, which normalise to macOS NFD and break
// NFS lookups for characters like й (U+0439 NFC → и+combining breve NFD).
let absolutePath: String = {
    if inputPath.hasPrefix("/") { return inputPath }
    return FileManager.default.currentDirectoryPath + "/" + inputPath
}()

// Existence check via POSIX open() with raw C bytes — same as head/cat.
// FileManager.fileExists goes through Foundation (NFD-normalised) → fails on NFS.
func canOpen(_ path: String) -> Bool {
    let fd = path.withCString { Darwin.open($0, O_RDONLY) }
    if fd >= 0 { Darwin.close(fd); return true }
    return false
}

guard canOpen(inputPath) || canOpen(absolutePath) else {
    fputs("Cannot open file: \(absolutePath)\n  \(String(cString: strerror(errno)))\n", stderr)
    exit(1)
}

// Build a URL for AppKit display only; all POSIX I/O uses absolutePath (raw NFC string).
let fileURL = URL(fileURLWithPath: absolutePath)

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate(imageURL: fileURL, rawPath: absolutePath)
app.delegate = delegate
app.run()
