import AppKit
import ApplicationServices

/// Drives a constant-speed automatic scroll over a screen region by posting
/// synthetic scroll-wheel events, so long-screenshot capture no longer needs
/// the user to scroll by hand. Uniform steps mean evenly-spaced frames, which
/// the stitcher can align far more reliably than uneven manual scrolling.
///
/// The loop posts one fixed scroll step, waits for the screen to settle, asks
/// the caller to capture a frame, and repeats. When several consecutive frames
/// report no new content, the page has bottomed out and the loop finishes.
final class AutoScroller {
    /// What a single capture step revealed, reported back by the caller.
    enum StepResult {
        /// The step revealed fresh content — keep scrolling.
        case progressed
        /// No new content this step (duplicate / tiny delta).
        case stalled
        /// Capturing must stop now (e.g. the frame budget is exhausted).
        case finished
    }

    /// Auto-scroll posts events into other apps, which requires the process to
    /// be trusted for Accessibility. Without it, posting silently no-ops.
    static var isPermitted: Bool { AXIsProcessTrusted() }

    /// Asks the system to surface the Accessibility permission prompt for
    /// capcap. Returns the current trust state.
    @discardableResult
    static func requestPermission() -> Bool {
        // Literal value of `kAXTrustedCheckOptionPrompt` — used directly to
        // avoid the constant's Unmanaged/CFString typing churn across SDKs.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private let location: CGPoint           // global CG coords (top-left origin)
    private let stepPixels: Int
    private let settleDelay: TimeInterval
    private let stallThreshold: Int
    private let queue = DispatchQueue(label: "capcap.auto-scroll", qos: .userInitiated)
    private let eventSource = CGEventSource(stateID: .hidSystemState)

    private let lock = NSLock()
    private var cancelledFlag = false

    private var cancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelledFlag
    }

    /// - Parameters:
    ///   - centerPoint: where to aim the scroll events, in global CG coords.
    ///   - stepPixels: how far to scroll per step (also the overlap hint).
    ///   - settleDelay: pause after each step so the screen finishes redrawing.
    ///   - stallThreshold: consecutive no-progress steps that mean "page end".
    init(
        centerPoint: CGPoint,
        stepPixels: Int,
        settleDelay: TimeInterval = 0.12,
        stallThreshold: Int = 4
    ) {
        self.location = centerPoint
        self.stepPixels = max(20, stepPixels)
        self.settleDelay = settleDelay
        self.stallThreshold = stallThreshold
    }

    /// Begins the scroll loop on a background queue.
    /// - Parameters:
    ///   - captureStep: invoked off the main thread after each scroll step;
    ///     should capture a frame and report what it revealed.
    ///   - onFinished: invoked on the main queue once the page has bottomed
    ///     out (not called if `stop()` cancels the loop first).
    func start(
        captureStep: @escaping () -> StepResult,
        onFinished: @escaping () -> Void
    ) {
        queue.async { [weak self] in
            self?.runLoop(captureStep: captureStep, onFinished: onFinished)
        }
    }

    /// Cancels the loop. The loop exits at its next checkpoint (within roughly
    /// `settleDelay`); `onFinished` will not fire afterwards.
    func stop() {
        lock.lock()
        cancelledFlag = true
        lock.unlock()
    }

    private func runLoop(
        captureStep: @escaping () -> StepResult,
        onFinished: @escaping () -> Void
    ) {
        var stallCount = 0

        while true {
            if cancelled { return }
            postScrollStep()
            Thread.sleep(forTimeInterval: settleDelay)
            if cancelled { return }

            switch captureStep() {
            case .progressed:
                stallCount = 0
            case .stalled:
                stallCount += 1
            case .finished:
                stallCount = stallThreshold
            }

            if stallCount >= stallThreshold {
                if !cancelled {
                    DispatchQueue.main.async { onFinished() }
                }
                return
            }
        }
    }

    private func postScrollStep() {
        // Negative wheel1 scrolls the page content downward, revealing content
        // further down — the direction long-screenshot stitching expects.
        guard let event = CGEvent(
            scrollWheelEvent2Source: eventSource,
            units: .pixel,
            wheelCount: 1,
            wheel1: Int32(-stepPixels),
            wheel2: 0,
            wheel3: 0
        ) else {
            return
        }

        event.location = location
        event.post(tap: .cghidEventTap)
    }
}
