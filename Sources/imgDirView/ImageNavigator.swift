import AppKit
import Darwin

protocol ImageNavigatorDelegate: AnyObject {
    func navigator(didLoad image: NSImage, index: Int, total: Int, url: URL)
    func navigator(didFailAt index: Int, total: Int, url: URL)
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

    // urls[i] — for display only (AppKit/delegate)
    // rawPaths[i] — for POSIX I/O (preserves original NFC bytes)
    private var urls: [URL] = []
    private var rawPaths: [String] = []

    private var currentIndex: Int = 0
    private var cache: [Int: NSImage] = [:]
    private let loadQueue  = DispatchQueue(label: "imgdirview.load",  qos: .userInitiated)
    private let cacheQueue = DispatchQueue(label: "imgdirview.cache", attributes: .concurrent)

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
            dirPath = String(rawPath[..<slashIdx])
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
                let fullRaw = dirPath + "/" + name
                // URL is used only by AppKit/delegate — normalization here is harmless
                let url = URL(fileURLWithPath: fullRaw)
                found.append((raw: fullRaw, url: url))
            }
        }

        // Sort by filename using locale-aware comparison
        found.sort {
            ($0.raw as NSString).lastPathComponent
                .localizedStandardCompare(($1.raw as NSString).lastPathComponent)
            == .orderedAscending
        }

        rawPaths = found.map { $0.raw }
        urls      = found.map { $0.url }

        if rawPaths.isEmpty {
            // Directory scan failed (permissions, empty dir) — single-file fallback
            rawPaths = [rawPath]
            urls     = [startURL]
            currentIndex = 0
        } else {
            currentIndex = rawPaths.firstIndex(where: {
                ($0 as NSString).lastPathComponent == targetName
            }) ?? 0
        }
    }

    // MARK: - Public API

    var count: Int { rawPaths.count }
    var index: Int { currentIndex }
    var currentRawPath: String? { rawPaths.isEmpty ? nil : rawPaths[currentIndex] }

    func loadCurrent() {
        let idx = currentIndex
        load(index: idx) { [weak self] image in
            guard let self else { return }
            let url = self.urls[idx]
            DispatchQueue.main.async {
                if let image {
                    self.delegate?.navigator(didLoad: image, index: idx, total: self.count, url: url)
                } else {
                    self.delegate?.navigator(didFailAt: idx, total: self.count, url: url)
                }
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

    /// Remove the current file from the list (call after successful trash/delete)
    /// and load the new current image. Returns false if the list is now empty.
    @discardableResult
    func removeCurrentAndLoad() -> Bool {
        guard !rawPaths.isEmpty else { return false }
        rawPaths.remove(at: currentIndex)
        urls.remove(at: currentIndex)
        // All cache indices have shifted — simplest fix is to clear entirely
        cacheQueue.async(flags: .barrier) { self.cache = [:] }
        guard !rawPaths.isEmpty else { return false }
        if currentIndex >= rawPaths.count { currentIndex = rawPaths.count - 1 }
        loadCurrent()
        return true
    }

    // MARK: - Private loading

    private func load(index: Int, completion: @escaping (NSImage?) -> Void) {
        guard index >= 0, index < rawPaths.count else { completion(nil); return }

        cacheQueue.sync {
            if let img = self.cache[index] { completion(img); return }
        }

        loadQueue.async { [weak self] in
            guard let self else { return }

            var cached: NSImage?
            self.cacheQueue.sync { cached = self.cache[index] }
            if let cached { completion(cached); return }

            let raw = self.rawPaths[index]
            guard let image = Self.readImage(rawPath: raw) else {
                completion(nil)
                return
            }

            self.cacheQueue.async(flags: .barrier) {
                self.cache[index] = image
                let keep = Set((self.currentIndex - 2)...(self.currentIndex + 2))
                self.cache = self.cache.filter { keep.contains($0.key) }
            }
            completion(image)
        }
    }

    /// Open and read an image file using raw POSIX calls with the original NFC path bytes.
    private static func readImage(rawPath: String) -> NSImage? {
        // Use withCString: Swift converts the String to UTF-8 bytes WITHOUT
        // any Unicode normalisation — the same bytes the NFS kernel path lookup uses.
        return rawPath.withCString { cPath -> NSImage? in
            let fd = Darwin.open(cPath, O_RDONLY)
            guard fd >= 0 else { return nil }
            defer { Darwin.close(fd) }

            // fstat for a single-allocation read
            var st = Darwin.stat()
            var data = Data()

            if Darwin.fstat(fd, &st) == 0, st.st_size > 0 {
                let size = Int(st.st_size)
                data = Data(count: size)
                let n = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, size) }
                if n != size { data = Data() } // partial read → fall through to chunked
            }

            // Chunked fallback (NFS fstat size unreliable, or partial read above)
            if data.isEmpty {
                let chunk = 131072
                var buf = [UInt8](repeating: 0, count: chunk)
                while true {
                    let n = Darwin.read(fd, &buf, chunk)
                    if n <= 0 { break }
                    data.append(contentsOf: buf.prefix(n))
                }
            }

            guard !data.isEmpty else { return nil }
            return NSImage(data: data)
        }
    }

    private func preload(index: Int) {
        guard index >= 0, index < rawPaths.count else { return }
        load(index: index) { _ in }
    }
}
