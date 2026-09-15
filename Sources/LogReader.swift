import Foundation

struct LogUpdate {
    var tracker: Tracker
    var file: URL?
    var bytes: UInt64
    var total: UInt64
    var modified: Date?
    var message: String
}
final class LogReader {
    var dredgeCards = Set<String>()
    private var tracker = Tracker()
    private var file: URL?
    private var identity: UInt64 = 0
    private var offset: UInt64 = 0
    private var pending = Data()
    private var selectedRoot: URL?
    static func normalizedRoot(_ url: URL) -> URL {
        var candidate = url
        // A selected session or Power.log should continue following later sessions.
        for _ in 0..<3 {
            if candidate.lastPathComponent == "Logs" { return candidate }
            let parent = candidate.deletingLastPathComponent()
            if parent == candidate { break }; candidate = parent
        }
        return url
    }
    static func newestLog(in root: URL) -> URL? {
        let fm = FileManager.default
        if root.lastPathComponent == "Power.log" { return fm.fileExists(atPath: root.path) ? root : nil }
        let children = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let sessions = children.filter { $0.lastPathComponent.hasPrefix("Hearthstone_") && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        if let latestSession = sessions.max(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let log = latestSession.appendingPathComponent("Power.log")
            // Do not replay an older finished match while a new Hearthstone
            // session is starting. Power.log appears once game-state logging begins.
            return fm.fileExists(atPath: log.path) ? log : nil
        }
        let direct = root.appendingPathComponent("Power.log")
        return fm.fileExists(atPath: direct.path) ? direct : nil
    }
    func reset() { tracker.reset(); file = nil; identity = 0; offset = 0; pending = Data() }
    func read(root: URL, limit: Int = 2*1024*1024) -> LogUpdate {
        tracker.dredgeCards = dredgeCards
        let root = Self.normalizedRoot(root)
        if selectedRoot != root { reset(); selectedRoot = root }
        guard let url = Self.newestLog(in: root) else {
            reset()
            return LogUpdate(tracker: tracker.snapshot(), file: nil, bytes: 0, total: 0, modified: nil, message: "等待当前游戏生成 Power.log；开启日志后需重启炉石并进入对局")
        }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            let modified = attributes[.modificationDate] as? Date
            if file != url || size < offset || inode != identity { reset(); file = url; identity = inode }
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: limit) ?? Data()
            offset += UInt64(data.count); pending.append(data)
            if let end = pending.lastIndex(of: 10) {
                let complete = pending[...end]
                for line in complete.split(separator: 10) { tracker.ingest(String(decoding: line, as: UTF8.self)) }
                pending = Data(pending[pending.index(after: end)...])
            }
            if pending.count > 1024*1024 { pending.removeAll() }
            let message = offset < size ? "正在恢复对局进度" : tracker.processedLines == 0 ? "已找到日志，等待对局数据" : tracker.active ? "实时记牌已连接" : "已连接 · 等待下一局"
            return LogUpdate(tracker: tracker.snapshot(), file: url, bytes: offset, total: size, modified: modified, message: message)
        } catch {
            return LogUpdate(tracker: tracker.snapshot(), file: file, bytes: offset, total: offset, modified: nil, message: "日志读取失败：\(error.localizedDescription)")
        }
    }
}
