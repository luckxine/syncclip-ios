import Foundation

/// App 内日志环形缓冲。挂到 `SCLog.sink` 上，界面就能实时看到同步在干什么。
public final class SCInAppLog {

    public struct Entry: Identifiable, Equatable {
        public let id: UInt64
        public let time: Date
        public let text: String
    }

    private let capacity: Int
    private let lock = NSLock()
    private var storage: [Entry] = []
    private var nextId: UInt64 = 1

    /// 有新日志时回调（在写入线程上调用，UI 层自己切主线程）
    public var onAppend: ((Entry) -> Void)?

    public init(capacity: Int = 400) {
        self.capacity = max(16, capacity)
    }

    public func append(_ text: String) {
        lock.lock()
        let entry = Entry(id: nextId, time: Date(), text: text)
        nextId += 1
        storage.append(entry)
        if storage.count > capacity {
            storage.removeFirst(storage.count - capacity)
        }
        lock.unlock()
        onAppend?(entry)
    }

    public func snapshot() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    public func clear() {
        lock.lock()
        storage.removeAll()
        lock.unlock()
    }

    /// 一次性文本，方便"分享/复制全部日志"
    public func plainText() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return snapshot().map { "[\(f.string(from: $0.time))] \($0.text)" }.joined(separator: "\n")
    }

    /// 挂到全局日志口上
    public func install() {
        SCLog.sink = { [weak self] line in
            self?.append(line)
        }
    }

    public func uninstall() {
        SCLog.sink = nil
    }
}
