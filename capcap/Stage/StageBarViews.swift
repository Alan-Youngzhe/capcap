import AppKit

/// Content of the Stage Bar window: a black left-rounded shell hugging the
/// right screen edge that morphs between a slim collapsed strip and the
/// expanded tile list.
final class StageBarRootView: NSView {
    private(set) var geometry = StageBarGeometry.geometry(for: nil, itemCount: 1)

    private let shellView = StageBarShellView()
    private let contentView = StageBarContentView()
    private let collapsedLabel = NSTextField(labelWithString: "")

    private(set) var isExpanded = false
    private var currentSize: NSSize = .zero

    var onRequestCollapse: (() -> Void)? {
        didSet {
            contentView.onRequestCollapse = onRequestCollapse
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        shellView.frame = bounds
        shellView.autoresizingMask = [.width, .height]
        addSubview(shellView)

        contentView.alphaValue = 0
        contentView.isHidden = true
        shellView.addSubview(contentView)

        collapsedLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        collapsedLabel.textColor = NSColor.white.withAlphaComponent(0.90)
        collapsedLabel.alignment = .center
        collapsedLabel.isSelectable = false
        shellView.addSubview(collapsedLabel)

        currentSize = geometry.collapsedSize
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        layoutShell(animated: false)
    }

    func updateGeometry(_ geometry: StageBarGeometry) {
        self.geometry = geometry
        currentSize = isExpanded ? geometry.expandedSize : geometry.collapsedSize
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func apply(items: [StageItem]) {
        collapsedLabel.stringValue = "\(items.count)"
        contentView.apply(items: items)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func setExpanded(_ expanded: Bool, animated: Bool) {
        guard isExpanded != expanded else { return }
        isExpanded = expanded
        currentSize = expanded ? geometry.expandedSize : geometry.collapsedSize

        if expanded {
            contentView.isHidden = false
        }

        let changes = {
            self.contentView.alphaValue = expanded ? 1 : 0
            self.collapsedLabel.alphaValue = expanded ? 0 : 1
        }

        layoutShell(animated: animated)

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = expanded ? 0.35 : 0.3
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                changes()
            } completionHandler: {
                self.contentView.isHidden = !expanded
            }
        } else {
            changes()
            contentView.isHidden = !expanded
        }
    }

    func expandedShellScreenRect(inWindowFrame windowFrame: NSRect) -> NSRect {
        let rect = shapeRect(for: geometry.expandedSize)
        return NSRect(
            x: windowFrame.minX + rect.minX,
            y: windowFrame.minY + rect.minY,
            width: rect.width,
            height: rect.height
        )
    }

    private func layoutShell(animated: Bool) {
        shellView.frame = bounds

        let currentRect = shapeRect(for: currentSize)
        let expandedRect = shapeRect(for: geometry.expandedSize)
        let collapsedRect = shapeRect(for: geometry.collapsedSize)

        shellView.setShape(rect: currentRect, expanded: isExpanded, animated: animated)
        contentView.frame = expandedRect
        collapsedLabel.frame = NSRect(
            x: collapsedRect.minX,
            y: collapsedRect.midY - 8,
            width: collapsedRect.width - 2,
            height: 16
        )
    }

    /// Shapes hug the right edge of the window, vertically centered.
    private func shapeRect(for size: NSSize) -> NSRect {
        NSRect(
            x: bounds.maxX - size.width,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}

/// The morphing black shell: straight along the screen edge on the right,
/// rounded corners on the left. Same spring-path approach as the notch shell.
final class StageBarShellView: NSView {
    private let fillLayer = CAShapeLayer()
    private let maskLayer = CAShapeLayer()
    private var shapeRect: NSRect = .zero
    private var isExpanded = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        fillLayer.fillColor = NSColor.black.withAlphaComponent(0.92).cgColor
        layer?.addSublayer(fillLayer)
        maskLayer.fillColor = NSColor.black.cgColor
        layer?.mask = maskLayer
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        updateMask(animated: false)
    }

    func setShape(rect: NSRect, expanded: Bool, animated: Bool) {
        let previousPath = maskLayer.presentation()?.path ?? maskLayer.path
        shapeRect = rect
        isExpanded = expanded
        updateMask(animated: animated, from: previousPath)
    }

    private func updateMask(animated: Bool, from previousPath: CGPath? = nil) {
        guard shapeRect.width > 0, shapeRect.height > 0 else { return }

        let path = Self.dockPath(in: shapeRect, cornerRadius: isExpanded ? 16 : 9)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.frame = bounds
        fillLayer.path = path
        maskLayer.frame = bounds
        maskLayer.path = path
        CATransaction.commit()

        guard animated, let previousPath else { return }

        let animation = Self.springAnimation(
            keyPath: "path",
            from: previousPath,
            to: path,
            expanded: isExpanded
        )
        fillLayer.add(animation, forKey: "stageBarFill")
        maskLayer.add(animation, forKey: "stageBarShape")
    }

    /// Left-rounded slab: flat right edge (flush with the screen edge),
    /// rounded top-left and bottom-left corners.
    private static func dockPath(in rect: NSRect, cornerRadius: CGFloat) -> CGPath {
        let radius = max(0, min(cornerRadius, rect.width * 0.9, rect.height * 0.5))
        let path = CGMutablePath()

        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.minY + radius),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + radius, y: rect.maxY),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()

        return path
    }

    private static func springAnimation(
        keyPath: String,
        from: CGPath,
        to: CGPath,
        expanded: Bool
    ) -> CASpringAnimation {
        let response: CGFloat = expanded ? 0.35 : 0.3
        let dampingFraction: CGFloat = expanded ? 0.86 : 0.9
        let omega = 2 * CGFloat.pi / response
        let animation = CASpringAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.mass = 1
        animation.stiffness = Double(omega * omega)
        animation.damping = Double(2 * dampingFraction * omega)
        animation.initialVelocity = 0
        animation.duration = min(max(animation.settlingDuration, Double(response)), 0.7)
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return animation
    }
}

/// The expanded panel content: a vertical, scrollable list of staged tiles.
final class StageBarContentView: NSView {
    var onRequestCollapse: (() -> Void)?

    private let scrollView = NSScrollView()
    private let listView = StageBarListView()
    private var tiles: [StageBarTileView] = []
    private var selectedIDs: [UUID] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.verticalScrollElasticity = .allowed
        scrollView.horizontalScrollElasticity = .none
        scrollView.documentView = listView
        scrollView.automaticallyAdjustsContentInsets = false
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        layoutList()
    }

    func apply(items: [StageItem]) {
        let liveIDs = Set(items.map(\.id))
        selectedIDs.removeAll { !liveIDs.contains($0) }

        tiles.forEach { $0.removeFromSuperview() }
        tiles = items.map { item in
            let tile = StageBarTileView(item: item)
            tile.onDelete = { [weak self] id in
                self?.selectedIDs.removeAll { $0 == id }
                StageManager.shared.remove(id: id)
            }
            tile.onToggleSelection = { [weak self] id in
                self?.toggleSelection(id)
            }
            tile.dragItemsProvider = { [weak self] tile in
                self?.dragItems(for: tile) ?? [tile.item]
            }
            tile.onRequestCollapse = { [weak self] in
                self?.onRequestCollapse?()
            }
            listView.addSubview(tile)
            return tile
        }
        refreshSelectionBadges()
        layoutList()
    }

    private func toggleSelection(_ id: UUID) {
        if let index = selectedIDs.firstIndex(of: id) {
            selectedIDs.remove(at: index)
        } else {
            selectedIDs.append(id)
        }
        refreshSelectionBadges()
    }

    private func refreshSelectionBadges() {
        for tile in tiles {
            let order = selectedIDs.firstIndex(of: tile.item.id).map { $0 + 1 }
            tile.setSelectionOrder(order)
        }
    }

    /// Dragging a selected tile carries the whole selection (in selection
    /// order); dragging an unselected tile carries just that tile.
    private func dragItems(for tile: StageBarTileView) -> [StageItem] {
        guard selectedIDs.contains(tile.item.id) else { return [tile.item] }
        let byID = Dictionary(uniqueKeysWithValues: tiles.map { ($0.item.id, $0.item) })
        return selectedIDs.compactMap { byID[$0] }
    }

    private func layoutList() {
        let inset = StageBarGeometry.contentInset
        let tileWidth = StageBarGeometry.tileWidth
        let tileHeight = StageBarGeometry.tileHeight
        let gap = StageBarGeometry.tileGap

        let count = CGFloat(tiles.count)
        let contentHeight = max(
            bounds.height,
            inset * 2 + count * tileHeight + max(0, count - 1) * gap
        )
        listView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: contentHeight)

        var y = contentHeight - inset - tileHeight
        for tile in tiles {
            tile.frame = NSRect(x: inset, y: y, width: tileWidth, height: tileHeight)
            y -= tileHeight + gap
        }
    }
}

private final class StageBarListView: NSView {
    override var isFlipped: Bool { false }
}
