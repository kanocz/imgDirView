import AppKit
import ImageIO

// MARK: - ThumbCell

final class ThumbCell: NSCollectionViewItem {

    private let imageBox = NSView()
    private let thumbImageView = NSImageView()
    private let label = NSTextField()

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 140))

        imageBox.wantsLayer = true
        imageBox.layer?.cornerRadius = 6
        imageBox.layer?.masksToBounds = true
        imageBox.layer?.backgroundColor = NSColor(white: 0.15, alpha: 1).cgColor
        view.addSubview(imageBox)

        thumbImageView.imageScaling = .scaleProportionallyUpOrDown
        thumbImageView.imageAlignment = .alignCenter
        thumbImageView.autoresizingMask = [.width, .height]
        imageBox.addSubview(thumbImageView)

        label.isEditable = false
        label.isSelectable = false
        label.isBezeled = false
        label.drawsBackground = false
        label.textColor = NSColor(white: 0.85, alpha: 1)
        label.font = .systemFont(ofSize: 10)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        view.addSubview(label)
    }

    override var isSelected: Bool {
        didSet { updateBorder() }
    }

    private func updateBorder() {
        imageBox.layer?.borderWidth = isSelected ? 2.5 : 0
        imageBox.layer?.borderColor = isSelected ? NSColor.controlAccentColor.cgColor : nil
    }

    func configure(image: NSImage?, filename: String) {
        thumbImageView.image = image
        label.stringValue = filename
    }

    override func viewWillLayout() {
        super.viewWillLayout()
        let b = view.bounds
        let labelH: CGFloat = 18
        imageBox.frame = CGRect(x: 0, y: labelH + 4, width: b.width, height: b.height - labelH - 4)
        thumbImageView.frame = imageBox.bounds
        label.frame = CGRect(x: 0, y: 0, width: b.width, height: labelH)
    }
}

// MARK: - ThumbnailBrowserView

final class ThumbnailBrowserView: NSView {

    var onOpen:    ((Int) -> Void)?
    var onDelete:  ((Int) -> Void)?
    var onDismiss: (() -> Void)?

    private var rawPaths: [String] = []
    private var columnCount = 5
    private var selectedIndex = 0
    // Keyed by raw path, so entries stay valid when a deletion shifts indices
    private var thumbnails: [Data: NSImage] = [:]
    private var loadingPaths = Set<Data>()
    private static let maxThumbnails = 500

    private let scrollView = NSScrollView()
    private var collectionView: NSCollectionView!
    // Each load holds a whole file in memory and blocks on I/O: cap the parallelism
    private let loadQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = ProcessInfo.processInfo.activeProcessorCount
        q.qualityOfService = .userInitiated
        return q
    }()

    private static let cellID = NSUserInterfaceItemIdentifier("ThumbCell")

    // MARK: - Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.05, alpha: 0.95).cgColor

        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

        collectionView = NSCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.backgroundColors = [.clear]
        collectionView.register(ThumbCell.self, forItemWithIdentifier: Self.cellID)

        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.autoresizingMask = [.width, .height]
        scrollView.frame = bounds
        addSubview(scrollView)

        let dblClick = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleClick(_:)))
        dblClick.numberOfClicksRequired = 2
        collectionView.addGestureRecognizer(dblClick)
    }

    // MARK: - Public API

    func load(rawPaths: [String], selectedIndex: Int) {
        self.rawPaths = rawPaths
        self.selectedIndex = max(0, min(selectedIndex, rawPaths.count - 1))
        thumbnails = [:]
        loadingPaths = []
        collectionView.reloadData()
        updateLayout()
        DispatchQueue.main.async { self.selectAndReveal(self.selectedIndex) }
    }

    func removeItem(at index: Int) {
        guard index >= 0, index < rawPaths.count else { return }
        thumbnails[rawPaths[index].rawKey] = nil
        rawPaths.remove(at: index)

        if index < selectedIndex { selectedIndex -= 1 }
        if !rawPaths.isEmpty {
            selectedIndex = max(0, min(selectedIndex, rawPaths.count - 1))
        }
        collectionView.reloadData()
        if !rawPaths.isEmpty {
            DispatchQueue.main.async { self.selectAndReveal(self.selectedIndex) }
        }
    }

    var currentSelectedIndex: Int { selectedIndex }

    func adjustColumns(by delta: Int) {
        columnCount = max(1, min(10, columnCount + delta))
        updateLayout()
        DispatchQueue.main.async { self.selectAndReveal(self.selectedIndex) }
    }

    // MARK: - Key handling (called from ImageWindowController)

    @discardableResult
    func handleKey(_ keyCode: UInt16, shift: Bool) -> Bool {
        switch keyCode {
        case 49:       onDismiss?()           // Space → return to single view
        case 36, 76:   onOpen?(selectedIndex) // Return / KP-Enter → open
        case 51, 117:  onDelete?(selectedIndex) // Backspace / Delete
        case 24:       adjustColumns(by: -1)  // + → bigger (fewer columns)
        case 27:       adjustColumns(by: +1)  // - → smaller (more columns)
        case 123:      move(by: -1)           // ←
        case 124:      move(by: +1)           // →
        case 125:      move(by: +columnCount) // ↓
        case 126:      move(by: -columnCount) // ↑
        default: return false
        }
        return true
    }

    // MARK: - Layout

    private func updateLayout() {
        guard let layout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout else { return }
        let inset = layout.sectionInset
        let spacing = layout.minimumInteritemSpacing
        let available = bounds.width - inset.left - inset.right
                         - spacing * CGFloat(columnCount - 1)
        let w = max(50, floor(available / CGFloat(columnCount)))
        layout.itemSize = CGSize(width: w, height: w + 22)
        layout.invalidateLayout()
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        updateLayout()
    }

    // MARK: - Navigation

    private func move(by delta: Int) {
        guard !rawPaths.isEmpty else { return }
        selectedIndex = max(0, min(rawPaths.count - 1, selectedIndex + delta))
        selectAndReveal(selectedIndex)
    }

    private func selectAndReveal(_ index: Int) {
        guard index >= 0, index < rawPaths.count else { return }
        let ip = IndexPath(item: index, section: 0)
        collectionView.deselectAll(nil)
        collectionView.selectItems(at: [ip], scrollPosition: [])
        collectionView.scrollToItems(at: [ip], scrollPosition: .nearestHorizontalEdge)
    }

    // MARK: - Thumbnail loading

    private func loadThumbnail(at index: Int) {
        guard index >= 0, index < rawPaths.count else { return }
        let raw = rawPaths[index]
        let key = raw.rawKey
        guard thumbnails[key] == nil, !loadingPaths.contains(key) else { return }
        loadingPaths.insert(key)

        loadQueue.addOperation { [weak self] in
            let img = Self.makeThumbnail(rawPath: raw, maxDimension: 400)
            DispatchQueue.main.async {
                guard let self else { return }
                self.loadingPaths.remove(key)
                // A deletion may have shifted the item while it was loading
                let item = index < self.rawPaths.count && self.rawPaths[index].rawKey == key
                    ? index : self.rawPaths.firstIndex { $0.rawKey == key }
                guard let item else { return }
                // ponytail: crude bound, drops every thumbnail at the limit. Cells on screen keep
                // their image and the rest reload on scroll. Switch to LRU if the reloads show.
                if self.thumbnails.count >= Self.maxThumbnails { self.thumbnails.removeAll() }
                self.thumbnails[key] = img ?? NSImage()
                self.collectionView.reloadItems(at: [IndexPath(item: item, section: 0)])
            }
        }
    }

    private static func makeThumbnail(rawPath: String, maxDimension: Int) -> NSImage? {
        guard let data = RawFile.read(rawPath),
              let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let size = NSSize(width: cg.width, height: cg.height)
        switch cg.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return NSImage(cgImage: cg, size: size)
        default:
            // Has an alpha channel: bake the checkerboard under the thumbnail
            return NSImage(size: size, flipped: false) { rect in
                NSColor.checkerboard.setFill()
                rect.fill()
                NSGraphicsContext.current?.cgContext.draw(cg, in: rect)
                return true
            }
        }
    }

    // MARK: - Double-click

    @objc private func handleDoubleClick(_ gr: NSClickGestureRecognizer) {
        let pt = gr.location(in: collectionView)
        guard let ip = collectionView.indexPathForItem(at: pt) else { return }
        onOpen?(ip.item)
    }
}

// MARK: - NSCollectionViewDataSource

extension ThumbnailBrowserView: NSCollectionViewDataSource {

    func collectionView(_ collectionView: NSCollectionView,
                        numberOfItemsInSection section: Int) -> Int {
        rawPaths.count
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(withIdentifier: Self.cellID,
                                           for: indexPath) as! ThumbCell
        let idx = indexPath.item
        cell.configure(image: thumbnails[rawPaths[idx].rawKey],
                       filename: (rawPaths[idx] as NSString).lastPathComponent)
        loadThumbnail(at: idx)
        return cell
    }
}

// MARK: - NSCollectionViewDelegate

extension ThumbnailBrowserView: NSCollectionViewDelegate {

    func collectionView(_ collectionView: NSCollectionView,
                        didSelectItemsAt indexPaths: Set<IndexPath>) {
        if let ip = indexPaths.first { selectedIndex = ip.item }
    }
}
