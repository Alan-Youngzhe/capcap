import AppKit

extension Notification.Name {
    /// Posted on the main queue whenever staged items are added or removed.
    static let stageItemsDidChange = Notification.Name("stageItemsDidChange")
}

/// One staged screenshot waiting in the Stage Bar. The image lives in memory;
/// `fileURL` points at a PNG in the session's stage directory so tiles can be
/// dragged into other apps as regular files.
struct StageItem {
    let id: UUID
    let image: NSImage
    let fileURL: URL
    let stagedAt: Date
}

/// In-memory store behind the Stage Bar. Deliberately not persistent: the bar
/// is a working tray, not an archive — its backing directory is wiped on every
/// launch, and history stays the job of HistoryManager.
final class StageManager {
    static let shared = StageManager()

    /// Main-thread only.
    private(set) var items: [StageItem] = []

    private let fileQueue = DispatchQueue(label: "capcap.stage", qos: .userInitiated)

    private static let directory: URL = {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("capcap-stage", isDirectory: true)
    }()

    private static let filenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter
    }()

    private init() {
        fileQueue.async {
            let fm = FileManager.default
            try? fm.removeItem(at: Self.directory)
            try? fm.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        }
    }

    @discardableResult
    func add(image: NSImage) -> StageItem {
        let stagedAt = Date()
        let name = Self.filenameFormatter.string(from: stagedAt) + ".png"
        let url = Self.directory.appendingPathComponent(name)
        let item = StageItem(id: UUID(), image: image, fileURL: url, stagedAt: stagedAt)

        fileQueue.async {
            guard let data = image.pngDataPreservingBacking() else { return }
            try? data.write(to: url, options: .atomic)
        }

        items.append(item)
        postChange()
        return item
    }

    func remove(ids: Set<UUID>) {
        let countBefore = items.count
        items.removeAll { ids.contains($0.id) }
        guard items.count != countBefore else { return }
        postChange()
    }

    func remove(id: UUID) {
        remove(ids: [id])
    }

    /// Blocks until every pending PNG write has landed on disk. Called right
    /// before a drag session starts so the promised file URLs are real.
    func waitForPendingWrites() {
        fileQueue.sync {}
    }

    private func postChange() {
        NotificationCenter.default.post(name: .stageItemsDidChange, object: nil)
    }
}
