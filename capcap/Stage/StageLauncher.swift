import AppKit

/// Entry point for the stage action: sends a captured image into the Stage
/// Bar, with a macOS-minimize-style fly animation from the capture rect to
/// the bar's collapsed strip on the right screen edge.
enum StageLauncher {
    /// Strong refs keep fly windows alive for the duration of their animation.
    private static var flyWindows: [NSWindow] = []

    /// Hotkey entry: stages the images currently selected in Finder. Same
    /// source-specificity as the old pin hotkey — no clipboard fallback.
    @discardableResult
    static func stageSelectedImagesIfAvailable() -> Bool {
        let images = FinderSelection.currentImageFileURLs().compactMap(loadImage)
        guard !images.isEmpty else {
            ToastWindow.show(message: L10n.selectedImagePinNoImage)
            return false
        }

        images.forEach { StageManager.shared.add(image: $0) }
        ToastWindow.show(message: L10n.pinFromFinderHint)
        return true
    }

    /// Hotkey entry: stages the image currently on the clipboard.
    @discardableResult
    static func stageClipboardImageIfAvailable() -> Bool {
        guard let image = ClipboardImageSource.currentImage() else {
            ToastWindow.show(message: L10n.clipboardImagePinNoImage)
            return false
        }

        StageManager.shared.add(image: image)
        ToastWindow.show(message: L10n.pinFromClipboardHint)
        return true
    }

    private static func loadImage(from url: URL) -> NSImage? {
        guard let data = try? Data(contentsOf: url),
              let image = NSImage.imagePreservingPixelDimensions(from: data),
              image.size.width > 0, image.size.height > 0
        else { return nil }
        return image
    }

    static func stage(image: NSImage, from sourceRect: NSRect?) {
        guard let sourceRect, sourceRect.width > 2, sourceRect.height > 2,
              let controller = StageBarController.shared
        else {
            StageManager.shared.add(image: image)
            return
        }

        let target = controller.flyTargetRect()
        animateFly(image: image, from: sourceRect, to: target) {
            StageManager.shared.add(image: image)
        }
    }

    private static func animateFly(
        image: NSImage,
        from source: NSRect,
        to target: NSRect,
        completion: @escaping () -> Void
    ) {
        let window = NSWindow(
            contentRect: source,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .statusBar
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false

        let imageView = NSImageView(frame: NSRect(origin: .zero, size: source.size))
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 8
        imageView.layer?.masksToBounds = true
        window.contentView = imageView
        window.orderFrontRegardless()

        flyWindows.append(window)

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.45
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.35, 0.0, 0.18, 1.0)
            window.animator().setFrame(target, display: true)
            window.animator().alphaValue = 0.3
        }, completionHandler: {
            window.orderOut(nil)
            window.contentView = nil
            flyWindows.removeAll { $0 === window }
            completion()
        })
    }
}
