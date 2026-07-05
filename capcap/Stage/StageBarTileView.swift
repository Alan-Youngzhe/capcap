import AppKit

/// One staged screenshot in the Stage Bar. Click toggles selection (for
/// multi-drag), dragging carries the tile (or the whole selection) out of the
/// bar. A plain drag feeds external apps: an accepted drop removes the items,
/// an unaccepted one snaps back and keeps them. Holding ⌥ switches the drag
/// into pin mode — nothing external can accept it, and release turns the
/// items into pinned windows at the drop point.
final class StageBarTileView: NSView, NSDraggingSource {
    /// Private pasteboard type used for ⌥-drags so no external app claims the
    /// drop and the release point is ours to pin at.
    private static let pinDragType = NSPasteboard.PasteboardType("cn.skyrin.capcap.stage-pin")
    let item: StageItem

    var onDelete: ((UUID) -> Void)?
    var onToggleSelection: ((UUID) -> Void)?
    var onRequestCollapse: (() -> Void)?
    var dragItemsProvider: ((StageBarTileView) -> [StageItem])?

    private let imageView = NSImageView()
    private let deleteButton = StageTileDeleteButton()
    private let selectionBadge = StageTileSelectionBadge()

    private var trackingArea: NSTrackingArea?
    private var isHovered = false
    private var selectionOrder: Int?

    private var mouseDownPoint: NSPoint?
    private var didStartDrag = false
    private var didRequestCollapseForDrag = false
    private var draggedItems: [StageItem] = []
    private var isPinDragSession = false

    init(item: StageItem) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor

        toolTip = L10n.stageTileHint

        imageView.image = item.image
        imageView.imageScaling = .scaleProportionallyDown
        imageView.unregisterDraggedTypes()
        addSubview(imageView)

        deleteButton.isHidden = true
        deleteButton.onClick = { [weak self] in
            guard let self else { return }
            self.onDelete?(self.item.id)
        }
        addSubview(deleteButton)

        selectionBadge.isHidden = true
        addSubview(selectionBadge)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        imageView.frame = bounds.insetBy(dx: 6, dy: 6)
        let buttonSize: CGFloat = 22
        deleteButton.frame = NSRect(
            x: bounds.maxX - buttonSize - 6,
            y: bounds.maxY - buttonSize - 6,
            width: buttonSize,
            height: buttonSize
        )
        selectionBadge.frame = NSRect(
            x: 6,
            y: bounds.maxY - buttonSize - 6,
            width: buttonSize,
            height: buttonSize
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        refreshOverlays()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        refreshOverlays()
    }

    func setSelectionOrder(_ order: Int?) {
        selectionOrder = order
        selectionBadge.order = order
        layer?.borderWidth = order == nil ? 0 : 2
        layer?.borderColor = accentGreen.withAlphaComponent(0.9).cgColor
        refreshOverlays()
    }

    private func refreshOverlays() {
        deleteButton.isHidden = !isHovered
        selectionBadge.isHidden = !(isHovered || selectionOrder != nil)
    }

    // MARK: Mouse & drag

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        didStartDrag = false
        didRequestCollapseForDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didStartDrag, let mouseDownPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - mouseDownPoint.x, point.y - mouseDownPoint.y) > 4 else { return }
        didStartDrag = true
        isPinDragSession = event.modifierFlags.contains(.option)

        draggedItems = dragItemsProvider?(self) ?? [item]
        guard !draggedItems.isEmpty else { return }
        if !isPinDragSession {
            StageManager.shared.waitForPendingWrites()
        }

        let baseImage = imageView.image ?? item.image
        var dragImage = draggedItems.count > 1
            ? Self.multiDragImage(base: baseImage, count: draggedItems.count)
            : baseImage
        if isPinDragSession {
            dragImage = Self.pinBadgeDragImage(base: dragImage)
        }
        let dragFrame = draggingFrame(for: dragImage)
        let items = draggedItems.enumerated().map { index, staged -> NSDraggingItem in
            let draggingItem: NSDraggingItem
            if isPinDragSession {
                let pasteboardItem = NSPasteboardItem()
                pasteboardItem.setString(staged.id.uuidString, forType: Self.pinDragType)
                draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
            } else {
                draggingItem = NSDraggingItem(pasteboardWriter: staged.fileURL as NSURL)
            }
            let offset = CGFloat(min(index, 2)) * 4
            draggingItem.setDraggingFrame(dragFrame.offsetBy(dx: offset, dy: offset), contents: dragImage)
            return draggingItem
        }
        let session = beginDraggingSession(with: items, event: event, source: self)
        // Plain drags snap back when nothing accepts them; pin drags must not,
        // because the pinned window appears at the release point instead.
        session.animatesToStartingPositionsOnCancelOrFail = !isPinDragSession
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownPoint = nil
            didStartDrag = false
        }
        guard !didStartDrag else { return }
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) {
            onToggleSelection?(item.id)
        }
    }

    private func draggingFrame(for image: NSImage) -> NSRect {
        let imageSize = image.size
        let container = imageView.bounds
        guard imageSize.width > 0, imageSize.height > 0,
              container.width > 0, container.height > 0
        else { return imageView.frame }

        let scale = min(container.width / imageSize.width, container.height / imageSize.height, 1)
        let fitted = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let rect = NSRect(
            x: container.midX - fitted.width / 2,
            y: container.midY - fitted.height / 2,
            width: fitted.width,
            height: fitted.height
        )
        return imageView.convert(rect, to: self)
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        guard !didRequestCollapseForDrag else { return }
        guard let window, !window.frame.contains(screenPoint) else { return }
        didRequestCollapseForDrag = true
        DispatchQueue.main.async { [weak self] in
            self?.onRequestCollapse?()
        }
    }

    /// Plain drag: an accepted drop means the items were used, so they leave
    /// the bar; an unaccepted one does nothing (the drag image snaps back).
    /// ⌥ pin drag: nothing can accept it, so release outside the bar pins the
    /// items at the drop point; release over the bar cancels.
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        let dragged = draggedItems
        let wasPinDrag = isPinDragSession
        draggedItems = []
        isPinDragSession = false
        guard !dragged.isEmpty else { return }

        if wasPinDrag {
            if let window, window.frame.contains(screenPoint) { return }
            let ids = Set(dragged.map(\.id))
            DispatchQueue.main.async {
                PinLauncher.pin(images: dragged.map(\.image), centeredAt: screenPoint)
                StageManager.shared.remove(ids: ids)
            }
        } else {
            guard !operation.isEmpty else { return }
            let ids = Set(dragged.map(\.id))
            DispatchQueue.main.async {
                StageManager.shared.remove(ids: ids)
            }
        }
    }

    /// Overlays a green pin badge on the drag preview so an ⌥ drag reads as
    /// "this will pin" while it is in flight.
    private static func pinBadgeDragImage(base: NSImage) -> NSImage {
        let baseSize = base.size.width > 0 && base.size.height > 0
            ? base.size
            : NSSize(width: 120, height: 80)
        let image = NSImage(size: baseSize)
        image.lockFocus()

        base.draw(in: NSRect(origin: .zero, size: baseSize), from: .zero, operation: .sourceOver, fraction: 1)

        let badgeSize: CGFloat = 26
        let badgeRect = NSRect(
            x: baseSize.width - badgeSize - 4,
            y: 4,
            width: badgeSize,
            height: badgeSize
        )
        accentGreen.withAlphaComponent(0.96).setFill()
        NSBezierPath(ovalIn: badgeRect).fill()

        if let pinGlyph = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .bold)) {
            let tinted = NSImage(size: pinGlyph.size)
            tinted.lockFocus()
            pinGlyph.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
            NSColor.white.set()
            NSRect(origin: .zero, size: pinGlyph.size).fill(using: .sourceAtop)
            tinted.unlockFocus()
            tinted.draw(
                in: NSRect(
                    x: badgeRect.midX - pinGlyph.size.width / 2,
                    y: badgeRect.midY - pinGlyph.size.height / 2,
                    width: pinGlyph.size.width,
                    height: pinGlyph.size.height
                ),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
        }

        image.unlockFocus()
        return image
    }

    private static func multiDragImage(base: NSImage, count: Int) -> NSImage {
        let baseSize = base.size.width > 0 && base.size.height > 0
            ? base.size
            : NSSize(width: 120, height: 80)
        let shadowOffset: CGFloat = 6
        let size = NSSize(width: baseSize.width + shadowOffset * 2, height: baseSize.height + shadowOffset * 2)
        let image = NSImage(size: size)
        image.lockFocus()

        for index in 0..<3 {
            let offset = CGFloat(2 - index) * 3
            let rect = NSRect(
                x: shadowOffset - offset,
                y: shadowOffset - offset,
                width: baseSize.width,
                height: baseSize.height
            )
            NSColor.black.withAlphaComponent(index == 2 ? 0.18 : 0.30).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        }

        base.draw(
            in: NSRect(x: shadowOffset, y: shadowOffset, width: baseSize.width, height: baseSize.height),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )

        let badgeSize: CGFloat = 28
        let badgeRect = NSRect(
            x: size.width - badgeSize - 2,
            y: size.height - badgeSize - 2,
            width: badgeSize,
            height: badgeSize
        )
        accentGreen.withAlphaComponent(0.96).setFill()
        NSBezierPath(ovalIn: badgeRect).fill()

        let text = "\(count)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let textSize = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: badgeRect.midX - textSize.width / 2, y: badgeRect.midY - textSize.height / 2),
            withAttributes: attributes
        )

        image.unlockFocus()
        return image
    }
}

// MARK: - Overlay controls

private final class StageTileDeleteButton: NSView {
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()

        let inset: CGFloat = 7
        let path = NSBezierPath()
        path.lineWidth = 1.6
        path.lineCapStyle = .round
        path.move(to: NSPoint(x: inset, y: inset))
        path.line(to: NSPoint(x: bounds.width - inset, y: bounds.height - inset))
        path.move(to: NSPoint(x: bounds.width - inset, y: inset))
        path.line(to: NSPoint(x: inset, y: bounds.height - inset))
        NSColor.white.withAlphaComponent(0.9).setStroke()
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        // Swallow so the tile below neither selects nor drags.
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) {
            onClick?()
        }
    }
}

private final class StageTileSelectionBadge: NSView {
    var order: Int? {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Purely decorative — clicks fall through to the tile.
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let circle = bounds.insetBy(dx: 1.5, dy: 1.5)
        if let order {
            accentGreen.withAlphaComponent(0.96).setFill()
            NSBezierPath(ovalIn: circle).fill()

            let text = "\(order)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold),
                .foregroundColor: NSColor.white
            ]
            let textSize = text.size(withAttributes: attributes)
            text.draw(
                at: NSPoint(x: circle.midX - textSize.width / 2, y: circle.midY - textSize.height / 2),
                withAttributes: attributes
            )
        } else {
            NSColor.black.withAlphaComponent(0.35).setFill()
            NSBezierPath(ovalIn: circle).fill()
            let ring = NSBezierPath(ovalIn: circle.insetBy(dx: 0.8, dy: 0.8))
            ring.lineWidth = 1.4
            NSColor.white.withAlphaComponent(0.85).setStroke()
            ring.stroke()
        }
    }
}
