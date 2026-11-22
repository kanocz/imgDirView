import AppKit
import Darwin

guard CommandLine.arguments.count > 1 else {
    fputs("Usage: imgDirView <image-file | directory>\n", stderr)
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

// Open the path with raw C bytes, the same way the loader does, and return its file type.
// FileManager.fileExists goes through Foundation (NFD-normalised) → fails on NFS.
// O_NONBLOCK keeps a FIFO from blocking the launch.
func probe(_ path: String) -> (error: Int32, type: mode_t) {
    path.withCString { cPath in
        let fd = Darwin.open(cPath, O_RDONLY | O_NONBLOCK)
        if fd < 0 { return (errno, 0) }
        defer { Darwin.close(fd) }
        var st = Darwin.stat()
        if Darwin.fstat(fd, &st) != 0 { return (errno, 0) }
        return (0, st.st_mode & S_IFMT)
    }
}

let (openError, fileType) = probe(absolutePath)
guard openError == 0 else {
    fputs("Cannot open: \(absolutePath)\n  \(String(cString: strerror(openError)))\n", stderr)
    exit(1)
}
// Anything else (FIFO, device) cannot be an image, and must not become a list entry
// that Backspace could then move to the Trash.
guard fileType == S_IFREG || fileType == S_IFDIR else {
    fputs("Not a file or directory: \(absolutePath)\n", stderr)
    exit(1)
}

// A directory is browsed from its first image. The trailing slash makes ImageNavigator
// scan the directory itself instead of treating it as a file inside its parent.
let rawPath = fileType == S_IFDIR && !absolutePath.hasSuffix("/") ? absolutePath + "/" : absolutePath

// Build a URL for AppKit display only; all POSIX I/O uses rawPath (raw NFC string).
let fileURL = URL(fileURLWithPath: rawPath)

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate(imageURL: fileURL, rawPath: rawPath)
app.delegate = delegate
app.run()
