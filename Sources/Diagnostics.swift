import Foundation

/// 诊断导出使用的脱敏工具。只依赖 Foundation，便于在测试中单独编译。
enum Redaction {
    static let pathPlaceholder = "<redacted-path>"
    static let tagPlaceholder = "<battle-tag>"
    static let namePlaceholder = "<player>"
    static let idPlaceholder = "<redacted-id>"

    /// 路径只保留最后一段；如果最后一段本身就是用户目录名（或为空），使用占位符。
    static func path(_ raw: String?, userName: String = NSUserName()) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let parts = raw.split(separator: "/").map(String.init)
        guard let last = parts.last, last != "~", last != ".", last != ".." else { return pathPlaceholder }
        if !userName.isEmpty, last.caseInsensitiveCompare(userName) == .orderedSame { return pathPlaceholder }
        if parts.count >= 2, ["Users", "home"].contains(parts[parts.count - 2]) { return pathPlaceholder }
        return text(last)
    }

    /// 自由文本脱敏：绝对路径、战网标签和已知玩家名都会被占位符替换。
    static func text(_ input: String, names: [String] = []) -> String {
        var s = input
        s = replace("(?<![\\w<])(?:~|(?:/[^\\s\"'<>/]+)+/?)", in: s, with: pathPlaceholder)
        s = replace("[\\p{L}\\p{N}_]{2,}#\\d{3,6}", in: s, with: tagPlaceholder)
        var known = Set<String>()
        for name in names {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            known.insert(trimmed)
            if let hash = trimmed.firstIndex(of: "#") { known.insert(String(trimmed[..<hash])) }
        }
        for name in known.filter({ $0.count >= 2 }).sorted(by: { $0.count > $1.count }) {
            s = s.replacingOccurrences(of: name, with: namePlaceholder, options: [.caseInsensitive, .literal])
        }
        return s
    }

    /// 卡牌 ID 等标识只允许安全字符；其他内容（例如混入日志的名字）一律替换。
    static func identifier(_ raw: String) -> String {
        raw.range(of: "^[A-Za-z0-9_.\\-]{1,64}$", options: .regularExpression) != nil ? raw : idPlaceholder
    }

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        return re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: NSRegularExpression.escapedTemplate(for: template))
    }
}

struct DiagnosticInput {
    var tracker: Tracker
    var library: DeckLibrary
    var player: Int
    var autoDeck = true
    var autoPlayer = true
    var demo = false
    var logRoot: URL? = nil
    var logFile: URL? = nil
    var bytesRead: UInt64 = 0
    var logSize: UInt64 = 0
    var lastModified: Date? = nil
    var status = ""
    /// 默认关闭。开启后仅附带已脱敏的当前选中套牌名。
    var includeNames = false
    var now = Date()
    var appVersion: String? = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    var appBuild: String? = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
}

struct DiagnosticReport: Codable {
    struct App: Codable { var version: String; var build: String }
    struct Runtime: Codable { var os: String; var osVersion: String; var architecture: String; var cpuCount: Int; var language: String }
    struct TrackerSummary: Codable {
        var turn: Int
        var gameActive: Bool
        var demo: Bool
        var stream: String
        var processedLines: Int
        var entityCount: Int
        var localPlayer: Int?
        var fatigue: [String: Int]
        var knownTopCardIDs: [String: [String]]
        var playCountsByCardID: [String: Int]
        var zoneCounts: [String: [String: Int]]
    }
    struct DeckMatching: Codable {
        var savedDeckCount: Int
        var candidateCount: Int
        var selectedDeckID: String?
        var selectedDeckName: String?
        var autoDeck: Bool
        var autoPlayer: Bool
        var player: Int
    }
    struct LogReaderSession: Codable {
        var rootName: String?
        var fileName: String?
        var bytesRead: UInt64
        var fileSize: UInt64
        var lastModifiedAgeSeconds: Int?
        var status: String
    }
    struct Privacy: Codable { var redacted: Bool; var includesDeckNames: Bool; var excluded: [String] }

    var schemaVersion = 1
    var generatedAt: String
    var app: App
    var runtime: Runtime
    var tracker: TrackerSummary
    var deckMatching: DeckMatching
    var logReader: LogReaderSession
    var privacy: Privacy

    static func make(_ input: DiagnosticInput) -> DiagnosticReport {
        let t = input.tracker
        let names = Array(t.names.values)
        func id(_ raw: String) -> String { Redaction.identifier(raw) }
        func key(_ player: Int) -> String { String(player) }

        var fatigue: [String: Int] = [:]
        for (p, n) in t.fatigueCounts { fatigue[key(p)] = n }
        var top: [String: [String]] = [:]
        for p in t.topCards.keys { top[key(p)] = t.knownTop(p).map { id($0.card) } }
        var plays: [String: Int] = [:]
        for play in t.plays { plays[id(play.card), default: 0] += 1 }
        var zones: [String: [String: Int]] = [:]
        for e in t.entities.values where e.controller > 0 && !e.zone.isEmpty { zones[key(e.controller), default: [:]][id(e.zone), default: 0] += 1 }

        let candidates = input.library.candidates(for: t, player: input.player)
        let selected = input.library.decks.first { $0.id == input.library.selected }
        let age = input.lastModified.map { max(0, Int(input.now.timeIntervalSince($0))) }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let arch = "arm64"
        #elseif arch(x86_64)
        let arch = "x86_64"
        #else
        let arch = "unknown"
        #endif
        #if os(macOS)
        let osName = "macOS"
        #elseif os(Linux)
        let osName = "Linux"
        #else
        let osName = "other"
        #endif

        return DiagnosticReport(
            generatedAt: ISO8601DateFormatter().string(from: input.now),
            app: App(version: input.appVersion ?? "unknown", build: input.appBuild ?? "unknown"),
            runtime: Runtime(os: osName, osVersion: "\(os.majorVersion).\(os.minorVersion)", architecture: arch,
                             cpuCount: ProcessInfo.processInfo.processorCount, language: Locale.preferredLanguages.first.map { Redaction.text($0) } ?? "unknown"),
            tracker: TrackerSummary(turn: t.turn, gameActive: t.active, demo: input.demo, stream: id(t.source ?? "none"),
                                    processedLines: t.processedLines, entityCount: t.entities.count, localPlayer: t.localPlayer,
                                    fatigue: fatigue, knownTopCardIDs: top, playCountsByCardID: plays, zoneCounts: zones),
            deckMatching: DeckMatching(savedDeckCount: input.library.decks.count, candidateCount: candidates.count,
                                       selectedDeckID: selected.map { id($0.id) },
                                       selectedDeckName: input.includeNames ? selected.map { Redaction.text($0.name, names: names) } : nil,
                                       autoDeck: input.autoDeck, autoPlayer: input.autoPlayer, player: input.player),
            logReader: LogReaderSession(rootName: Redaction.path(input.logRoot?.path), fileName: Redaction.path(input.logFile?.path),
                                        bytesRead: input.bytesRead, fileSize: input.logSize, lastModifiedAgeSeconds: age,
                                        status: Redaction.text(input.status, names: names)),
            privacy: Privacy(redacted: true, includesDeckNames: input.includeNames,
                             excluded: ["Power.log 内容", "完整路径", "战网昵称与标签", "剪贴板文本", "套牌名称（默认）"]))
    }

    func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
