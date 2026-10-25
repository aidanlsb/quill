import AppKit
import ImageIO
import QuillMarkdown
import QuillVim

/// Bitmap published from a background decode. `CGImage` does not change after init.
// quill-concurrency: CGImage is immutable after creation and is only read once published.
final class ImageBitmapBox: @unchecked Sendable {
    let image: CGImage
    let width: Int
    let height: Int

    init(_ image: CGImage) {
        self.image = image
        self.width = image.width
        self.height = image.height
    }
}

/// One preview under a source line. Not part of the text storage.
final class ImageBlockView: NSView {
    var sourceLine = 0
    var destination = ""
    var alt = ""
    var failed = false
    var fill: NSColor = .clear
    var stroke: NSColor = .separatorColor
    var caption: NSColor = .secondaryLabelColor
    private var bitmap: CGImage?
    private var rendered: NSImage?

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var showsImage: Bool { bitmap != nil }

    func setBitmap(_ image: CGImage?) {
        bitmap = image
        rendered = image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        guard rect.width > 1, rect.height > 1 else { return }
        let path = NSBezierPath(roundedRect: rect, xRadius: ImageFit.cornerRadius, yRadius: ImageFit.cornerRadius)
        fill.setFill()
        path.fill()
        if let rendered {
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            rendered.draw(
                in: bounds.insetBy(dx: 1, dy: 1),
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
            NSGraphicsContext.restoreGraphicsState()
        } else {
            let label = alt.isEmpty ? (failed ? "missing" : "image") : alt
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.lineBreakMode = .byTruncatingTail
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: caption,
                .paragraphStyle: style,
            ]
            let textRect = bounds.insetBy(dx: 12, dy: 8)
            (label as NSString).draw(in: textRect, withAttributes: attrs)
        }
        stroke.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

enum ImageDecoder {
    static func file(path: String, maxPixel: Int) -> (image: ImageBitmapBox, modified: Int64)? {
        guard let modified = mtime(path) else { return nil }
        let image: CGImage?
        if path.lowercased().hasSuffix(".pdf") {
            image = pdf(path: path, maxPixel: maxPixel)
        } else {
            image = thumbnail(url: URL(fileURLWithPath: path) as CFURL, maxPixel: maxPixel)
        }
        guard let image else { return nil }
        return (ImageBitmapBox(image), modified)
    }

    static func remote(url: URL, maxPixel: Int) async -> ImageBitmapBox? {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.cachePolicy = .returnCacheDataElseLoad
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return nil
            }
            if data.count > 20 * 1024 * 1024 { return nil }
            guard let image = thumbnail(data: data as CFData, maxPixel: maxPixel) else { return nil }
            return ImageBitmapBox(image)
        } catch {
            return nil
        }
    }

    static func mtime(_ path: String) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let date = attrs[.modificationDate] as? Date else { return nil }
        return Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private static func thumbnail(url: CFURL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
        return thumbnail(source: source, maxPixel: maxPixel)
    }

    private static func thumbnail(data: CFData, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data, nil) else { return nil }
        return thumbnail(source: source, maxPixel: maxPixel)
    }

    private static func thumbnail(source: CGImageSource, maxPixel: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// First page, scaled down to `maxPixel` on the long edge.
    private static func pdf(path: String, maxPixel: Int) -> CGImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let document = CGPDFDocument(url), let page = document.page(at: 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        guard box.width > 1, box.height > 1 else { return nil }
        let scale = min(1, CGFloat(maxPixel) / max(box.width, box.height))
        let width = max(1, Int((box.width * scale).rounded(.up)))
        let height = max(1, Int((box.height * scale).rounded(.up)))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        ) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -box.origin.x, y: -box.origin.y)
        context.drawPDFPage(page)
        return context.makeImage()
    }
}

/// Places image previews under `![alt](path)` lines.
///
/// The source line stays ordinary text. The preview's height is paragraph
/// spacing, so TextKit's next line starts below it and `j` / `k` step from
/// the source line to that next line. Nothing is inserted into the storage,
/// so motions, operators, search, LSP offsets, and undo keep the same coordinates.
/// `ImageScreenRows` is the same gap expressed as screen rows for `ScreenModel`.
@MainActor
final class ImagePreviewController {
    weak var textView: VimTextView?
    var enabled = true
    var filePath: String?
    private(set) var blockViews: [ImageBlockView] = []

    private var found: [MarkdownImage] = []
    private var textDirty = true
    private var extraByLine: [Int: CGFloat] = [:]
    private var refreshScheduled = false
    private var refreshing = false
    private var refreshAgain = false
    private var cache = ImageCache<ImageBitmapBox>(limit: 64)
    private var inflight: Set<String> = []
    private var failed: Set<String> = []
    private var checked: [String: Date] = [:]
    private var home = NSHomeDirectory()

    var reservedHeight: CGFloat {
        extraByLine.values.reduce(0, +)
    }

    /// Screen rows the preview occupies. `j` / `k` cross all of them at once.
    func gapRows(on line: Int, rowHeight: CGFloat) -> Int {
        guard let extra = extraByLine[line], extra > 0.5 else { return 0 }
        return ImageFit.screenRows(height: Double(extra), rowHeight: Double(max(rowHeight, 1)))
    }

    func heightBefore(line: Int) -> CGFloat {
        extraByLine.reduce(0) { partial, item in
            item.key < line ? partial + item.value : partial
        }
    }

    func attach(_ textView: VimTextView) {
        self.textView = textView
    }

    func setContext(enabled: Bool, filePath: String?) {
        let pathChanged = self.filePath != filePath
        self.filePath = filePath
        if pathChanged {
            failed.removeAll()
            checked.removeAll()
            textDirty = true
        }
        if self.enabled != enabled {
            self.enabled = enabled
            if !enabled {
                tearDown()
            } else {
                textDirty = true
                scheduleRefresh()
            }
        } else if pathChanged, enabled {
            scheduleRefresh()
        }
    }

    func noteDocumentReplaced() {
        guard enabled else { return }
        found = []
        failed.removeAll()
        checked.removeAll()
        extraByLine = [:]
        removeViews()
        textDirty = true
        scheduleRefresh()
    }

    func noteEdits(_ edits: [TextEdit]) {
        guard enabled else { return }
        if found.isEmpty, !edits.contains(where: { $0.replacement.contains("![") }) {
            return
        }
        textDirty = true
        failed.removeAll()
        scheduleRefresh()
    }

    func scheduleRefresh() {
        guard enabled, !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    func flush() {
        refreshScheduled = false
        refresh()
    }

    func reposition() {
        guard enabled, !blockViews.isEmpty else { return }
        placeViews(ensure: false)
    }

    func restoreSpacing(in limit: Range<Int>?) {
        guard enabled, !extraByLine.isEmpty else { return }
        applySpacing(only: limit)
    }

    func applyTheme() {
        guard let tv = textView else { return }
        for view in blockViews {
            paint(view, theme: tv.theme)
            view.needsDisplay = true
        }
    }

    private func tearDown() {
        let lines = Array(extraByLine.keys)
        extraByLine = [:]
        found = []
        removeViews()
        guard let tv = textView, let storage = tv.textStorage else { return }
        storage.beginEditing()
        for line in lines {
            writeSpacing(0, line: line, storage: storage)
        }
        storage.endEditing()
        tv.noteContentSizeChanged()
    }

    private func refresh() {
        if refreshing {
            refreshAgain = true
            return
        }
        refreshing = true
        defer {
            refreshing = false
            if refreshAgain {
                refreshAgain = false
                refresh()
            }
        }
        guard let tv = textView, enabled, !tv.isDirectoryBuffer else {
            if enabled == false || textView?.isDirectoryBuffer == true {
                if !extraByLine.isEmpty || !blockViews.isEmpty { tearDown() }
            }
            return
        }
        if textDirty {
            textDirty = false
            let text = tv.string
            found = text.contains("![") ? MarkdownImages.find(in: text) : []
        }
        let bands = lineBands()
        var heights: [Int: [Double]] = [:]
        var visible: [MarkdownImage] = []
        for image in found {
            guard bands.spacing.contains(image.line) else { continue }
            let resolved = ImagePaths.resolve(image.destination, filePath: filePath, home: home)
            let known = resolved.flatMap { self.cached($0.identity) }
            let height: Double
            if let known {
                let size = ImageFit.displaySize(
                    pixelWidth: known.value.width,
                    pixelHeight: known.value.height,
                    columnWidth: Double(columnWidth)
                )
                height = size.height
            } else {
                height = ImageFit.placeholderHeight
            }
            heights[image.line, default: []].append(height)
            if bands.visible.contains(image.line) {
                visible.append(image)
            }
        }
        var next: [Int: CGFloat] = [:]
        for (line, values) in heights {
            next[line] = CGFloat(ImageFit.spacing(heights: values))
        }
        let previous = extraByLine
        extraByLine = next
        if previous != next {
            applySpacing(only: nil)
            zeroSpacing(on: previous.keys.filter { next[$0] == nil })
            tv.noteContentSizeChanged()
            tv.layoutSubtreeIfNeeded()
            tv.textLayoutManager?.textViewportLayoutController.layoutViewport()
        }
        syncViews(visible)
        placeViews(ensure: true)
        loadVisible(visible)
    }

    private struct Bands {
        var spacing: Range<Int>
        var visible: Range<Int>
    }

    /// Spacing covers a margin around the clip so a scroll doesn't overlap the
    /// next line. Views and decodes stay on the visible lines.
    private func lineBands() -> Bands {
        guard let tv = textView, let engine = tv.engine else { return Bands(spacing: 0..<0, visible: 0..<0) }
        let count = engine.buffer.lineCount
        guard count > 0 else { return Bands(spacing: 0..<0, visible: 0..<0) }
        let row = max(tv.bodyRowHeight(), 1)
        let clip = tv.enclosingScrollView?.contentView.bounds ?? tv.bounds
        let originY = tv.textContainerOrigin.y
        let top = (clip.height > 2 ? clip.minY : 0) - originY
        let bottom = (clip.height > 2 ? clip.maxY : top + 600) - originY
        var y: CGFloat = 0
        var visibleLower = 0
        var visibleUpper = 1
        var started = false
        for line in 0..<count {
            let next = y + row + (extraByLine[line] ?? 0)
            if !started, next >= top - row * 2 {
                visibleLower = line
                started = true
            }
            if started { visibleUpper = line + 1 }
            y = next
            if started, y > bottom + row * 2 { break }
        }
        let spacingLower = max(0, visibleLower - 40)
        let spacingUpper = min(count, visibleUpper + 40)
        return Bands(
            spacing: spacingLower..<max(spacingLower, spacingUpper),
            visible: visibleLower..<max(visibleLower, min(count, visibleUpper))
        )
    }

    private var columnWidth: CGFloat {
        guard let tv = textView else { return 640 }
        let width = tv.textContainer?.size.width ?? 0
        if width > 1, width < 100_000 { return width }
        return max(1, tv.columnWidth)
    }

    private var maxPixel: Int {
        let scale = textView?.window?.backingScaleFactor ?? 2
        return min(2048, max(64, Int((columnWidth * scale).rounded(.up))))
    }

    private func applySpacing(only limit: Range<Int>?) {
        guard let tv = textView, let storage = tv.textStorage, let engine = tv.engine else { return }
        storage.beginEditing()
        for (line, extra) in extraByLine {
            guard line >= 0, line < engine.buffer.lineCount else { continue }
            let span = engine.buffer.lineFullRange(at: line)
            if let limit, span.upperBound <= limit.lowerBound || span.lowerBound >= limit.upperBound {
                continue
            }
            writeSpacing(extra, line: line, storage: storage)
        }
        storage.endEditing()
    }

    private func zeroSpacing(on lines: [Int]) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        guard !lines.isEmpty else { return }
        storage.beginEditing()
        for line in lines {
            writeSpacing(0, line: line, storage: storage)
        }
        storage.endEditing()
    }

    private func writeSpacing(_ extra: CGFloat, line: Int, storage: NSTextStorage) {
        guard let tv = textView, let engine = tv.engine else { return }
        guard line >= 0, line < engine.buffer.lineCount else { return }
        let span = engine.buffer.lineFullRange(at: line)
        guard !span.isEmpty else { return }
        let range = tv.nsRange(span)
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
        let current = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
        if let current, abs(current.paragraphSpacing - extra) < 0.5, abs(current.lineHeightMultiple - tv.theme.lineHeight) < 0.01 {
            return
        }
        let style = (current?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        style.lineHeightMultiple = tv.theme.lineHeight
        if extra > 0.5 {
            style.paragraphSpacing = extra
        } else if let current, current.firstLineHeadIndent > 0.5 {
            style.paragraphSpacing = tv.theme.listItemSpacing
        } else {
            style.paragraphSpacing = extra
        }
        storage.addAttribute(.paragraphStyle, value: style, range: range)
    }

    private func syncViews(_ images: [MarkdownImage]) {
        guard let tv = textView else { return }
        var pool = blockViews
        var ordered: [ImageBlockView] = []
        for image in images {
            let view: ImageBlockView
            if let index = pool.firstIndex(where: { $0.sourceLine == image.line && $0.destination == image.destination }) {
                view = pool.remove(at: index)
            } else {
                view = ImageBlockView(frame: .zero)
            }
            view.sourceLine = image.line
            view.destination = image.destination
            view.alt = image.alt
            paint(view, theme: tv.theme)
            if view.superview !== tv {
                tv.addSubview(view)
            }
            ordered.append(view)
        }
        for view in blockViews where view.superview != nil && !ordered.contains(where: { $0 === view }) {
            view.removeFromSuperview()
        }
        blockViews = ordered
    }

    private func paint(_ view: ImageBlockView, theme: QuillTheme) {
        view.fill = theme.tableBackground
        view.stroke = theme.syntaxColor.withAlphaComponent(0.35)
        view.caption = theme.dimColor
    }

    private func placeViews(ensure: Bool) {
        guard let tv = textView, let engine = tv.engine else { return }
        let width = columnWidth
        let originX = tv.textContainerOrigin.x
        var index = 0
        while index < blockViews.count {
            let line = blockViews[index].sourceLine
            var group: [ImageBlockView] = []
            while index < blockViews.count, blockViews[index].sourceLine == line {
                group.append(blockViews[index])
                index += 1
            }
            guard let metrics = lineMetrics(line, ensure: ensure) else { continue }
            let nextTop: CGFloat
            if line + 1 < engine.buffer.lineCount, let next = lineMetrics(line + 1, ensure: ensure) {
                nextTop = next.top
            } else {
                nextTop = metrics.textBottom + (extraByLine[line] ?? 0)
            }
            var y = metrics.textBottom + CGFloat(ImageFit.verticalGap)
            let limit = max(y, nextTop - CGFloat(ImageFit.verticalGap))
            for view in group {
                let resolved = ImagePaths.resolve(view.destination, filePath: filePath, home: home)
                let box = resolved.flatMap { self.cached($0.identity)?.value }
                let size = ImageFit.displaySize(
                    pixelWidth: box?.width ?? 0,
                    pixelHeight: box?.height ?? 0,
                    columnWidth: Double(width)
                )
                var height = CGFloat(size.height)
                if y + height > limit, limit > y {
                    height = max(1, limit - y)
                }
                let viewWidth = min(CGFloat(size.width), width)
                let x = originX + (width - viewWidth) / 2
                view.frame = NSRect(x: x, y: y, width: viewWidth, height: height)
                y += height + CGFloat(ImageFit.verticalGap)
            }
        }
    }

    private struct LineMetrics {
        var top: CGFloat
        var textBottom: CGFloat
    }

    private func lineMetrics(_ line: Int, ensure: Bool) -> LineMetrics? {
        guard let tv = textView, let lm = tv.textLayoutManager, let engine = tv.engine else { return nil }
        guard line >= 0, line < engine.buffer.lineCount else { return nil }
        let length = (tv.string as NSString).length
        guard length > 0 else { return nil }
        let start = engine.buffer.line(line).start
        let probe = min(max(0, start), length - 1)
        let doc = lm.documentRange.location
        guard let location = lm.location(doc, offsetBy: probe) else { return nil }
        if ensure {
            lm.enumerateTextLayoutFragments(from: location, options: [.ensuresLayout]) { _ in false }
        }
        guard let fragment = lm.textLayoutFragment(for: location) else { return nil }
        let fragmentStart = lm.offset(from: doc, to: fragment.rangeInElement.location)
        let fragmentEnd = lm.offset(from: doc, to: fragment.rangeInElement.endLocation)
        if fragmentStart == NSNotFound || fragmentEnd == NSNotFound { return nil }
        if probe < fragmentStart || probe >= fragmentEnd { return nil }
        let frame = fragment.layoutFragmentFrame
        let container = tv.textContainerOrigin
        let lines = fragment.textLineFragments
        let textBottom: CGFloat
        if let last = lines.last(where: { $0.characterRange.length > 0 }) ?? lines.last {
            textBottom = container.y + frame.minY + last.typographicBounds.maxY
        } else {
            textBottom = container.y + frame.maxY
        }
        return LineMetrics(top: container.y + frame.minY, textBottom: textBottom)
    }

    private func cached(_ identity: String) -> (modified: Int64?, value: ImageBitmapBox)? {
        cache.stored(identity: identity)
    }

    private func loadVisible(_ images: [MarkdownImage]) {
        var seen: Set<String> = []
        for image in images {
            guard let resolved = ImagePaths.resolve(image.destination, filePath: filePath, home: home) else {
                markUnresolved(image)
                continue
            }
            let identity = resolved.identity
            if !seen.insert(identity).inserted { continue }
            if failed.contains(identity) { continue }
            if inflight.contains(identity) { continue }
            if let stored = cache.stored(identity: identity) {
                let recent = checked[identity].map { Date().timeIntervalSince($0) < 1 } ?? false
                if recent || resolved.isRemote {
                    apply(stored.value, identity: identity, failed: false)
                    continue
                }
            }
            startLoad(resolved)
        }
    }

    private func markUnresolved(_ image: MarkdownImage) {
        for view in blockViews where view.sourceLine == image.line && view.destination == image.destination {
            view.failed = true
            view.setBitmap(nil)
        }
    }

    private func startLoad(_ resolved: ResolvedImage) {
        let identity = resolved.identity
        inflight.insert(identity)
        let pixel = maxPixel
        let known = cache.stored(identity: identity)
        Task { [weak self] in
            let loaded: (ImageBitmapBox?, Int64?) = await Self.decode(
                resolved,
                maxPixel: pixel,
                known: known?.value,
                knownModified: known?.modified
            )
            self?.finish(identity: identity, image: loaded.0, modified: loaded.1)
        }
    }

    nonisolated private static func decode(
        _ resolved: ResolvedImage,
        maxPixel: Int,
        known: ImageBitmapBox?,
        knownModified: Int64?
    ) async -> (ImageBitmapBox?, Int64?) {
        switch resolved {
        case .local(let path):
            let modified = ImageDecoder.mtime(path)
            if let modified, let known, knownModified == modified {
                return (known, modified)
            }
            guard let modified else { return (nil, nil) }
            if let file = ImageDecoder.file(path: path, maxPixel: maxPixel) {
                return (file.image, file.modified)
            }
            return (nil, modified)
        case .remote(let url):
            if let known, knownModified == nil { return (known, nil) }
            guard let url = URL(string: url) else { return (nil, nil) }
            if let image = await ImageDecoder.remote(url: url, maxPixel: maxPixel) {
                return (image, nil)
            }
            return (nil, nil)
        }
    }

    private func finish(identity: String, image: ImageBitmapBox?, modified: Int64?) {
        inflight.remove(identity)
        checked[identity] = Date()
        if let image {
            failed.remove(identity)
            cache.store(image, for: .init(identity: identity, modified: modified))
            apply(image, identity: identity, failed: false)
            refresh()
        } else {
            failed.insert(identity)
            apply(nil, identity: identity, failed: true)
        }
    }

    private func apply(_ image: ImageBitmapBox?, identity: String, failed: Bool) {
        for view in blockViews {
            guard let resolved = ImagePaths.resolve(view.destination, filePath: filePath, home: home) else { continue }
            guard resolved.identity == identity else { continue }
            view.failed = failed
            view.setBitmap(image?.image)
        }
    }

    private func removeViews() {
        for view in blockViews {
            view.removeFromSuperview()
        }
        blockViews = []
    }
}

private extension ResolvedImage {
    var isRemote: Bool {
        if case .remote = self { return true }
        return false
    }
}
