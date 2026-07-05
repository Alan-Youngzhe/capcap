import AppKit

/// Where a pinned image was loaded from — drives the X-key "close and clear
/// source" behavior so a stale Finder selection or clipboard image won't keep
/// re-pinning on the next hotkey press.
enum PinSource {
    case finder
    case clipboard
    case clipboardText
}

/// A borderless, always-on-top window that holds a pinned image. Unlike a plain
/// borderless `NSWindow` it can become key, so it receives keystrokes: Esc
/// closes it, X closes it and clears the source it came from.
final class PinWindow: NSWindow {
    /// Set when the pin came from a hotkey press. nil for editor-created pins,
    /// which have no external source to clear.
    var pinSource: PinSource?

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        (contentView as? TextPinContentView)?.commitTextEditingIfNeeded()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 7: // X — close and clear the originating source.
            dismissClearingSource()
        case 53: // Esc — close only.
            dismiss()
        default:
            super.keyDown(with: event)
        }
    }

    /// Tears the window down and drops it from the manager so it deallocates.
    func dismiss() {
        orderOut(nil)
        contentView = nil
        PinWindowManager.shared.remove(self)
    }

    func dismissClearingSource() {
        clearSource()
        dismiss()
    }

    private func clearSource() {
        switch pinSource {
        case .finder:
            FinderSelection.clearSelection()
        case .clipboard, .clipboardText:
            ClipboardImageSource.clear()
        case nil:
            break
        }
    }
}

/// Builds pinned-image windows. Used by the editor's pin button and by the
/// source-specific global pin hotkeys.
enum PinLauncher {
    private static let stackOffset = NSSize(width: 28, height: -28)
    private static let maxDistinctStackOffsets = 8

    /// Pins plain text currently on the clipboard as an editable text view.
    @discardableResult
    static func pinClipboardTextIfAvailable() -> Bool {
        guard let text = ClipboardTextSource.currentText() else {
            ToastWindow.show(message: L10n.clipboardTextPinNoText)
            return false
        }

        pin(text: text, source: .clipboardText)
        ToastWindow.show(message: L10n.pinFromClipboardTextHint)
        return true
    }

    /// Creates a floating pinned window for `image`. When `origin` is nil the
    /// window is centered on the screen under the cursor. Oversized images are
    /// scaled down to fit the screen.
    static func pin(image: NSImage, at origin: NSPoint? = nil, source: PinSource? = nil) {
        let screen = activeScreen()
        let size = fittedSize(for: image.size, on: screen)
        let frameOrigin = origin ?? centeredOrigin(for: size, on: screen)

        makeWindow(image: image, size: size, origin: frameOrigin, source: source)
    }

    /// Creates a floating editable text pin backed by a regular AppKit text view.
    static func pin(text: String, at origin: NSPoint? = nil, source: PinSource? = nil) {
        TextPinDebugLog.resetForProcessIfNeeded()
        let previewText = TextPinLayout.previewText(text)
        guard !previewText.isEmpty else { return }
        let screen = activeScreen()
        let size = TextPinLayout.size(
            for: previewText,
            maxWidth: TextPinLayout.maxWidth(on: screen)
        )
        let fittedSize = fittedSize(for: size, on: screen)
        let frameOrigin = origin ?? centeredOrigin(for: fittedSize, on: screen)
        var metadata = TextPinDebugLog.textMetadata(previewText)
        metadata["rawTextMetadata"] = TextPinDebugLog.textMetadata(text)
        metadata["screenFrame"] = TextPinDebugLog.rect(screen.frame)
        metadata["screenVisibleFrame"] = TextPinDebugLog.rect(screen.visibleFrame)
        metadata["maxWidth"] = TextPinDebugLog.number(TextPinLayout.maxWidth(on: screen))
        metadata["measuredSize"] = TextPinDebugLog.size(size)
        metadata["fittedSize"] = TextPinDebugLog.size(fittedSize)
        metadata["origin"] = TextPinDebugLog.point(frameOrigin)
        metadata["source"] = debugSourceName(source)
        TextPinDebugLog.log("pin-text-start", metadata: metadata)

        makeTextWindow(text: previewText, size: fittedSize, origin: frameOrigin, source: source)
    }

    /// Pins `images` as floating windows centered on `point` — used when a
    /// Stage Bar drag ends on empty screen space. Multiple images fan out from
    /// the point like the multi-image hotkey path; origins are clamped so a
    /// release near a screen edge stays fully visible.
    static func pin(images: [NSImage], centeredAt point: NSPoint) {
        let screen = activeScreen()
        for (index, image) in images.enumerated() {
            let size = fittedSize(for: image.size, on: screen)
            guard size.width > 0, size.height > 0 else { continue }
            let base = NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
            let origin = stackedOrigin(baseOrigin: base, index: index, size: size, on: screen)
            makeWindow(image: image, size: size, origin: origin, source: nil)
        }
    }

    private static func makeWindow(image: NSImage, size: NSSize, origin: NSPoint, source: PinSource?) {
        let window = PinWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        if Defaults.pinAcrossSpaces {
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = false
        window.acceptsMouseMovedEvents = true
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.pinSource = source

        let contentView = PinContentView(frame: NSRect(origin: .zero, size: size))
        contentView.image = image
        contentView.pinWindow = window
        window.contentView = contentView

        PinWindowManager.shared.add(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(contentView)
    }

    private static func makeTextWindow(
        text: String,
        size: NSSize,
        origin: NSPoint,
        source: PinSource?
    ) {
        let window = PinWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        if Defaults.pinAcrossSpaces {
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = false
        window.acceptsMouseMovedEvents = true
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.pinSource = source
        TextPinDebugLog.log("make-text-window-configured", metadata: [
            "windowFrame": TextPinDebugLog.rect(window.frame),
            "contentSize": TextPinDebugLog.size(size),
            "origin": TextPinDebugLog.point(origin),
            "source": debugSourceName(source),
        ])

        let contentView = TextPinContentView(
            text: text,
            frame: NSRect(origin: .zero, size: size)
        )
        contentView.pinWindow = window
        window.contentView = contentView

        PinWindowManager.shared.add(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(contentView)
        TextPinDebugLog.log("make-text-window-ready", metadata: [
            "windowFrame": TextPinDebugLog.rect(window.frame),
            "contentFrame": TextPinDebugLog.rect(contentView.frame),
            "firstResponder": String(describing: window.firstResponder),
        ])
    }

    // MARK: - Helpers

    private static func activeScreen() -> NSScreen {
        let cursor = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(cursor) })
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    /// Scales `size` down to fit within the active screen (with a margin),
    /// keeping the aspect ratio. Returns it unchanged when it already fits.
    private static func fittedSize(for size: NSSize, on screen: NSScreen) -> NSSize {
        guard size.width > 0, size.height > 0 else { return size }
        let frame = screen.visibleFrame
        let maxWidth = max(200, frame.width - 80)
        let maxHeight = max(200, frame.height - 80)
        let ratio = min(1.0, min(maxWidth / size.width, maxHeight / size.height))
        if ratio >= 1.0 { return size }
        return NSSize(width: floor(size.width * ratio), height: floor(size.height * ratio))
    }

    private static func centeredOrigin(for size: NSSize, on screen: NSScreen) -> NSPoint {
        let frame = screen.visibleFrame
        return NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2
        )
    }

    private static func stackedOrigin(
        baseOrigin: NSPoint,
        index: Int,
        size: NSSize,
        on screen: NSScreen
    ) -> NSPoint {
        let distinctIndex = index % maxDistinctStackOffsets
        let wrapIndex = index / maxDistinctStackOffsets
        let proposed = NSPoint(
            x: baseOrigin.x + CGFloat(distinctIndex) * stackOffset.width + CGFloat(wrapIndex) * 10,
            y: baseOrigin.y + CGFloat(distinctIndex) * stackOffset.height - CGFloat(wrapIndex) * 10
        )
        return clampedOrigin(proposed, size: size, on: screen)
    }

    private static func clampedOrigin(_ origin: NSPoint, size: NSSize, on screen: NSScreen) -> NSPoint {
        let frame = screen.visibleFrame
        let maxX = max(frame.minX, frame.maxX - size.width)
        let maxY = max(frame.minY, frame.maxY - size.height)
        return NSPoint(
            x: min(max(origin.x, frame.minX), maxX),
            y: min(max(origin.y, frame.minY), maxY)
        )
    }

    private static func debugSourceName(_ source: PinSource?) -> String {
        switch source {
        case .finder:
            return "finder"
        case .clipboard:
            return "clipboard"
        case .clipboardText:
            return "clipboardText"
        case nil:
            return "nil"
        }
    }
}

// MARK: - Pin Window Manager (retains all pinned windows)

final class PinWindowManager {
    static let shared = PinWindowManager()
    private var windows: [NSWindow] = []

    func add(_ window: NSWindow) {
        windows.append(window)
    }

    func remove(_ window: NSWindow) {
        windows.removeAll { $0 === window }
    }
}

// MARK: - Text Pin

private enum TextPinDebugLog {
    private static let lock = NSLock()
    private static let directoryName = "capcap"
    private static let fileName = "text-pin-layout.log"
    private static let maxLogBytes = 4_000_000
    private static let trimToBytes = 2_500_000
    private static var didResetForProcess = false

    static var logURL: URL? {
        guard let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            return nil
        }
        return logs
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    static func resetForProcessIfNeeded() {
        lock.lock()
        let shouldReset = !didResetForProcess
        if shouldReset {
            didResetForProcess = true
            if let url = logURL {
                try? FileManager.default.removeItem(at: url)
            }
        }
        lock.unlock()

        if shouldReset {
            log("session-start", metadata: [
                "logPath": logURL?.path ?? "nil",
                "system": DiagnosticLog.systemSnapshot(),
            ])
        }
    }

    static func log(
        _ event: String,
        metadata: [String: Any] = [:],
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        guard let data = makeLine(
            event: event,
            metadata: metadata,
            file: String(describing: file),
            line: line
        ).data(using: .utf8) else {
            return
        }

        lock.lock()
        defer { lock.unlock() }
        append(data)
    }

    static func textMetadata(_ text: String) -> [String: Any] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        let blankLines = lines.filter {
            $0.trimmingCharacters(in: .whitespaces).isEmpty
        }.count
        let lineStats = lines.prefix(20).enumerated().map { index, line in
            let trimmedCount = line.trimmingCharacters(in: .whitespaces).count
            let trailingSpaces = line.reversed().prefix { $0 == " " || $0 == "\t" }.count
            return "\(index):len\(line.count):trim\(trimmedCount):trail\(trailingSpaces)"
        }.joined(separator: ",")
        return [
            "textLength": normalized.count,
            "utf16Length": normalized.utf16.count,
            "lineCount": lines.count,
            "blankLineCount": blankLines,
            "leadingNewlineCount": prefixCount(in: normalized, matching: "\n"),
            "trailingNewlineCount": suffixCount(in: normalized, matching: "\n"),
            "trailingWhitespaceCount": normalized.reversed().prefix { $0.isWhitespace }.count,
            "lineStats": lineStats,
            "preview": preview(normalized),
        ]
    }

    static func rect(_ rect: NSRect) -> String {
        "x=\(number(rect.origin.x)),y=\(number(rect.origin.y)),w=\(number(rect.size.width)),h=\(number(rect.size.height))"
    }

    static func size(_ size: NSSize) -> String {
        "w=\(number(size.width)),h=\(number(size.height))"
    }

    static func point(_ point: NSPoint) -> String {
        "x=\(number(point.x)),y=\(number(point.y))"
    }

    static func insets(_ insets: NSSize) -> String {
        "w=\(number(insets.width)),h=\(number(insets.height))"
    }

    static func number(_ value: CGFloat) -> String {
        String(format: "%.2f", Double(value))
    }

    private static func makeLine(
        event: String,
        metadata: [String: Any],
        file: String,
        line: UInt
    ) -> String {
        let timestamp = ISO8601DateFormatter.textPinDiagnostic.string(from: Date())
        var parts = [
            timestamp,
            "pid=\(ProcessInfo.processInfo.processIdentifier)",
            "thread=\(Thread.isMainThread ? "main" : "background")",
            "event=\(sanitize(event))",
        ]
        if !metadata.isEmpty {
            parts.append(contentsOf: metadata.keys.sorted().map { key in
                "\(sanitize(key))=\(sanitize(String(describing: metadata[key] ?? "")))"
            })
        }
        parts.append("source=\(sanitize(file)):\(line)")
        return parts.joined(separator: " ") + "\n"
    }

    private static func append(_ data: Data) {
        guard let url = logURL else { return }
        let directory = url.deletingLastPathComponent()
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: url.path) {
                _ = fm.createFile(atPath: url.path, contents: nil)
            }
            trimIfNeeded(at: url)
            let handle = try FileHandle(forWritingTo: url)
            handle.seekToEndOfFile()
            handle.write(data)
            handle.synchronizeFile()
            handle.closeFile()
        } catch {
            NSLog("[capcap] TextPinDebugLog append failed: \(error.localizedDescription)")
        }
    }

    private static func trimIfNeeded(at url: URL) {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        guard (values?.fileSize ?? 0) > maxLogBytes,
              let existing = try? Data(contentsOf: url),
              existing.count > trimToBytes else {
            return
        }

        var trimmed = Data()
        if let marker = "\n--- earlier text pin layout log lines truncated ---\n".data(using: .utf8) {
            trimmed.append(marker)
        }
        trimmed.append(existing.suffix(trimToBytes))
        try? trimmed.write(to: url, options: .atomic)
    }

    private static func preview(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
        return String(escaped.prefix(220))
    }

    private static func prefixCount(in text: String, matching character: Character) -> Int {
        text.prefix { $0 == character }.count
    }

    private static func suffixCount(in text: String, matching character: Character) -> Int {
        text.reversed().prefix { $0 == character }.count
    }

    private static func sanitize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}

private extension ISO8601DateFormatter {
    static var textPinDiagnostic: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone.current
        return formatter
    }
}

private enum TextPinLayout {
    static let font = NSFont.systemFont(ofSize: 15, weight: .regular)
    private static let minWidth: CGFloat = 220
    private static let maxPreferredWidth: CGFloat = 560
    private static let minHeight: CGFloat = 72
    private static let contentInset: CGFloat = 17
    private static let padding = NSEdgeInsets(
        top: contentInset,
        left: contentInset,
        bottom: contentInset,
        right: contentInset
    )

    static func maxWidth(on screen: NSScreen) -> CGFloat {
        min(maxPreferredWidth, max(minWidth, screen.visibleFrame.width - 80))
    }

    static func size(for text: String, maxWidth: CGFloat) -> NSSize {
        let attributes = textAttributes()
        let normalized = normalizedText(text)
        let availableWidth = max(120, maxWidth - padding.left - padding.right)
        let measured = (normalized as NSString).boundingRect(
            with: NSSize(width: availableWidth, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        let contentWidth = min(availableWidth, max(1, ceil(measured.width)))
        let width = ceil(min(maxWidth, max(minWidth, contentWidth + padding.left + padding.right)))
        let wrappedWidth = max(120, width - padding.left - padding.right)
        let wrapped = (normalized as NSString).boundingRect(
            with: NSSize(width: wrappedWidth, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        let textSystem = textSystemMeasurement(for: normalized, width: wrappedWidth)
        let textHeight = max(1, ceil(textSystem.usedRect.height))
        let height = ceil(max(minHeight, textHeight + padding.top + padding.bottom))
        let result = NSSize(width: width, height: height)
        var metadata = TextPinDebugLog.textMetadata(normalized)
        metadata["availableWidth"] = TextPinDebugLog.number(availableWidth)
        metadata["contentWidth"] = TextPinDebugLog.number(contentWidth)
        metadata["maxWidth"] = TextPinDebugLog.number(maxWidth)
        metadata["measuredRect"] = TextPinDebugLog.rect(measured)
        metadata["padding"] = "top=\(TextPinDebugLog.number(padding.top)),left=\(TextPinDebugLog.number(padding.left)),bottom=\(TextPinDebugLog.number(padding.bottom)),right=\(TextPinDebugLog.number(padding.right))"
        metadata["resultSize"] = TextPinDebugLog.size(result)
        metadata["textHeight"] = TextPinDebugLog.number(textHeight)
        metadata["textSystemExtraLineFragment"] = TextPinDebugLog.rect(textSystem.extraLineFragmentRect)
        metadata["textSystemGlyphRangeLength"] = textSystem.glyphRangeLength
        metadata["textSystemLineCount"] = textSystem.lineCount
        metadata["textSystemUsedRect"] = TextPinDebugLog.rect(textSystem.usedRect)
        metadata["wrappedRect"] = TextPinDebugLog.rect(wrapped)
        metadata["wrappedWidth"] = TextPinDebugLog.number(wrappedWidth)
        TextPinDebugLog.log("layout-size", metadata: metadata)
        return result
    }

    static func textFrame(in bounds: NSRect) -> NSRect {
        NSRect(
            x: bounds.minX + padding.left,
            y: bounds.minY + padding.bottom,
            width: max(1, bounds.width - padding.left - padding.right),
            height: max(1, bounds.height - padding.top - padding.bottom)
        )
    }

    static func normalizedText(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
    }

    static func previewText(_ text: String) -> String {
        var normalized = normalizedText(text)
        while normalized.last?.isWhitespace == true {
            normalized.removeLast()
        }
        return normalized
    }

    static func textAttributes() -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 3
        return [
            .font: font,
            .foregroundColor: NSColor(calibratedWhite: 0.08, alpha: 1),
            .paragraphStyle: paragraph,
        ]
    }

    static func configure(_ textView: NSTextView, text: String) {
        let attributed = NSAttributedString(
            string: normalizedText(text),
            attributes: textAttributes()
        )
        textView.textStorage?.setAttributedString(attributed)
        textView.font = font
        textView.textColor = NSColor(calibratedWhite: 0.08, alpha: 1)
        textView.typingAttributes = textAttributes()
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: max(1, textView.bounds.width),
            height: CGFloat.greatestFiniteMagnitude
        )
        var metadata = TextPinDebugLog.textMetadata(textView.string)
        metadata["textViewBounds"] = TextPinDebugLog.rect(textView.bounds)
        metadata["textViewFrame"] = TextPinDebugLog.rect(textView.frame)
        metadata["textContainerSize"] = TextPinDebugLog.size(textView.textContainer?.containerSize ?? .zero)
        metadata["textContainerInset"] = TextPinDebugLog.insets(textView.textContainerInset)
        metadata["textContainerLineFragmentPadding"] = TextPinDebugLog.number(textView.textContainer?.lineFragmentPadding ?? -1)
        metadata["textContainerOrigin"] = TextPinDebugLog.point(textView.textContainerOrigin)
        TextPinDebugLog.log("layout-configure-text-view", metadata: metadata)
    }

    static func drawBackground(in bounds: NSRect) {
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: 10,
            yRadius: 10
        )
        NSColor(calibratedWhite: 0.98, alpha: 0.97).setFill()
        path.fill()
        NSColor(calibratedWhite: 0.12, alpha: 0.14).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    static func renderImage(for text: String, size: NSSize) -> NSImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        var metadata = TextPinDebugLog.textMetadata(text)
        metadata["renderSize"] = TextPinDebugLog.size(size)
        metadata["textFrame"] = TextPinDebugLog.rect(textFrame(in: NSRect(origin: .zero, size: size)))
        TextPinDebugLog.log("layout-render-image", metadata: metadata)
        let image = NSImage(size: size)
        image.lockFocus()
        let bounds = NSRect(origin: .zero, size: size)
        drawBackground(in: bounds)
        (normalizedText(text) as NSString).draw(
            with: textFrame(in: bounds),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: textAttributes()
        )
        image.unlockFocus()
        return image
    }

    private struct TextSystemMeasurement {
        let usedRect: NSRect
        let extraLineFragmentRect: NSRect
        let glyphRangeLength: Int
        let lineCount: Int
    }

    private static func textSystemMeasurement(for text: String, width: CGFloat) -> TextSystemMeasurement {
        let storage = NSTextStorage(string: normalizedText(text), attributes: textAttributes())
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(
            width: max(1, width),
            height: CGFloat.greatestFiniteMagnitude
        ))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)

        let glyphRange = layoutManager.glyphRange(for: container)
        var lineCount = 0
        var index = glyphRange.location
        while index < NSMaxRange(glyphRange) {
            var effectiveRange = NSRange(location: 0, length: 0)
            _ = layoutManager.lineFragmentRect(
                forGlyphAt: index,
                effectiveRange: &effectiveRange,
                withoutAdditionalLayout: true
            )
            let next = NSMaxRange(effectiveRange)
            guard next > index else { break }
            lineCount += 1
            index = next
        }

        return TextSystemMeasurement(
            usedRect: layoutManager.usedRect(for: container),
            extraLineFragmentRect: layoutManager.extraLineFragmentRect,
            glyphRangeLength: glyphRange.length,
            lineCount: lineCount
        )
    }
}

private final class TextPinContentView: NSView, NSTextViewDelegate {
    weak var pinWindow: PinWindow?

    private let toolbar = TextPinToolbarView()
    private let displayTextView = TextPinDisplayTextView()
    private let debugID = UUID().uuidString
    private var text: String
    private var trackingArea: NSTrackingArea?
    private var isToolbarVisible = false
    private var isEndingTextEditing = false
    private var committedTextDuringEditing = false

    override var acceptsFirstResponder: Bool { true }

    init(text: String, frame frameRect: NSRect) {
        self.text = text
        super.init(frame: frameRect)
        wantsLayer = true
        setupDisplayTextView()
        setupToolbar()
        logSnapshot("content-init")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        TextPinLayout.drawBackground(in: bounds)
    }

    override func layout() {
        super.layout()
        layoutDisplayTextView()
        layoutToolbar()
        refreshToolbarVisibility()
        logSnapshot("content-layout")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
            self.trackingArea = nil
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        guard !isTextEditing else {
            super.mouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        pinWindow?.performDrag(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        updateToolbarVisibility(for: event)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateToolbarVisibility(for: event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        updateToolbarVisibility(for: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshToolbarVisibility()
    }

    private func setupDisplayTextView() {
        displayTextView.isEditable = false
        displayTextView.isSelectable = false
        displayTextView.isRichText = false
        displayTextView.importsGraphics = false
        displayTextView.drawsBackground = false
        displayTextView.insertionPointColor = NSColor(calibratedWhite: 0.08, alpha: 1)
        displayTextView.textContainer?.widthTracksTextView = true
        displayTextView.textContainer?.containerSize = NSSize(
            width: max(1, bounds.width),
            height: CGFloat.greatestFiniteMagnitude
        )
        displayTextView.onMouseDown = { [weak self] event in
            self?.handleDisplayMouseDown(event)
        }
        displayTextView.onPointerEvent = { [weak self] event in
            self?.updateToolbarVisibility(for: event)
        }
        displayTextView.onCommit = { [weak self] in self?.commitTextEditingIfNeeded() }
        displayTextView.onCancel = { [weak self] in self?.cancelTextEditing() }
        displayTextView.delegate = self
        TextPinLayout.configure(displayTextView, text: text)
        addSubview(displayTextView)
        logSnapshot("setup-display-text-view")
    }

    private func layoutDisplayTextView() {
        displayTextView.frame = TextPinLayout.textFrame(in: bounds)
        displayTextView.textContainer?.containerSize = NSSize(
            width: max(1, displayTextView.bounds.width),
            height: CGFloat.greatestFiniteMagnitude
        )
        logSnapshot("layout-display-text-view")
    }

    private func handleDisplayMouseDown(_ event: NSEvent) {
        if isTextEditing {
            return
        }
        window?.makeFirstResponder(self)
        if event.clickCount >= 2 {
            beginTextEditing()
            displayTextView.forwardEditingMouseDown(with: event)
            return
        }
        pinWindow?.performDrag(with: event)
    }

    private func setupToolbar() {
        toolbar.alphaValue = 0
        toolbar.isHidden = true
        toolbar.onClose = { [weak self] in
            self?.pinWindow?.dismissClearingSource()
        }
        toolbar.onEdit = { [weak self] in
            self?.editTextImage()
        }
        toolbar.onEditText = { [weak self] in
            self?.beginTextEditingFromToolbar()
        }
        toolbar.onPointerEvent = { [weak self] event in
            self?.updateToolbarVisibility(for: event)
        }
        addSubview(toolbar)
    }

    private func layoutToolbar() {
        toolbar.frame = NSRect(
            x: 8,
            y: max(8, bounds.height - TextPinToolbarView.preferredHeight - 8),
            width: TextPinToolbarView.preferredWidth,
            height: TextPinToolbarView.preferredHeight
        )
    }

    private var isTextEditing: Bool {
        displayTextView.isTextEditing
    }

    private func updateToolbarVisibility(for event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        setToolbarVisible(bounds.contains(point))
    }

    private func refreshToolbarVisibility() {
        guard let window else {
            setToolbarVisible(false)
            return
        }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setToolbarVisible(bounds.contains(point))
    }

    private func setToolbarVisible(_ visible: Bool) {
        guard visible != isToolbarVisible else { return }
        isToolbarVisible = visible
        toolbar.isHidden = !visible
        toolbar.alphaValue = visible ? 1 : 0
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 7:
            pinWindow?.dismissClearingSource()
        case 53:
            pinWindow?.dismiss()
        default:
            super.keyDown(with: event)
        }
    }

    func textDidEndEditing(_ notification: Notification) {
        logSnapshot("delegate-text-did-end-editing", extra: [
            "committedTextDuringEditing": committedTextDuringEditing,
            "isEndingTextEditing": isEndingTextEditing,
        ])
        guard isTextEditing, !isEndingTextEditing, !committedTextDuringEditing else { return }
        commitTextEditingIfNeeded()
    }

    func textDidBeginEditing(_ notification: Notification) {
        logSnapshot("delegate-text-did-begin-editing")
    }

    func textDidChange(_ notification: Notification) {
        resizeForLiveTextEditing()
        logSnapshot("delegate-text-did-change")
    }

    private func beginTextEditing() {
        guard !isTextEditing else { return }
        logSnapshot("begin-text-editing-before")
        committedTextDuringEditing = false
        displayTextView.isTextEditing = true
        displayTextView.isEditable = true
        displayTextView.isSelectable = true
        window?.makeFirstResponder(displayTextView)
        logSnapshot("begin-text-editing-after")
    }

    private func beginTextEditingFromToolbar() {
        beginTextEditing()
        displayTextView.setSelectedRange(NSRange(location: displayTextView.string.utf16.count, length: 0))
        logSnapshot("begin-text-editing-from-toolbar")
    }

    @discardableResult
    func commitTextEditingIfNeeded() -> Bool {
        guard isTextEditing else { return true }
        logSnapshot("commit-text-editing-start")
        committedTextDuringEditing = true
        let updatedText = TextPinLayout.previewText(displayTextView.string)
        endTextEditing()

        guard !updatedText.isEmpty else {
            logSnapshot("commit-text-editing-empty-dismiss")
            pinWindow?.dismissClearingSource()
            return false
        }

        text = updatedText
        updateDisplayTextAndResize()
        logSnapshot("commit-text-editing-finish")
        return true
    }

    private func cancelTextEditing() {
        guard isTextEditing else { return }
        logSnapshot("cancel-text-editing-start")
        TextPinLayout.configure(displayTextView, text: text)
        endTextEditing()
        updateDisplayTextAndResize()
        logSnapshot("cancel-text-editing-finish")
    }

    private func endTextEditing() {
        logSnapshot("end-text-editing-before")
        isEndingTextEditing = true
        displayTextView.isTextEditing = false
        displayTextView.isEditable = false
        displayTextView.isSelectable = false
        window?.makeFirstResponder(self)
        isEndingTextEditing = false
        logSnapshot("end-text-editing-after")
    }

    private func updateDisplayTextAndResize() {
        let screen = window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let targetSize = targetTextSize(for: text, on: screen)
        logSnapshot("update-display-text-and-resize-before", extra: [
            "targetSize": TextPinDebugLog.size(targetSize),
            "screenVisibleFrame": TextPinDebugLog.rect(screen.visibleFrame),
        ])
        resizeWindow(to: targetSize, on: screen)
        frame = NSRect(origin: .zero, size: targetSize)
        TextPinLayout.configure(displayTextView, text: text)
        layoutDisplayTextView()
        needsDisplay = true
        logSnapshot("update-display-text-and-resize-after", extra: [
            "targetSize": TextPinDebugLog.size(targetSize),
        ])
    }

    private func resizeForLiveTextEditing() {
        guard isTextEditing else { return }
        let screen = window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let selection = displayTextView.selectedRange()
        let targetSize = targetTextSize(for: displayTextView.string, on: screen)
        let shouldResize = abs(targetSize.width - bounds.width) > 0.5 ||
            abs(targetSize.height - bounds.height) > 0.5

        logSnapshot("live-text-resize-before", extra: [
            "shouldResize": shouldResize,
            "targetSize": TextPinDebugLog.size(targetSize),
            "screenVisibleFrame": TextPinDebugLog.rect(screen.visibleFrame),
        ])
        if shouldResize {
            resizeWindow(to: targetSize, on: screen)
            frame = NSRect(origin: .zero, size: targetSize)
            layoutDisplayTextView()
            needsDisplay = true
        }

        displayTextView.setSelectedRange(selection)
        displayTextView.ensureSelectionVisible()
        logSnapshot("live-text-resize-after", extra: [
            "targetSize": TextPinDebugLog.size(targetSize),
        ])
    }

    private func targetTextSize(for string: String, on screen: NSScreen) -> NSSize {
        fittedSize(
            for: TextPinLayout.size(
                for: string,
                maxWidth: TextPinLayout.maxWidth(on: screen)
            ),
            on: screen
        )
    }

    private func resizeWindow(to targetSize: NSSize, on screen: NSScreen) {
        guard let window else {
            logSnapshot("resize-window-no-window", extra: [
                "targetSize": TextPinDebugLog.size(targetSize),
            ])
            setFrameSize(targetSize)
            return
        }

        let current = window.frame
        var targetFrame = NSRect(
            x: current.minX,
            y: current.maxY - targetSize.height,
            width: targetSize.width,
            height: targetSize.height
        )
        targetFrame = clampedFrame(targetFrame, on: screen)
        TextPinDebugLog.log("resize-window", metadata: [
            "pinID": debugID,
            "currentFrame": TextPinDebugLog.rect(current),
            "targetFrame": TextPinDebugLog.rect(targetFrame),
            "targetSize": TextPinDebugLog.size(targetSize),
            "screenVisibleFrame": TextPinDebugLog.rect(screen.visibleFrame),
        ])
        window.setFrame(targetFrame, display: true, animate: false)
    }

    private func fittedSize(for size: NSSize, on screen: NSScreen) -> NSSize {
        guard size.width > 0, size.height > 0 else { return size }
        let frame = screen.visibleFrame
        let maxWidth = max(200, frame.width - 80)
        let maxHeight = max(200, frame.height - 80)
        let ratio = min(1.0, min(maxWidth / size.width, maxHeight / size.height))
        if ratio >= 1.0 { return size }
        return NSSize(width: floor(size.width * ratio), height: floor(size.height * ratio))
    }

    private func clampedFrame(_ frame: NSRect, on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        var result = frame
        result.origin.x = min(max(result.minX, visible.minX), max(visible.minX, visible.maxX - result.width))
        result.origin.y = min(max(result.minY, visible.minY), max(visible.minY, visible.maxY - result.height))
        return result
    }

    private func editTextImage() {
        guard commitTextEditingIfNeeded() else { return }
        guard let pinWindow,
              let appDelegate = NSApp.delegate as? AppDelegate,
              let image = TextPinLayout.renderImage(for: text, size: bounds.size)
        else { return }
        logSnapshot("edit-text-image")

        appDelegate.handlePinnedImageEditRequest(image) {
            pinWindow.dismiss()
        }
    }

    private func logSnapshot(_ event: String, extra: [String: Any] = [:]) {
        var metadata = TextPinDebugLog.textMetadata(displayTextView.string)
        metadata["pinID"] = debugID
        metadata["contentBounds"] = TextPinDebugLog.rect(bounds)
        metadata["contentFrame"] = TextPinDebugLog.rect(frame)
        metadata["displayBounds"] = TextPinDebugLog.rect(displayTextView.bounds)
        metadata["displayFrame"] = TextPinDebugLog.rect(displayTextView.frame)
        metadata["displayVisibleRect"] = TextPinDebugLog.rect(displayTextView.visibleRect)
        metadata["expectedTextFrame"] = TextPinDebugLog.rect(TextPinLayout.textFrame(in: bounds))
        metadata["firstResponder"] = String(describing: window?.firstResponder)
        metadata["isEditable"] = displayTextView.isEditable
        metadata["isSelectable"] = displayTextView.isSelectable
        metadata["isTextEditing"] = isTextEditing
        metadata["textContainerInset"] = TextPinDebugLog.insets(displayTextView.textContainerInset)
        metadata["textContainerLineFragmentPadding"] = TextPinDebugLog.number(displayTextView.textContainer?.lineFragmentPadding ?? -1)
        metadata["textContainerOrigin"] = TextPinDebugLog.point(displayTextView.textContainerOrigin)
        metadata["textContainerSize"] = TextPinDebugLog.size(displayTextView.textContainer?.containerSize ?? .zero)
        metadata["windowFrame"] = TextPinDebugLog.rect(window?.frame ?? .zero)
        if let layoutManager = displayTextView.layoutManager,
           let textContainer = displayTextView.textContainer {
            metadata["layoutManagerExtraLineFragment"] = TextPinDebugLog.rect(layoutManager.extraLineFragmentRect)
            metadata["layoutManagerGlyphRange"] = String(describing: layoutManager.glyphRange(for: textContainer))
            metadata["layoutManagerUsedRect"] = TextPinDebugLog.rect(layoutManager.usedRect(for: textContainer))
        }
        for (key, value) in extra {
            metadata[key] = value
        }
        TextPinDebugLog.log(event, metadata: metadata)
    }
}

private final class TextPinDisplayTextView: NSTextView {
    var onMouseDown: ((NSEvent) -> Void)?
    var onPointerEvent: ((NSEvent) -> Void)?
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    var isTextEditing = false
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { isTextEditing }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
            self.trackingArea = nil
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onPointerEvent?(event)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onPointerEvent?(event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onPointerEvent?(event)
    }

    override func mouseDown(with event: NSEvent) {
        onPointerEvent?(event)
        guard !isTextEditing else {
            super.mouseDown(with: event)
            return
        }
        onMouseDown?(event)
    }

    override func keyDown(with event: NSEvent) {
        guard isTextEditing else {
            super.keyDown(with: event)
            return
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53, modifiers.isEmpty {
            onCancel?()
            return
        }
        if (event.keyCode == 36 || event.keyCode == 76), modifiers == .command {
            onCommit?()
            return
        }
        super.keyDown(with: event)
    }

    func forwardEditingMouseDown(with event: NSEvent) {
        guard isTextEditing else { return }
        super.mouseDown(with: event)
    }

    func ensureSelectionVisible() {
        guard isTextEditing else { return }
        if let layoutManager, let textContainer {
            layoutManager.ensureLayout(for: textContainer)
        }
        scrollRangeToVisible(selectedRange())
    }
}

// MARK: - Pin Content View (zoomable image with floating controls)

private enum PinZoom {
    static let minScale: CGFloat = 0.25
    static let maxScale: CGFloat = 5.0
    static let buttonStep: CGFloat = 0.1
    static let wheelSensitivity: CGFloat = 0.002
    static let toolbarInset: CGFloat = 8
    static let navigatorScaleThreshold: CGFloat = 1.2
    static let navigatorGap: CGFloat = 8
    static let navigatorIdleHideDelay: TimeInterval = 0.8
    static let navigatorActivationDelay: TimeInterval = 0.4
    static let navigatorEntryTimeout: TimeInterval = 3.0
    static let toolbarAnimationDuration: TimeInterval = 0.16
}

final class PinContentView: NSView {
    var image: NSImage? {
        didSet {
            navigator.image = image
            zoomScale = 1.0
            panOffset = .zero
            resetOCRSelection()
            needsDisplay = true
            needsLayout = true
            updateImageInteractionGeometry()
        }
    }
    weak var pinWindow: PinWindow?

    private let baseImageSize: NSSize
    private let toolbar = PinToolbarView()
    private let navigator = PinNavigatorView()
    private let ocrOverlay: OCRLineSelectionOverlayView
    private var zoomScale: CGFloat = 1.0 {
        didSet {
            toolbar.zoomScale = zoomScale
            updateNavigatorViewport()
            if !canShowNavigator {
                hideNavigator(animated: true)
            }
            needsDisplay = true
        }
    }
    private var panOffset: NSPoint = .zero {
        didSet {
            updateNavigatorViewport()
            needsDisplay = true
        }
    }
    private var panStartPoint: NSPoint?
    private var panStartOffset: NSPoint = .zero
    private var imageTrackingArea: NSTrackingArea?
    private var isToolbarVisible = false
    private var isNavigatorVisible = false
    private var isNavigatorFrameValid = false
    private var isNavigatorSuppressedUntilMouseExit = false
    private var wasMouseInNavigatorActivationRegion = false
    private var isMouseInNavigatorRegion = false
    private var lastNavigatorPointerPoint: NSPoint?
    private var navigatorNavigationBlockedUntil: Date?
    private var navigatorIdleTimer: Timer?
    private var navigatorEntryTimer: Timer?
    private var isOCRSelectionEnabled = false {
        didSet {
            toolbar.isOCRActive = isOCRSelectionEnabled
            refreshOCROverlayVisibility()
        }
    }
    private var hasOCRResult = false
    private var ocrRunID = UUID()
    private var ocrRecognitionTask: Task<Void, Never>?

    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        baseImageSize = frame.size
        ocrOverlay = OCRLineSelectionOverlayView(imageSize: frame.size)
        super.init(frame: frame)
        setupOCROverlay()
        setupToolbar()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        navigatorIdleTimer?.invalidate()
        navigatorEntryTimer?.invalidate()
        ocrRecognitionTask?.cancel()
    }

    private func setupOCROverlay() {
        ocrOverlay.isHidden = true
        ocrOverlay.showsLineBoxes = false
        ocrOverlay.onSelectText = { text, lineIndices, isFinal in
            guard isFinal else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(trimmed, forType: .string)
            ToastWindow.show(
                message: lineIndices.count == 1 ? L10n.ocrLineCopied : L10n.ocrCopied,
                duration: 0.9
            )
        }
        addSubview(ocrOverlay)
    }

    private func setupToolbar() {
        toolbar.alphaValue = 0
        toolbar.isHidden = true
        navigator.alphaValue = 0
        navigator.isHidden = true

        toolbar.onEdit = { [weak self] in
            self?.editPinnedImage()
        }
        toolbar.onOCR = { [weak self] in
            self?.toggleOCRSelection()
        }
        toolbar.onStage = { [weak self] in
            self?.stagePinnedImage()
        }
        toolbar.onMoveMouseDown = { [weak self] event in
            self?.pinWindow?.performDrag(with: event)
        }
        toolbar.onZoomOut = { [weak self] in
            self?.adjustZoom(by: -PinZoom.buttonStep)
        }
        toolbar.onZoomIn = { [weak self] in
            self?.adjustZoom(by: PinZoom.buttonStep)
        }
        toolbar.onClose = { [weak self] in
            self?.pinWindow?.dismiss()
        }
        navigator.onFocusChanged = { [weak self] unitPoint in
            self?.focusImage(at: unitPoint)
        }
        navigator.onPointerActivity = { [weak self] point in
            self?.registerNavigatorPointerActivity(at: point) == true
        }
        navigator.onPointerExited = { [weak self] in
            self?.handleNavigatorPointerExit()
        }
        addSubview(navigator)
        addSubview(toolbar)
    }

    /// Sweeps this pinned image back into the Stage Bar: the window flies
    /// into the bar's collapsed strip and the item becomes a staged tile.
    private func stagePinnedImage() {
        guard let image, let pinWindow else { return }
        let imageToStage = image.copy() as? NSImage ?? image
        let sourceRect = pinWindow.frame
        pinWindow.dismiss()
        StageLauncher.stage(image: imageToStage, from: sourceRect)
    }

    private func editPinnedImage() {
        guard let image,
              let pinWindow,
              let appDelegate = NSApp.delegate as? AppDelegate
        else {
            return
        }

        let imageForEditing = image.copy() as? NSImage ?? image
        appDelegate.handlePinnedImageEditRequest(imageForEditing) {
            pinWindow.dismiss()
        }
    }

    override func layout() {
        super.layout()
        updateToolbarFrame()
        updateOCROverlayFrame()
        updateNavigatorFrame()
        updateNavigatorViewport()
        updateImageTrackingArea()
        refreshToolbarVisibility(animated: false)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateImageTrackingArea()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshToolbarVisibility(animated: false)
    }

    private func updateToolbarFrame() {
        let toolbarWidth = min(PinToolbarView.preferredWidth, max(PinToolbarView.minimumWidth, bounds.width - 12))
        let toolbarHeight = PinToolbarView.preferredHeight
        let imageFrame = imageRect()
        let margin: CGFloat = 6
        let proposedX = imageFrame.minX + PinZoom.toolbarInset
        let proposedY = imageFrame.maxY - toolbarHeight - PinZoom.toolbarInset
        let maxX = max(margin, bounds.width - toolbarWidth - margin)
        let maxY = max(margin, bounds.height - toolbarHeight - margin)

        toolbar.frame = NSRect(
            x: min(max(proposedX, margin), maxX),
            y: min(max(proposedY, margin), maxY),
            width: toolbarWidth,
            height: toolbarHeight
        )
    }

    private func updateOCROverlayFrame() {
        ocrOverlay.frame = imageRect()
        ocrOverlay.needsDisplay = true
    }

    private func updateNavigatorFrame() {
        let size = navigatorSize()
        guard size.width > 0, size.height > 0 else {
            isNavigatorFrameValid = false
            hideNavigator(animated: true)
            return
        }

        isNavigatorFrameValid = true
        let margin: CGFloat = 6
        let proposedX = PinZoom.toolbarInset
        let proposedY = bounds.height - PinToolbarView.preferredHeight -
            PinZoom.toolbarInset - PinZoom.navigatorGap - size.height
        let maxX = max(margin, bounds.width - size.width - margin)
        let maxY = max(margin, bounds.height - size.height - margin)

        navigator.frame = NSRect(
            x: min(max(proposedX, margin), maxX),
            y: min(max(proposedY, margin), maxY),
            width: size.width,
            height: size.height
        )
    }

    private func navigatorSize() -> NSSize {
        guard baseImageSize.width > 0, baseImageSize.height > 0 else { return .zero }

        let margin: CGFloat = 6
        let aspect = baseImageSize.width / baseImageSize.height
        let widthLimit = max(48, min(PinNavigatorView.maxWidth, bounds.width - margin * 2))
        let availableHeightBelowToolbar = toolbar.frame.minY - PinZoom.navigatorGap - margin
        let heightLimit = max(36, min(PinNavigatorView.maxHeight, availableHeightBelowToolbar))

        var width = min(widthLimit, max(PinNavigatorView.minWidth, bounds.width * 0.18))
        var height = width / aspect
        if height > heightLimit {
            height = heightLimit
            width = height * aspect
        }
        if width > widthLimit {
            width = widthLimit
            height = width / aspect
        }

        guard width >= 48, height >= 36 else { return .zero }
        return NSSize(width: floor(width), height: floor(height))
    }

    override func keyDown(with event: NSEvent) {
        if handleOCRKeyEquivalent(event) {
            return
        }
        switch event.keyCode {
        case 7: // X — close and clear the originating source.
            pinWindow?.dismissClearingSource()
        case 53: // Esc — close only.
            pinWindow?.dismiss()
        default:
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleOCRKeyEquivalent(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard !toolbarInteractiveRect().contains(point) else { return }
        guard !navigatorInteractiveRect().contains(point) else { return }
        guard imageHoverRect().contains(point) else { return }

        if event.clickCount >= 2 {
            pinWindow?.dismiss()
            return
        }

        if zoomScale > 1 {
            panStartPoint = point
            panStartOffset = panOffset
            return
        }

        pinWindow?.performDrag(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard zoomScale > 1, let start = panStartPoint else { return }

        let point = convert(event.locationInWindow, from: nil)
        let proposed = NSPoint(
            x: panStartOffset.x + point.x - start.x,
            y: panStartOffset.y + point.y - start.y
        )
        panOffset = clampedPanOffset(proposed, scale: zoomScale)
        updateImageInteractionGeometry()
    }

    override func mouseUp(with event: NSEvent) {
        panStartPoint = nil
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        guard delta != 0 else {
            super.scrollWheel(with: event)
            return
        }

        let normalizedDelta = event.hasPreciseScrollingDeltas ? delta : delta * 10
        let factor = pow(1 + PinZoom.wheelSensitivity, normalizedDelta)
        zoomAtEventLocation(zoomScale * factor, event: event)
    }

    override func magnify(with event: NSEvent) {
        let factor = max(0.1, 1 + event.magnification)
        zoomAtEventLocation(zoomScale * factor, event: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        let context = NSGraphicsContext.current
        let oldInterpolation = context?.imageInterpolation
        context?.imageInterpolation = .high
        image.draw(in: imageRect())
        if let oldInterpolation {
            context?.imageInterpolation = oldInterpolation
        }
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        updateToolbarVisibility(for: event, animated: true)
        updateNavigatorActivation(for: event, animated: true)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateToolbarVisibility(for: event, animated: true)
        updateNavigatorActivation(for: event, animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        updateToolbarVisibility(for: event, animated: true)
        updateNavigatorActivation(for: event, animated: true)
    }

    private func adjustZoom(by delta: CGFloat) {
        setZoom(zoomScale + delta)
    }

    private func toggleOCRSelection() {
        guard image != nil else { return }
        if isOCRSelectionEnabled {
            isOCRSelectionEnabled = false
            return
        }

        if hasOCRResult, ocrOverlay.lines.isEmpty {
            ToastWindow.show(message: L10n.ocrNoText, duration: 0.9)
            return
        }

        window?.makeFirstResponder(self)
        isOCRSelectionEnabled = true
        startOCRRecognitionIfNeeded()
    }

    private func startOCRRecognitionIfNeeded() {
        guard !hasOCRResult, ocrRecognitionTask == nil, let image else { return }

        ToastWindow.show(message: L10n.ocrRecognizing, duration: 0.8)
        let runID = UUID()
        ocrRunID = runID
        let imageForOCR = image.copy() as? NSImage ?? image

        ocrRecognitionTask = Task { @MainActor [weak self] in
            let lines = await OCRService.recognizeLines(
                image: imageForOCR,
                diagnosticID: String(runID.uuidString.prefix(8)),
                source: "pin.ocr-selection"
            )
            guard let self, self.ocrRunID == runID else { return }
            self.ocrRecognitionTask = nil
            self.hasOCRResult = true
            self.ocrOverlay.lines = lines
            if lines.isEmpty {
                if self.isOCRSelectionEnabled {
                    self.isOCRSelectionEnabled = false
                    ToastWindow.show(message: L10n.ocrNoText, duration: 0.9)
                }
            } else {
                self.refreshOCROverlayVisibility()
            }
        }
    }

    private func resetOCRSelection() {
        ocrRunID = UUID()
        ocrRecognitionTask?.cancel()
        ocrRecognitionTask = nil
        hasOCRResult = false
        isOCRSelectionEnabled = false
        ocrOverlay.lines = []
        refreshOCROverlayVisibility()
    }

    private func refreshOCROverlayVisibility() {
        updateOCROverlayFrame()
        let showOverlay = isOCRSelectionEnabled && !ocrOverlay.lines.isEmpty
        ocrOverlay.showsLineBoxes = showOverlay
        ocrOverlay.isHidden = !showOverlay
    }

    private func handleOCRKeyEquivalent(_ event: NSEvent) -> Bool {
        guard isOCRSelectionEnabled,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return false
        }

        switch event.charactersIgnoringModifiers {
        case "a":
            return ocrOverlay.selectAllText()
        case "c":
            guard ocrOverlay.copySelectedTextToClipboard() else { return false }
            ToastWindow.show(message: L10n.ocrCopied, duration: 0.9)
            return true
        default:
            return false
        }
    }

    private func zoomAtEventLocation(_ proposedScale: CGFloat, event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let unitPoint = imageUnitPoint(for: point) else {
            setZoom(proposedScale)
            return
        }

        setZoom(proposedScale, focusing: unitPoint, at: point)
    }

    private func setZoom(
        _ proposedScale: CGFloat,
        focusing unitPoint: NSPoint? = nil,
        at focusPoint: NSPoint? = nil
    ) {
        let newScale = min(max(proposedScale, PinZoom.minScale), PinZoom.maxScale)
        let didChangeScale = abs(newScale - zoomScale) > 0.001
        guard didChangeScale || unitPoint != nil else { return }

        let currentSize = bounds.size
        let targetSize = windowSize(for: newScale)
        let shouldRevealNavigator = didChangeScale &&
            zoomScale < PinZoom.navigatorScaleThreshold &&
            newScale >= PinZoom.navigatorScaleThreshold
        if didChangeScale {
            zoomScale = newScale
        }
        if let unitPoint, newScale > 1 {
            resizeWindowKeepingTopLeft(for: newScale)
            panOffset = focusedPanOffset(
                on: unitPoint,
                scale: newScale,
                at: adjustedFocusPoint(
                    focusPoint,
                    from: currentSize,
                    to: targetSize
                )
            )
        } else {
            panOffset = newScale > 1 ? clampedPanOffset(panOffset, scale: newScale) : .zero
            if didChangeScale {
                resizeWindowKeepingTopLeft(for: newScale)
            }
        }
        updateImageInteractionGeometry()
        if shouldRevealNavigator {
            isNavigatorSuppressedUntilMouseExit = false
            showNavigator(animated: true)
            updateNavigatorActivationAtCurrentMouse(animated: true)
        }
    }

    private func focusImage(at unitPoint: NSPoint) {
        guard isNavigatorVisible,
              !isNavigatorSuppressedUntilMouseExit,
              !isNavigatorNavigationBlocked,
              zoomScale >= PinZoom.navigatorScaleThreshold
        else { return }

        let imageSize = scaledImageSize(for: zoomScale)
        panOffset = focusedPanOffset(on: unitPoint, scale: zoomScale, imageSize: imageSize)
        updateImageInteractionGeometry()
    }

    private func imageUnitPoint(for point: NSPoint) -> NSPoint? {
        let frame = imageRect()
        guard frame.width > 0,
              frame.height > 0,
              frame.contains(point)
        else { return nil }

        return NSPoint(
            x: min(max((point.x - frame.minX) / frame.width, 0), 1),
            y: min(max((point.y - frame.minY) / frame.height, 0), 1)
        )
    }

    private func focusedPanOffset(
        on unitPoint: NSPoint,
        scale: CGFloat,
        imageSize: NSSize? = nil,
        at focusPoint: NSPoint? = nil
    ) -> NSPoint {
        let size = imageSize ?? scaledImageSize(for: scale)
        let targetPoint = focusPoint ?? NSPoint(x: bounds.midX, y: bounds.midY)
        let imagePoint = NSPoint(
            x: min(max(unitPoint.x, 0), 1) * size.width,
            y: min(max(unitPoint.y, 0), 1) * size.height
        )
        let proposed = NSPoint(
            x: targetPoint.x - imagePoint.x,
            y: targetPoint.y - imagePoint.y - bounds.height + size.height
        )
        return clampedPanOffset(proposed, scale: scale)
    }

    private func adjustedFocusPoint(
        _ point: NSPoint?,
        from currentSize: NSSize,
        to targetSize: NSSize
    ) -> NSPoint? {
        guard let point else { return nil }
        return NSPoint(
            x: point.x,
            y: point.y + targetSize.height - currentSize.height
        )
    }

    private func imageRect() -> NSRect {
        let size = scaledImageSize(for: zoomScale)
        return NSRect(
            x: panOffset.x,
            y: bounds.height - size.height + panOffset.y,
            width: size.width,
            height: size.height
        )
    }

    private func scaledImageSize(for scale: CGFloat) -> NSSize {
        NSSize(
            width: max(1, floor(baseImageSize.width * scale)),
            height: max(1, floor(baseImageSize.height * scale))
        )
    }

    private func windowSize(for scale: CGFloat) -> NSSize {
        let imageSize = scaledImageSize(for: scale)
        let naturalSize = scale > 1 ? baseImageSize : imageSize
        return NSSize(
            width: max(naturalSize.width, PinToolbarView.minimumWidth + 12),
            height: max(naturalSize.height, PinToolbarView.preferredHeight + PinZoom.toolbarInset * 2)
        )
    }

    private func clampedPanOffset(_ offset: NSPoint, scale: CGFloat) -> NSPoint {
        guard scale > 1 else { return .zero }

        let imageSize = scaledImageSize(for: scale)
        let minX = min(0, bounds.width - imageSize.width)
        let maxY = max(0, imageSize.height - bounds.height)
        return NSPoint(
            x: min(max(offset.x, minX), 0),
            y: min(max(offset.y, 0), maxY)
        )
    }

    private func resizeWindowKeepingTopLeft(for scale: CGFloat) {
        let targetSize = windowSize(for: scale)
        guard let window else {
            setFrameSize(targetSize)
            return
        }

        let currentFrame = window.frame
        let targetFrame = NSRect(
            x: currentFrame.minX,
            y: currentFrame.maxY - targetSize.height,
            width: targetSize.width,
            height: targetSize.height
        )
        guard abs(targetFrame.width - currentFrame.width) > 0.5 ||
              abs(targetFrame.height - currentFrame.height) > 0.5
        else { return }

        window.setFrame(targetFrame, display: true, animate: false)
    }

    private func imageHoverRect() -> NSRect {
        guard image != nil else { return .zero }
        let rect = imageRect().intersection(bounds)
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { return .zero }
        return rect
    }

    private func updateImageInteractionGeometry() {
        updateToolbarFrame()
        updateOCROverlayFrame()
        updateNavigatorFrame()
        updateNavigatorViewport()
        updateImageTrackingArea()
        refreshToolbarVisibility(animated: true)
    }

    private func updateNavigatorViewport() {
        navigator.viewportRect = normalizedVisibleImageRect()
    }

    private var canShowNavigator: Bool {
        zoomScale >= PinZoom.navigatorScaleThreshold &&
            image != nil &&
            isNavigatorFrameValid &&
            navigator.frame.width > 0 &&
            navigator.frame.height > 0
    }

    private func normalizedVisibleImageRect() -> NSRect {
        let imageFrame = imageRect()
        let visible = imageFrame.intersection(bounds)
        guard !visible.isNull,
              imageFrame.width > 0,
              imageFrame.height > 0
        else { return .zero }

        return NSRect(
            x: min(max((visible.minX - imageFrame.minX) / imageFrame.width, 0), 1),
            y: min(max((visible.minY - imageFrame.minY) / imageFrame.height, 0), 1),
            width: min(max(visible.width / imageFrame.width, 0), 1),
            height: min(max(visible.height / imageFrame.height, 0), 1)
        )
    }

    private func navigatorInteractiveRect() -> NSRect {
        guard isNavigatorVisible,
              zoomScale >= PinZoom.navigatorScaleThreshold,
              navigator.frame.width > 0,
              navigator.frame.height > 0
        else { return .zero }
        return navigator.frame
    }

    private func toolbarInteractiveRect() -> NSRect {
        guard !toolbar.isHidden,
              toolbar.frame.width > 0,
              toolbar.frame.height > 0
        else { return .zero }
        return toolbar.frame
    }

    private func navigatorActivationRect() -> NSRect {
        guard canShowNavigator else { return .zero }
        return navigator.frame
    }

    private func updateImageTrackingArea() {
        if let imageTrackingArea {
            removeTrackingArea(imageTrackingArea)
            self.imageTrackingArea = nil
        }

        let rect = imageHoverRect()
        guard rect.width > 0, rect.height > 0 else {
            setToolbarVisible(false, animated: false)
            return
        }

        let area = NSTrackingArea(
            rect: rect,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        imageTrackingArea = area
    }

    private func updateToolbarVisibility(for event: NSEvent, animated: Bool) {
        let point = convert(event.locationInWindow, from: nil)
        setToolbarVisible(imageHoverRect().contains(point), animated: animated)
    }

    private func updateNavigatorActivation(for event: NSEvent, animated: Bool) {
        updateNavigatorActivation(at: convert(event.locationInWindow, from: nil), animated: animated)
    }

    private func updateNavigatorActivationAtCurrentMouse(animated: Bool) {
        guard let window else { return }
        updateNavigatorActivation(at: convert(window.mouseLocationOutsideOfEventStream, from: nil), animated: animated)
    }

    private func currentMousePointInView() -> NSPoint? {
        guard let window else { return nil }
        return convert(window.mouseLocationOutsideOfEventStream, from: nil)
    }

    private var isCurrentMouseInsideNavigatorActivationRegion: Bool {
        guard canShowNavigator, let point = currentMousePointInView() else { return false }
        return navigatorActivationRect().contains(point)
    }

    private func updateNavigatorActivation(at point: NSPoint, animated: Bool) {
        guard canShowNavigator else {
            isNavigatorSuppressedUntilMouseExit = false
            lastNavigatorPointerPoint = nil
            wasMouseInNavigatorActivationRegion = false
            hideNavigator(animated: animated)
            return
        }

        let inside = navigatorActivationRect().contains(point)
        if !inside {
            isNavigatorSuppressedUntilMouseExit = false
            navigatorNavigationBlockedUntil = nil
            lastNavigatorPointerPoint = nil
        }
        defer { wasMouseInNavigatorActivationRegion = inside }

        if isNavigatorSuppressedUntilMouseExit {
            if !inside, wasMouseInNavigatorActivationRegion {
                handleNavigatorPointerExit()
            }
            return
        }

        if inside {
            if !wasMouseInNavigatorActivationRegion {
                showNavigator(animated: animated)
                beginNavigatorHover(at: point)
                return
            }
            guard isNavigatorVisible else { return }

            guard registerNavigatorPointerActivity(at: point) else { return }
            if let unitPoint = navigator.unitPoint(forPointInSuperview: point) {
                focusImage(at: unitPoint)
            }
        } else if wasMouseInNavigatorActivationRegion {
            handleNavigatorPointerExit()
        }
    }

    private func refreshToolbarVisibility(animated: Bool) {
        guard let window else {
            setToolbarVisible(false, animated: false)
            return
        }

        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setToolbarVisible(imageHoverRect().contains(point), animated: animated)
    }

    private func setToolbarVisible(_ visible: Bool, animated: Bool) {
        guard visible != isToolbarVisible else { return }
        isToolbarVisible = visible
        setFloatingControl(
            toolbar,
            visible: visible,
            animated: animated,
            shouldRemainVisible: { [weak self] in self?.isToolbarVisible == true }
        )
    }

    private func showNavigator(animated _: Bool) {
        guard canShowNavigator else { return }
        navigatorEntryTimer?.invalidate()
        scheduleNavigatorEntryTimeout()
        guard !isNavigatorVisible else { return }

        isNavigatorVisible = true
        setFloatingControl(
            navigator,
            visible: true,
            animated: true,
            shouldRemainVisible: { [weak self] in self?.isNavigatorVisible == true }
        )
    }

    private func hideNavigator(animated _: Bool) {
        hideNavigator(animated: true, suppressUntilMouseExit: false)
    }

    private func hideNavigator(animated _: Bool, suppressUntilMouseExit: Bool) {
        navigatorIdleTimer?.invalidate()
        navigatorEntryTimer?.invalidate()
        isMouseInNavigatorRegion = false
        isNavigatorSuppressedUntilMouseExit = suppressUntilMouseExit
        navigatorNavigationBlockedUntil = nil
        lastNavigatorPointerPoint = nil
        wasMouseInNavigatorActivationRegion = suppressUntilMouseExit
        guard isNavigatorVisible || !navigator.isHidden else { return }

        isNavigatorVisible = false
        setFloatingControl(
            navigator,
            visible: false,
            animated: true,
            shouldRemainVisible: { [weak self] in self?.isNavigatorVisible == true }
        )
    }

    private func beginNavigatorHover(at point: NSPoint) {
        guard isNavigatorVisible else { return }
        isMouseInNavigatorRegion = true
        wasMouseInNavigatorActivationRegion = true
        navigatorNavigationBlockedUntil = Date().addingTimeInterval(PinZoom.navigatorActivationDelay)
        lastNavigatorPointerPoint = point
        navigatorEntryTimer?.invalidate()
        scheduleNavigatorIdleHide()
    }

    @discardableResult
    private func registerNavigatorPointerActivity(at point: NSPoint? = nil) -> Bool {
        guard isNavigatorVisible else { return false }
        isMouseInNavigatorRegion = true
        wasMouseInNavigatorActivationRegion = true
        navigatorEntryTimer?.invalidate()

        if let point {
            let didMove = navigatorPointerDidMove(to: point)
            guard didMove || navigatorIdleTimer == nil else { return false }
        }
        scheduleNavigatorIdleHide()
        return !isNavigatorNavigationBlocked
    }

    private func handleNavigatorPointerExit() {
        if isNavigatorSuppressedUntilMouseExit,
           isCurrentMouseInsideNavigatorActivationRegion {
            isMouseInNavigatorRegion = false
            navigatorIdleTimer?.invalidate()
            return
        }

        isMouseInNavigatorRegion = false
        isNavigatorSuppressedUntilMouseExit = false
        navigatorNavigationBlockedUntil = nil
        wasMouseInNavigatorActivationRegion = false
        lastNavigatorPointerPoint = nil
        navigatorIdleTimer?.invalidate()
        guard isNavigatorVisible else { return }
        scheduleNavigatorEntryTimeout()
    }

    private func navigatorPointerDidMove(to point: NSPoint) -> Bool {
        defer { lastNavigatorPointerPoint = point }
        guard let previous = lastNavigatorPointerPoint else { return true }

        return abs(previous.x - point.x) > 0.5 || abs(previous.y - point.y) > 0.5
    }

    private var isNavigatorNavigationBlocked: Bool {
        guard let blockedUntil = navigatorNavigationBlockedUntil else { return false }
        guard Date() < blockedUntil else {
            navigatorNavigationBlockedUntil = nil
            return false
        }
        return true
    }

    private func scheduleNavigatorIdleHide() {
        navigatorIdleTimer?.invalidate()
        let timer = Timer(timeInterval: PinZoom.navigatorIdleHideDelay, repeats: false) { [weak self] _ in
            guard let self, self.isMouseInNavigatorRegion else { return }
            self.hideNavigator(animated: true, suppressUntilMouseExit: true)
        }
        RunLoop.main.add(timer, forMode: .common)
        navigatorIdleTimer = timer
    }

    private func scheduleNavigatorEntryTimeout() {
        navigatorEntryTimer?.invalidate()
        let timer = Timer(timeInterval: PinZoom.navigatorEntryTimeout, repeats: false) { [weak self] _ in
            guard let self, self.isNavigatorVisible, !self.isMouseInNavigatorRegion else { return }
            self.hideNavigator(animated: true)
        }
        RunLoop.main.add(timer, forMode: .common)
        navigatorEntryTimer = timer
    }

    private func setFloatingControl(
        _ view: NSView,
        visible: Bool,
        animated: Bool,
        shouldRemainVisible: @escaping () -> Bool
    ) {
        if visible {
            view.isHidden = false
        }

        let finish = { [weak view] in
            guard let view else { return }
            if !shouldRemainVisible() {
                view.isHidden = true
            }
        }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = PinZoom.toolbarAnimationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                view.animator().alphaValue = visible ? 1 : 0
            } completionHandler: {
                finish()
            }
        } else {
            view.alphaValue = visible ? 1 : 0
            finish()
        }
    }
}

// MARK: - Pin Navigator

private final class PinNavigatorView: NSView {
    static let maxWidth: CGFloat = 240
    static let maxHeight: CGFloat = 160
    static let minWidth: CGFloat = 96

    var image: NSImage? {
        didSet { needsDisplay = true }
    }
    var viewportRect: NSRect = .zero {
        didSet { needsDisplay = true }
    }
    var onFocusChanged: ((NSPoint) -> Void)?
    var onPointerActivity: ((NSPoint) -> Bool)?
    var onPointerExited: (() -> Void)?

    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        setAccessibilityLabel("Pinned image navigator")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        guard bounds.width > 0, bounds.height > 0 else { return }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseEntered(with event: NSEvent) {
        updateFocus(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateFocus(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        updateFocus(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        updateFocus(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        onPointerExited?()
    }

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        nextResponder?.magnify(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        let outerRect = bounds.insetBy(dx: 1.5, dy: 1.5)
        let outerPath = NSBezierPath(roundedRect: outerRect, xRadius: 5, yRadius: 5)

        NSColor(white: 0.02, alpha: 0.42).setFill()
        outerPath.fill()

        if let image {
            let imageRect = thumbnailImageRect()
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: imageRect, xRadius: 3, yRadius: 3).addClip()

            let context = NSGraphicsContext.current
            let oldInterpolation = context?.imageInterpolation
            context?.imageInterpolation = .high
            image.draw(in: imageRect)
            if let oldInterpolation {
                context?.imageInterpolation = oldInterpolation
            }
            NSGraphicsContext.restoreGraphicsState()

            drawViewport(in: imageRect)
        }

        NSColor.systemGreen.withAlphaComponent(0.95).setStroke()
        outerPath.lineWidth = 3
        outerPath.stroke()
    }

    private func drawViewport(in imageRect: NSRect) {
        guard viewportRect.width > 0, viewportRect.height > 0 else { return }

        let rect = NSRect(
            x: imageRect.minX + viewportRect.minX * imageRect.width,
            y: imageRect.minY + viewportRect.minY * imageRect.height,
            width: max(8, viewportRect.width * imageRect.width),
            height: max(8, viewportRect.height * imageRect.height)
        ).intersection(imageRect)
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { return }

        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 2, yRadius: 2)
        NSColor.systemGreen.withAlphaComponent(0.18).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.88).setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }

    func unitPoint(forPointInSuperview point: NSPoint) -> NSPoint? {
        guard let superview else { return nil }
        return unitPoint(forLocalPoint: convert(point, from: superview))
    }

    private func updateFocus(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        var shouldFocus = true
        if let superview {
            shouldFocus = onPointerActivity?(convert(localPoint, to: superview)) ?? true
        }
        guard shouldFocus else { return }
        guard let unitPoint = unitPoint(forLocalPoint: localPoint) else { return }
        onFocusChanged?(unitPoint)
    }

    private func unitPoint(forLocalPoint point: NSPoint) -> NSPoint? {
        guard !bounds.isEmpty else { return nil }
        guard bounds.contains(point) else { return nil }

        let imageRect = thumbnailImageRect()
        guard imageRect.width > 0, imageRect.height > 0 else { return nil }

        let clamped = NSPoint(
            x: min(max(point.x, imageRect.minX), imageRect.maxX),
            y: min(max(point.y, imageRect.minY), imageRect.maxY)
        )
        return NSPoint(
            x: (clamped.x - imageRect.minX) / imageRect.width,
            y: (clamped.y - imageRect.minY) / imageRect.height
        )
    }

    private func thumbnailImageRect() -> NSRect {
        let content = bounds.insetBy(dx: 5, dy: 5)
        guard content.width > 0, content.height > 0 else { return .zero }
        guard let image, image.size.width > 0, image.size.height > 0 else { return content }

        let imageAspect = image.size.width / image.size.height
        let contentAspect = content.width / content.height
        if imageAspect >= contentAspect {
            let height = content.width / imageAspect
            return NSRect(
                x: content.minX,
                y: content.midY - height / 2,
                width: content.width,
                height: height
            )
        } else {
            let width = content.height * imageAspect
            return NSRect(
                x: content.midX - width / 2,
                y: content.minY,
                width: width,
                height: content.height
            )
        }
    }
}

// MARK: - Pin Toolbar

private final class PinToolbarView: NSView {
    static let preferredWidth: CGFloat = 290
    static let minimumWidth: CGFloat = 252
    static let preferredHeight: CGFloat = 34

    var onEdit: (() -> Void)?
    var onOCR: (() -> Void)?
    var onStage: (() -> Void)?
    var onMoveMouseDown: ((NSEvent) -> Void)?
    var onZoomOut: (() -> Void)?
    var onZoomIn: (() -> Void)?
    var onClose: (() -> Void)?
    var isOCRActive = false {
        didSet { ocrButton.isActive = isOCRActive }
    }

    var zoomScale: CGFloat = 1.0 {
        didSet {
            zoomLabel.stringValue = "\(Int(round(zoomScale * 100)))%"
        }
    }

    private let editButton = PinToolbarIconButton(symbolName: "pencil", accessibilityLabel: L10n.pinToolbarEdit)
    private let ocrButton = PinToolbarIconButton(symbolName: "text.viewfinder", accessibilityLabel: L10n.tipOCR)
    private let stageButton = PinToolbarIconButton(symbolName: "tray.and.arrow.down", accessibilityLabel: L10n.tipStage)
    private let moveButton = PinToolbarMoveButton(symbolName: "arrow.up.and.down.and.arrow.left.and.right",
                                                  accessibilityLabel: "Move pinned image")
    private let zoomOutButton = PinToolbarIconButton(symbolName: "minus", accessibilityLabel: "Zoom out")
    private let zoomLabel = NSTextField(labelWithString: "100%")
    private let zoomInButton = PinToolbarIconButton(symbolName: "plus", accessibilityLabel: "Zoom in")
    private let closeButton = PinToolbarIconButton(symbolName: "xmark",
                                                   accessibilityLabel: "Close pinned image")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = false

        editButton.toolTip = L10n.pinToolbarEdit
        editButton.target = self
        editButton.action = #selector(editTapped)
        ocrButton.toolTip = L10n.tipOCR
        ocrButton.target = self
        ocrButton.action = #selector(ocrTapped)
        stageButton.toolTip = L10n.tipStage
        stageButton.target = self
        stageButton.action = #selector(stageTapped)
        moveButton.onMouseDown = { [weak self] event in
            self?.onMoveMouseDown?(event)
        }

        zoomOutButton.target = self
        zoomOutButton.action = #selector(zoomOutTapped)
        zoomInButton.target = self
        zoomInButton.action = #selector(zoomInTapped)
        closeButton.target = self
        closeButton.action = #selector(closeTapped)

        zoomLabel.alignment = .center
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        zoomLabel.textColor = NSColor.white.withAlphaComponent(0.9)
        zoomLabel.backgroundColor = .clear
        zoomLabel.isBezeled = false
        zoomLabel.isEditable = false
        zoomLabel.isSelectable = false

        addSubview(moveButton)
        addSubview(editButton)
        addSubview(ocrButton)
        addSubview(stageButton)
        addSubview(zoomOutButton)
        addSubview(zoomLabel)
        addSubview(zoomInButton)
        addSubview(closeButton)
    }

    override func layout() {
        super.layout()

        let buttonSide = min(28, max(22, bounds.height - 6))
        let buttonY = (bounds.height - buttonSide) / 2
        let horizontalInset: CGFloat = 4
        let gap: CGFloat = 8
        let buttonGap: CGFloat = 4

        closeButton.frame = NSRect(x: horizontalInset, y: buttonY, width: buttonSide, height: buttonSide)
        moveButton.frame = NSRect(
            x: bounds.width - horizontalInset - buttonSide,
            y: buttonY,
            width: buttonSide,
            height: buttonSide
        )
        editButton.frame = NSRect(
            x: moveButton.frame.minX - buttonGap - buttonSide,
            y: buttonY,
            width: buttonSide,
            height: buttonSide
        )
        ocrButton.frame = NSRect(
            x: editButton.frame.minX - buttonGap - buttonSide,
            y: buttonY,
            width: buttonSide,
            height: buttonSide
        )
        stageButton.frame = NSRect(
            x: ocrButton.frame.minX - buttonGap - buttonSide,
            y: buttonY,
            width: buttonSide,
            height: buttonSide
        )

        let centerX = closeButton.frame.maxX + gap
        let centerWidth = max(76, stageButton.frame.minX - gap - centerX)
        let stepWidth = min(24, max(20, centerWidth * 0.22))
        let labelWidth = max(36, centerWidth - stepWidth * 2)

        zoomOutButton.frame = NSRect(x: centerX, y: buttonY, width: stepWidth, height: buttonSide)
        zoomLabel.frame = NSRect(x: zoomOutButton.frame.maxX, y: buttonY + 5,
                                 width: labelWidth, height: buttonSide - 10)
        zoomInButton.frame = NSRect(x: zoomLabel.frame.maxX, y: buttonY,
                                    width: stepWidth, height: buttonSide)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: bounds.height / 2,
                                yRadius: bounds.height / 2)
        NSColor(white: 0.08, alpha: 0.78).setFill()
        path.fill()

        NSColor.white.withAlphaComponent(0.18).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        nextResponder?.magnify(with: event)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {}

    @objc private func editTapped() {
        onEdit?()
    }

    @objc private func ocrTapped() {
        onOCR?()
    }

    @objc private func stageTapped() {
        onStage?()
    }

    @objc private func zoomOutTapped() {
        onZoomOut?()
    }

    @objc private func zoomInTapped() {
        onZoomIn?()
    }

    @objc private func closeTapped() {
        onClose?()
    }
}

private class PinToolbarIconButton: NSButton {
    var isActive = false {
        didSet { updateAppearance() }
    }

    init(symbolName: String, accessibilityLabel: String) {
        super.init(frame: .zero)
        title = ""
        isBordered = false
        imagePosition = .imageOnly
        bezelStyle = .regularSquare
        focusRingType = .none
        wantsLayer = true
        layer?.masksToBounds = true
        setAccessibilityLabel(accessibilityLabel)

        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel) {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            self.image = image.withSymbolConfiguration(config)
        }
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { false }

    override func layout() {
        super.layout()
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        nextResponder?.magnify(with: event)
    }

    private func updateAppearance() {
        contentTintColor = isActive ? .white : NSColor.white.withAlphaComponent(0.88)
        layer?.backgroundColor = (isActive
            ? accentGreen.withAlphaComponent(0.86)
            : NSColor.clear
        ).cgColor
    }
}

private final class PinToolbarMoveButton: PinToolbarIconButton {
    var onMouseDown: ((NSEvent) -> Void)?

    override func mouseDown(with event: NSEvent) {
        onMouseDown?(event)
    }
}

private final class TextPinToolbarView: NSView {
    static let preferredWidth: CGFloat = 106
    static let preferredHeight: CGFloat = 34

    var onClose: (() -> Void)?
    var onEdit: (() -> Void)?
    var onEditText: (() -> Void)?
    var onPointerEvent: ((NSEvent) -> Void)?

    private let closeButton = PinToolbarIconButton(symbolName: "xmark", accessibilityLabel: L10n.imageMergeClose)
    private let textEditButton = PinToolbarIconButton(symbolName: "textformat", accessibilityLabel: L10n.pinToolbarEditText)
    private let editButton = PinToolbarIconButton(symbolName: "pencil", accessibilityLabel: L10n.pinToolbarEdit)
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = false

        closeButton.toolTip = L10n.imageMergeClose
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        textEditButton.toolTip = L10n.pinToolbarEditText
        textEditButton.target = self
        textEditButton.action = #selector(editTextTapped)
        editButton.toolTip = L10n.pinToolbarEdit
        editButton.target = self
        editButton.action = #selector(editTapped)

        addSubview(closeButton)
        addSubview(textEditButton)
        addSubview(editButton)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
            self.trackingArea = nil
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func layout() {
        super.layout()

        let buttonSide = min(28, max(22, bounds.height - 6))
        let buttonY = (bounds.height - buttonSide) / 2
        let horizontalInset: CGFloat = 4
        let gap = max(4, (bounds.width - horizontalInset * 2 - buttonSide * 3) / 2)

        closeButton.frame = NSRect(
            x: horizontalInset,
            y: buttonY,
            width: buttonSide,
            height: buttonSide
        )
        textEditButton.frame = NSRect(
            x: closeButton.frame.maxX + gap,
            y: buttonY,
            width: buttonSide,
            height: buttonSide
        )
        editButton.frame = NSRect(
            x: textEditButton.frame.maxX + gap,
            y: buttonY,
            width: buttonSide,
            height: buttonSide
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: bounds.height / 2,
            yRadius: bounds.height / 2
        )
        NSColor(white: 0.08, alpha: 0.78).setFill()
        path.fill()

        NSColor.white.withAlphaComponent(0.18).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onPointerEvent?(event)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onPointerEvent?(event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onPointerEvent?(event)
    }

    override func mouseDown(with event: NSEvent) {
        onPointerEvent?(event)
    }

    override func mouseDragged(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {}

    @objc private func closeTapped() {
        onClose?()
    }

    @objc private func editTextTapped() {
        onEditText?()
    }

    @objc private func editTapped() {
        onEdit?()
    }
}
