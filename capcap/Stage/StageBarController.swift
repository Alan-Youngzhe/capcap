import AppKit

extension NSScreen {
    static func screenForMouseLocation() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(location) })
    }
}

/// Owns the Stage Bar window. The bar exists only while there are staged
/// items: it appears (collapsed against the right screen edge) when the first
/// item is staged and disappears when the last one leaves.
final class StageBarController {
    private(set) static weak var shared: StageBarController?

    private var windowController: StageBarWindowController?

    init() {
        Self.shared = self
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(stageItemsChanged),
            name: .stageItemsDidChange,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        windowController?.close()
    }

    /// Screen rect the stage fly-in animation should land on: the collapsed
    /// strip if the bar is visible, otherwise where the strip will appear once
    /// the pending item arrives.
    func flyTargetRect() -> NSRect {
        if let windowController {
            return windowController.collapsedStripScreenRect()
        }
        let screen = StageBarWindowController.anchorScreen()
        let geometry = StageBarGeometry.geometry(for: screen, itemCount: 1)
        let windowFrame = StageBarWindowController.frame(for: screen, geometry: geometry)
        return geometry.stripScreenRect(inWindowFrame: windowFrame)
    }

    @objc private func stageItemsChanged() {
        let items = StageManager.shared.items
        if items.isEmpty {
            windowController?.close()
            windowController = nil
            return
        }
        if windowController == nil {
            windowController = StageBarWindowController()
        }
        windowController?.apply(items: items)
    }
}

// MARK: - Geometry

struct StageBarGeometry {
    var itemCount: Int
    var screenVisibleFrame: NSRect
    var screenFrame: NSRect

    static let stripWidth: CGFloat = 22
    static let tileWidth: CGFloat = 204
    static let tileHeight: CGFloat = 138
    static let tileGap: CGFloat = 10
    static let contentInset: CGFloat = 12

    static func geometry(for screen: NSScreen?, itemCount: Int) -> StageBarGeometry {
        let fallback = NSRect(x: 0, y: 0, width: 1440, height: 900)
        return StageBarGeometry(
            itemCount: max(itemCount, 1),
            screenVisibleFrame: screen?.visibleFrame ?? fallback,
            screenFrame: screen?.frame ?? fallback
        )
    }

    var collapsedSize: NSSize {
        let height = min(56 + CGFloat(itemCount) * 20, 220)
        return NSSize(width: Self.stripWidth, height: height)
    }

    var expandedWidth: CGFloat {
        Self.tileWidth + Self.contentInset * 2
    }

    var maxPanelHeight: CGFloat {
        max(220, screenVisibleFrame.height - 120)
    }

    var expandedSize: NSSize {
        let count = CGFloat(itemCount)
        let needed = Self.contentInset * 2
            + count * Self.tileHeight
            + max(0, count - 1) * Self.tileGap
        return NSSize(width: expandedWidth, height: min(needed, maxPanelHeight))
    }

    /// The window never resizes; it is always big enough for the tallest
    /// expanded panel and the shell morphs inside it.
    var windowSize: NSSize {
        NSSize(width: expandedWidth, height: maxPanelHeight)
    }

    /// Collapsed strip rect in screen coordinates, given the window's frame.
    func stripScreenRect(inWindowFrame windowFrame: NSRect) -> NSRect {
        let size = collapsedSize
        return NSRect(
            x: windowFrame.maxX - size.width,
            y: windowFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}

// MARK: - Window controller

final class StageBarWindowController: NSWindowController {
    private let rootView = StageBarRootView()
    private var hoverSampler: DispatchSourceTimer?
    private var expandWorkItem: DispatchWorkItem?
    private var collapseWorkItem: DispatchWorkItem?
    private var isCollapsing = false
    private var suppressCollapseUntil: Date?

    private let expandDelay: TimeInterval = 0.03
    private let collapseDelay: TimeInterval = 0.35
    private let collapseAnimationDuration: TimeInterval = 0.36
    private let sampleInterval: TimeInterval = 0.035
    private let postExpandGrace: TimeInterval = 0.5

    init() {
        let screen = Self.anchorScreen()
        let geometry = StageBarGeometry.geometry(for: screen, itemCount: StageManager.shared.items.count)
        rootView.updateGeometry(geometry)
        let frame = Self.frame(for: screen, geometry: geometry)
        let panel = StageBarPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = true

        rootView.frame = NSRect(origin: .zero, size: frame.size)
        rootView.autoresizingMask = [.width, .height]
        panel.contentView = rootView

        super.init(window: panel)
        rootView.onRequestCollapse = { [weak self] in
            self?.collapse()
        }
        panel.orderFrontRegardless()
        startHoverSampler()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        close()
    }

    override func close() {
        NotificationCenter.default.removeObserver(self)
        stopHoverSampler()
        cancelExpand()
        cancelCollapse()
        super.close()
    }

    func apply(items: [StageItem]) {
        let screen = window?.screen ?? Self.anchorScreen()
        let geometry = StageBarGeometry.geometry(for: screen, itemCount: items.count)
        rootView.updateGeometry(geometry)
        rootView.apply(items: items)
    }

    func collapsedStripScreenRect() -> NSRect {
        guard let window else { return .zero }
        return rootView.geometry.stripScreenRect(inWindowFrame: window.frame)
    }

    // MARK: Placement

    static func anchorScreen() -> NSScreen? {
        NSScreen.screenForMouseLocation() ?? NSScreen.main ?? NSScreen.screens.first
    }

    static func frame(for screen: NSScreen?, geometry: StageBarGeometry) -> NSRect {
        let screenFrame = screen?.frame ?? geometry.screenFrame
        let size = geometry.windowSize
        return NSRect(
            x: screenFrame.maxX - size.width,
            y: screenFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    @objc private func screenDidChange() {
        let screen = Self.anchorScreen()
        let geometry = StageBarGeometry.geometry(for: screen, itemCount: StageManager.shared.items.count)
        rootView.updateGeometry(geometry)
        window?.setFrame(Self.frame(for: screen, geometry: geometry), display: true)
    }

    // MARK: Hover expand/collapse

    private func expand() {
        guard !rootView.isExpanded else { return }
        isCollapsing = false
        cancelCollapse()
        window?.ignoresMouseEvents = false
        window?.orderFrontRegardless()
        window?.makeKey()
        rootView.setExpanded(true, animated: true)
    }

    private func collapse() {
        guard rootView.isExpanded else { return }
        cancelExpand()
        rootView.setExpanded(false, animated: true)
        isCollapsing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + collapseAnimationDuration) { [weak self] in
            guard let self, self.isCollapsing else { return }
            self.isCollapsing = false
            self.window?.ignoresMouseEvents = true
        }
    }

    private func startHoverSampler() {
        guard hoverSampler == nil else { return }
        let sampler = DispatchSource.makeTimerSource(queue: .main)
        sampler.schedule(deadline: .now(), repeating: sampleInterval, leeway: .milliseconds(8))
        sampler.setEventHandler { [weak self] in
            self?.handleMouseMove()
        }
        hoverSampler = sampler
        sampler.resume()
    }

    private func stopHoverSampler() {
        hoverSampler?.setEventHandler {}
        hoverSampler?.cancel()
        hoverSampler = nil
    }

    private func handleMouseMove() {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation

        if rootView.isExpanded {
            if expandedHoverRect(in: window).contains(mouse) {
                cancelCollapse()
            } else {
                if let until = suppressCollapseUntil, Date() < until { return }
                scheduleCollapse()
            }
        } else {
            if collapsedHitRect(in: window).contains(mouse) {
                scheduleExpand()
            } else {
                cancelExpand()
            }
        }
    }

    private func expandedHoverRect(in window: NSWindow) -> NSRect {
        let expanded = rootView.expandedShellScreenRect(inWindowFrame: window.frame)
        return expanded.insetBy(dx: -30, dy: -15)
    }

    private func collapsedHitRect(in window: NSWindow) -> NSRect {
        rootView.geometry
            .stripScreenRect(inWindowFrame: window.frame)
            .insetBy(dx: -10, dy: -10)
    }

    private func scheduleExpand() {
        guard expandWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.expandWorkItem = nil
            self.expand()
            self.suppressCollapseUntil = Date().addingTimeInterval(self.postExpandGrace)
        }
        expandWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + expandDelay, execute: work)
    }

    private func cancelExpand() {
        expandWorkItem?.cancel()
        expandWorkItem = nil
    }

    private func scheduleCollapse() {
        guard collapseWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.collapseWorkItem = nil
            self.collapse()
        }
        collapseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + collapseDelay, execute: work)
    }

    private func cancelCollapse() {
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
    }
}

private final class StageBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
