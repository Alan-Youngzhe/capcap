import AppKit

/// Crop overlay shown after a long-screenshot scroll capture. The whole
/// stitched image is scaled to fit on screen so the user sees all of it at
/// once; only the top and bottom edges move — the width is fixed.
///
/// At fit scale a long screenshot shrinks to a thin sliver, so dragging an
/// edge pops a 1:1 loupe at the cut line, letting the user place it exactly.
final class ScrollCropView: NSView {
    private let image: NSImage
    private let cgImage: CGImage?

    private enum Edge { case top, bottom }

    // Geometry, recomputed on layout. `imageFrame` is the on-screen rect the
    // scaled image occupies; `cropTop`/`cropBottom` are the cut lines, all in
    // this view's flipped (top-left origin) coordinates.
    private var imageFrame: NSRect = .zero
    private var cropTop: CGFloat = 0
    private var cropBottom: CGFloat = 0
    private var scaledImage: NSImage?
    private var lastLaidOutSize: NSSize = .zero

    private var activeEdge: Edge?

    private let accent = NSColor(red: 0, green: 212.0 / 255.0, blue: 106.0 / 255.0, alpha: 1.0)
    private let outerMargin: CGFloat = 80
    private let minimumCropHeight: CGFloat = 12
    private let edgeHitInset: CGFloat = 16
    private let loupeSize = NSSize(width: 280, height: 190)

    init(frame frameRect: NSRect, image: NSImage) {
        self.image = image
        self.cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        super.init(frame: frameRect)
        recomputeLayout(resetCrop: true)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        recomputeLayout(resetCrop: false)
    }

    // MARK: - Result

    /// The stitched image cropped to the current top/bottom selection.
    func croppedImage() -> NSImage {
        guard imageFrame.height > 0, let cg = cgImage else { return image }

        let topFraction = max(0, (cropTop - imageFrame.minY) / imageFrame.height)
        let bottomFraction = min(1, (cropBottom - imageFrame.minY) / imageFrame.height)

        let pxTop = (topFraction * CGFloat(cg.height)).rounded()
        let pxBottom = (bottomFraction * CGFloat(cg.height)).rounded()
        let pxHeight = max(1, pxBottom - pxTop)

        // CGImage has a top-left origin, so the crop is a full-width band.
        let band = CGRect(x: 0, y: pxTop, width: CGFloat(cg.width), height: pxHeight)
        guard let cropped = cg.cropping(to: band) else { return image }

        let scaleX = CGFloat(cg.width) / max(image.size.width, 1)
        let scaleY = CGFloat(cg.height) / max(image.size.height, 1)
        return NSImage(
            cgImage: cropped,
            size: NSSize(
                width: CGFloat(cropped.width) / scaleX,
                height: CGFloat(cropped.height) / scaleY
            )
        )
    }

    // MARK: - Layout

    private func recomputeLayout(resetCrop: Bool) {
        guard resetCrop || bounds.size != lastLaidOutSize else { return }
        lastLaidOutSize = bounds.size

        let fractions = resetCrop ? nil : currentCropFractions()

        let availableW = max(1, bounds.width - outerMargin * 2)
        let availableH = max(1, bounds.height - outerMargin * 2)
        let imgW = max(1, image.size.width)
        let imgH = max(1, image.size.height)
        // Fit the whole image; never upscale past 1:1.
        let scale = min(availableW / imgW, availableH / imgH, 1)
        let drawSize = NSSize(width: imgW * scale, height: imgH * scale)

        imageFrame = NSRect(
            x: ((bounds.width - drawSize.width) / 2).rounded(),
            y: ((bounds.height - drawSize.height) / 2).rounded(),
            width: drawSize.width,
            height: drawSize.height
        )

        if let fractions {
            cropTop = imageFrame.minY + fractions.lowerBound * imageFrame.height
            cropBottom = imageFrame.minY + fractions.upperBound * imageFrame.height
        } else {
            cropTop = imageFrame.minY
            cropBottom = imageFrame.maxY
        }

        scaledImage = makeScaledImage(targetSize: imageFrame.size)
        needsDisplay = true
    }

    private func currentCropFractions() -> ClosedRange<CGFloat>? {
        guard imageFrame.height > 0 else { return nil }
        let lo = (cropTop - imageFrame.minY) / imageFrame.height
        let hi = (cropBottom - imageFrame.minY) / imageFrame.height
        return Swift.min(lo, hi)...Swift.max(lo, hi)
    }

    /// Pre-renders the heavily down-scaled image once so per-frame redraws
    /// (especially during a drag) just blit a small bitmap.
    private func makeScaledImage(targetSize: NSSize) -> NSImage? {
        guard targetSize.width >= 1, targetSize.height >= 1 else { return nil }
        let scaled = NSImage(size: targetSize)
        scaled.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        scaled.unlockFocus()
        return scaled
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.08, alpha: 1).setFill()
        bounds.fill()

        guard imageFrame.width > 0 else { return }

        // `respectFlipped: true` is required — the plain draw(in:from:...)
        // ignores the view's flipped state and renders the image upside down.
        scaledImage?.draw(
            in: imageFrame,
            from: .zero,
            operation: .copy,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )

        // Dim the trimmed-away strips.
        NSColor(white: 0, alpha: 0.62).setFill()
        NSRect(
            x: imageFrame.minX, y: imageFrame.minY,
            width: imageFrame.width, height: cropTop - imageFrame.minY
        ).fill()
        NSRect(
            x: imageFrame.minX, y: cropBottom,
            width: imageFrame.width, height: imageFrame.maxY - cropBottom
        ).fill()

        // Kept-region border.
        accent.setStroke()
        let border = NSBezierPath(rect: NSRect(
            x: imageFrame.minX, y: cropTop,
            width: imageFrame.width, height: cropBottom - cropTop
        ))
        border.lineWidth = 2
        border.stroke()

        drawHandle(atY: cropTop)
        drawHandle(atY: cropBottom)

        if let activeEdge {
            drawLoupe(forEdge: activeEdge)
        }
    }

    private func drawHandle(atY y: CGFloat) {
        accent.setStroke()
        let line = NSBezierPath()
        line.lineWidth = 2
        line.move(to: NSPoint(x: imageFrame.minX, y: y))
        line.line(to: NSPoint(x: imageFrame.maxX, y: y))
        line.stroke()

        let tab = NSRect(x: imageFrame.midX - 24, y: y - 7, width: 48, height: 14)
        accent.setFill()
        NSBezierPath(roundedRect: tab, xRadius: 7, yRadius: 7).fill()
        NSColor.white.setFill()
        for dx in [-7.0, 0.0, 7.0] {
            NSBezierPath(ovalIn: NSRect(
                x: tab.midX + dx - 1.5, y: tab.midY - 1.5, width: 3, height: 3
            )).fill()
        }
    }

    /// Draws a 1:1 magnified window of the image at the cut line so the user
    /// can crop precisely despite the tiny fit-scaled preview.
    private func drawLoupe(forEdge edge: Edge) {
        guard let cg = cgImage else { return }
        let lineY = (edge == .top) ? cropTop : cropBottom
        let fraction = clamp((lineY - imageFrame.minY) / max(imageFrame.height, 1), 0, 1)

        let pixelScale = CGFloat(cg.height) / max(image.size.height, 1)
        let bandH = min(loupeSize.height * pixelScale, CGFloat(cg.height))
        let bandW = min(loupeSize.width * pixelScale, CGFloat(cg.width))
        let centerPx = fraction * CGFloat(cg.height)
        let bandY = clamp(centerPx - bandH / 2, 0, max(0, CGFloat(cg.height) - bandH))
        let bandX = (CGFloat(cg.width) - bandW) / 2
        let band = CGRect(x: bandX, y: bandY, width: bandW, height: bandH)

        let loupeRect = loupeFrame(forLineY: lineY)

        NSColor(white: 0.1, alpha: 0.96).setFill()
        NSBezierPath(
            roundedRect: loupeRect.insetBy(dx: -10, dy: -10),
            xRadius: 12, yRadius: 12
        ).fill()

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: loupeRect).addClip()
        NSColor.black.setFill()
        loupeRect.fill()
        if let cropped = cg.cropping(to: band) {
            NSImage(cgImage: cropped, size: loupeRect.size).draw(
                in: loupeRect,
                from: .zero,
                operation: .copy,
                fraction: 1,
                respectFlipped: true,
                hints: nil
            )
        }
        NSGraphicsContext.restoreGraphicsState()

        // Cut-line marker — tracks the real cut position even when the band
        // was clamped against the top or bottom of the image.
        let markerFraction = bandH > 0 ? (centerPx - bandY) / bandH : 0.5
        let markerY = loupeRect.minY + markerFraction * loupeRect.height
        NSColor.systemRed.setStroke()
        let marker = NSBezierPath()
        marker.lineWidth = 2
        marker.move(to: NSPoint(x: loupeRect.minX, y: markerY))
        marker.line(to: NSPoint(x: loupeRect.maxX, y: markerY))
        marker.stroke()

        accent.setStroke()
        let frame = NSBezierPath(rect: loupeRect)
        frame.lineWidth = 1.5
        frame.stroke()
    }

    private func loupeFrame(forLineY lineY: CGFloat) -> NSRect {
        var y = lineY - loupeSize.height / 2
        y = clamp(y, bounds.minY + 16, bounds.maxY - 16 - loupeSize.height)

        // The fit-scaled image is a thin sliver, so there is room beside it.
        var x = imageFrame.maxX + 44
        if x + loupeSize.width > bounds.maxX - 16 {
            x = imageFrame.minX - 44 - loupeSize.width
        }
        x = clamp(x, bounds.minX + 16, bounds.maxX - 16 - loupeSize.width)
        return NSRect(x: x, y: y, width: loupeSize.width, height: loupeSize.height)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        activeEdge = edge(at: point)
        if activeEdge != nil { needsDisplay = true }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let activeEdge else { return }
        let point = convert(event.locationInWindow, from: nil)
        switch activeEdge {
        case .top:
            cropTop = clamp(point.y, imageFrame.minY, cropBottom - minimumCropHeight)
        case .bottom:
            cropBottom = clamp(point.y, cropTop + minimumCropHeight, imageFrame.maxY)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        activeEdge = nil
        needsDisplay = true
    }

    private func edge(at point: NSPoint) -> Edge? {
        guard point.x >= imageFrame.minX - 36, point.x <= imageFrame.maxX + 36 else {
            return nil
        }
        let nearTop = abs(point.y - cropTop)
        let nearBottom = abs(point.y - cropBottom)
        if nearTop <= edgeHitInset && nearTop <= nearBottom { return .top }
        if nearBottom <= edgeHitInset { return .bottom }
        return nil
    }

    // MARK: - Cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        (edge(at: point) != nil ? NSCursor.resizeUpDown : NSCursor.arrow).set()
    }

    private func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        guard upper > lower else { return lower }
        return Swift.max(lower, Swift.min(upper, value))
    }
}
