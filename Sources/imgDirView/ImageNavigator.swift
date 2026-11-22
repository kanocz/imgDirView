import AppKit
import Darwin

protocol ImageNavigatorDelegate: AnyObject {
    /// The file at `index` became current and is being read; the previous image is still on screen.
    func navigator(willLoadAt index: Int, total: Int, url: URL)
    func navigator(didLoad image: NSImage, index: Int, total: Int, url: URL)
    func navigator(didFailAt index: Int, total: Int, url: URL)
}

/// Reads a regular file through POSIX calls on the raw path bytes (see ImageNavigator
/// for why Foundation path APIs are avoided).
enum RawFile {
    /// Upper bound for one file held in memory.
    static let maxSize = 1 << 30

    static func read(_ rawPath: String) -> Data? {
        // O_NONBLOCK: opening a FIFO returns at once instead of waiting for a writer
        let fd = rawPath.withCString { Darwin.open($0, O_RDONLY | O_NONBLOCK) }
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }

        // Regular files only: a symlink to /dev/zero or a FIFO named x.png never reaches EOF
        var st = Darwin.stat()
        guard Darwin.fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }

        // st_size is only a capacity hint (NFS can report it stale); read until EOF
        var data = Data()
        data.reserveCapacity(min(max(Int(st.st_size), 0), maxSize))
        var buf = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let n = Darwin.read(fd, &buf, buf.count)
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if n == 0 { break }
            guard data.count + n <= maxSize else { return nil }
            data.append(buf, count: n)
        }
        return data.isEmpty ? nil : data
    }
}

extension String {
    /// Byte-exact identity of a raw path, for dictionary keys and comparisons. String equality
    /// is canonical ("й" in NFC equals "й" in NFD), so two files on NFS whose names differ
    /// only in normalisation would otherwise share one cache entry.
    var rawKey: Data { Data(utf8) }
}

/// Manages the list of images in a directory and their preloaded cache.
///
/// All filesystem operations use POSIX calls with raw Swift String → C-string
/// conversion (.withCString), which preserves the original NFC UTF-8 bytes
/// from the shell/NFS server. Foundation APIs (URL.withUnsafeFileSystemRepresentation,
/// FileManager.fileExists, url.resourceValues) normalise paths to macOS NFD,
/// which changes bytes for characters like й (U+0439) and breaks NFS lookups.
final class ImageNavigator {
    weak var delegate: ImageNavigatorDelegate?

    // List state is touched only on the main thread.
    // urls[i] — for display only (AppKit/delegate)
    // rawPaths[i] — for POSIX I/O (preserves original NFC bytes)
    private var urls: [URL] = []
    private var rawPaths: [String] = []
    private var currentIndex: Int = 0

    // Decoded images keyed by raw path, so entries stay valid when a deletion shifts indices.
    private var cache: [Data: NSImage] = [:]
    // Raw paths within ±2 of the current position; a queued load outside it is skipped.
    private var wanted: Set<Data> = []
    private let cacheLock = NSLock() // guards cache and wanted
    private let loadQueue = DispatchQueue(label: "imgdirview.load", qos: .userInitiated)

    private static let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "bmp",
        "tiff", "tif", "heic", "heif",
        "webp", "avif", "ico", "pnm", "pgm", "ppm"
    ]

    // MARK: - Init

    /// - Parameters:
    ///   - startURL: URL of the initial file (used by the delegate for display).
    ///   - rawPath:  Absolute POSIX path with original NFC bytes — used for all I/O.
    init(startURL: URL, rawPath: String) {
        // Split rawPath into directory + filename using pure string operations.
        // Never use NSString.deletingLastPathComponent or URL.deletingLastPathComponent
        // because they can alter the byte representation.
        let dirPath: String
        let targetName: String
        if let slashIdx = rawPath.lastIndex(of: "/") {
            dirPath = slashIdx == rawPath.startIndex ? "/" : String(rawPath[..<slashIdx])
            targetName = String(rawPath[rawPath.index(after: slashIdx)...])
        } else {
            dirPath = "."
            targetName = rawPath
        }

        // Scan directory via POSIX opendir/readdir using raw C-string bytes.
        var found: [(raw: String, url: URL)] = []

        dirPath.withCString { dirCStr in
            guard let dp = Darwin.opendir(dirCStr) else { return }
            defer { Darwin.closedir(dp) }

            while let entry = Darwin.readdir(dp) {
                // DT_UNKNOWN is common on NFS — allow it through
                let dType = entry.pointee.d_type
                guard dType == DT_REG || dType == DT_UNKNOWN || dType == DT_LNK else { continue }

                // d_name is a fixed C array; rebind to CChar for String conversion
                let name: String = withUnsafePointer(to: entry.pointee.d_name) { ptr in
                    ptr.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                        String(cString: $0)
                    }
                }

                guard !name.hasPrefix(".") else { continue }
                let ext = (name as NSString).pathExtension.lowercased()
                guard Self.supportedExtensions.contains(ext) else { continue }

                // Build full raw path by string concatenation (no Foundation)
                let fullRaw = (dirPath.hasSuffix("/") ? dirPath : dirPath + "/") + name
                // URL is used only by AppKit/delegate — normalization here is harmless
                let url = URL(fileURLWithPath: fullRaw)
                found.append((raw: fullRaw, url: url))
            }
        }

        // The requested file is always in the list: its extension may be one the scan
        // skips, or the scan itself may have failed (permissions).
        // On a case-insensitive volume the name may be typed in another case than the scan
        // returns it, so a byte-exact match is tried first and a case-insensitive one second.
        // A directory argument ends with "/" (see main.swift) and has no target name: nothing
        // is added for it, and the caller reports an empty list.
        let name: (String) -> String = { ($0 as NSString).lastPathComponent }
        var targetRaw = (found.first { name($0.raw).rawKey == targetName.rawKey }
            ?? found.first { name($0.raw).caseInsensitiveCompare(targetName) == .orderedSame })?.raw
        if targetRaw == nil, !targetName.isEmpty {
            found.append((raw: rawPath, url: startURL))
            targetRaw = rawPath
        }

        // Sort by filename using locale-aware comparison
        found.sort {
            ($0.raw as NSString).lastPathComponent
                .localizedStandardCompare(($1.raw as NSString).lastPathComponent)
            == .orderedAscending
        }

        rawPaths = found.map { $0.raw }
        urls     = found.map { $0.url }
        currentIndex = targetRaw.flatMap { target in
            rawPaths.firstIndex { $0.rawKey == target.rawKey }
        } ?? 0
    }

    // MARK: - Public API (main thread only)

    var count: Int { rawPaths.count }
    var index: Int { currentIndex }
    var currentRawPath: String? { rawPaths.indices.contains(currentIndex) ? rawPaths[currentIndex] : nil }
    var allRawPaths: [String] { rawPaths }

    func jumpTo(index: Int) {
        guard index >= 0, index < rawPaths.count else { return }
        currentIndex = index
    }

    /// Drop the entry at `index` (call after the file was trashed or deleted). The current
    /// position stays on the same file, or moves to its successor when the current file
    /// itself was removed. Does NOT call loadCurrent(). Returns false if the list is now empty.
    @discardableResult
    func removeAt(index: Int) -> Bool {
        guard index >= 0, index < rawPaths.count else { return !rawPaths.isEmpty }
        rawPaths.remove(at: index)
        urls.remove(at: index)
        if index < currentIndex { currentIndex -= 1 }
        currentIndex = min(currentIndex, max(0, rawPaths.count - 1))
        return !rawPaths.isEmpty
    }

    func loadCurrent() {
        guard let raw = currentRawPath else { return }
        let key = raw.rawKey
        trimCache()
        if cachedImage(key) == nil {
            delegate?.navigator(willLoadAt: currentIndex, total: count, url: urls[currentIndex])
        }
        load(rawPath: raw) { [weak self] image in
            guard let self else { return }
            // Drop results for a file that is no longer current (user moved on, or it was deleted)
            guard self.currentRawPath?.rawKey == key else { return }
            let idx = self.currentIndex
            let url = self.urls[idx]
            if let image {
                self.delegate?.navigator(didLoad: image, index: idx, total: self.count, url: url)
            } else {
                self.delegate?.navigator(didFailAt: idx, total: self.count, url: url)
            }
            self.preload(index: idx + 1)
            self.preload(index: idx - 1)
        }
    }

    func goToNext() {
        guard currentIndex < rawPaths.count - 1 else { return }
        currentIndex += 1
        loadCurrent()
    }

    func goToPrevious() {
        guard currentIndex > 0 else { return }
        currentIndex -= 1
        loadCurrent()
    }

    // MARK: - Private loading

    private func cachedImage(_ key: Data) -> NSImage? {
        cacheLock.withLock { cache[key] }
    }

    /// Keep only images within ±2 of the current position and publish that window to the loader.
    private func trimCache() {
        guard !rawPaths.isEmpty else { return }
        let lo = max(0, currentIndex - 2)
        let hi = min(rawPaths.count - 1, currentIndex + 2)
        let keep = Set(rawPaths[lo...hi].map(\.rawKey))
        cacheLock.withLock {
            wanted = keep
            cache = cache.filter { keep.contains($0.key) }
        }
    }

    /// Call on the main thread. Completion also runs on the main thread:
    /// synchronously on a cache hit, asynchronously otherwise. It is not called at all
    /// for a request that went stale in the queue (its file left the ±2 window).
    private func load(rawPath: String, completion: @escaping (NSImage?) -> Void) {
        let key = rawPath.rawKey
        if let image = cachedImage(key) { completion(image); return }

        loadQueue.async { [weak self] in
            guard let self else { return }
            // An earlier queued request for the same file may have filled the cache meanwhile
            let (cached, isWanted) = self.cacheLock.withLock {
                (self.cache[key], self.wanted.contains(key))
            }
            // The user moved on (a held arrow key on a slow disk queues one read per file):
            // skip the read so the queue drains. loadCurrent() puts the current file into
            // the window before it queues the request, so that request is never skipped.
            guard isWanted else { return }
            let image = cached ?? RawFile.read(rawPath).flatMap { NSImage(data: $0) }
            if let image { self.cacheLock.withLock { self.cache[key] = image } }
            DispatchQueue.main.async { completion(image) }
        }
    }

    private func preload(index: Int) {
        guard index >= 0, index < rawPaths.count else { return }
        load(rawPath: rawPaths[index]) { _ in }
    }
}
