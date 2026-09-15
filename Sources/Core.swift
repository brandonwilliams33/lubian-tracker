import Foundation
import CoreGraphics

func match(_ pattern: String, _ text: String) -> [String]? {
    guard let re = try? NSRegularExpression(pattern: pattern), let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
    return (0..<m.numberOfRanges).map { Range(m.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
}
struct Entity {
    var id: Int
    var card = ""
    var controller = 0
    var zone = ""
    var type = ""
    var originalOwner = 0
    var originalCard = ""
    var linked = 0
    var copiedFrom = 0
    var creator = 0
}
struct Play { var player: Int; var card: String }
struct PlayEvent { var entity: Int; var player: Int; var card: String }
final class Tracker {
    var entities: [Int: Entity] = [:]
    var playEvents: [PlayEvent] = []
    var plays: [Play] { playEvents.compactMap { event in
        let card = event.card.isEmpty ? (entities[event.entity]?.card ?? "") : event.card
        return card.isEmpty ? nil : Play(player: event.player, card: card)
    } }
    var processedLines = 0
    var localPlayer: Int?
    var handEvidence = Set<Int>()
    var fatigueCounts: [Int: Int] = [:]
    var gameID = UUID()
    var topCards: [Int: [Int]] = [:]
    var dredgeCards = Set<String>()
    var blocks: [String] = []
    var dredgeCandidates = Set<Int>()
    var current: Int?
    var turn = 0
    var active = false
    var source: String?
    var names: [Int: String] = [:]
    func reset() { entities = [:]; playEvents = []; current = nil; turn = 0; active = false; names = [:]; source = nil; processedLines = 0; localPlayer = nil; handEvidence = []; fatigueCounts = [:]; gameID = UUID(); topCards = [:]; blocks = []; dredgeCandidates = [] }
    func ingest(_ line: String) {
        let stream = line.contains("GameState.DebugPrintPower") ? "GameState" : line.contains("PowerTaskList.DebugPrintPower") ? "PowerTaskList" : ""
        guard !stream.isEmpty else { return }
        if source == nil { source = stream }
        guard source == stream else { return }
        if line.contains("CREATE_GAME") { reset(); source = stream; active = true; return }
        processedLines += 1
        if let shuffle = match("SHUFFLE_DECK PlayerID=(\\d+)", line), let p = Int(shuffle[1]) {
            topCards[p] = []; dredgeCandidates = dredgeCandidates.filter { entities[$0]?.controller != p }; return
        }
        if line.contains("BLOCK_END") { if !blocks.isEmpty { blocks.removeLast() }; return }
        if line.contains("BLOCK_START") {
            let card = match("cardId=([^\\s\\]]*)", line)?[1]
                ?? match("Entity=(\\d+)", line).flatMap { Int($0[1]) }.flatMap { entities[$0]?.card } ?? ""
            blocks.append(card)
        }
        if let m = match("Player EntityID=(\\d+) PlayerID=(\\d+)", line), let id = Int(m[1]) { current = id; entities[id] = Entity(id: id); return }
        if let m = match("GameEntity EntityID=(\\d+)", line), let id = Int(m[1]) { current = id; entities[id] = Entity(id: id); return }
        if line.contains("FULL_ENTITY") || line.contains("SHOW_ENTITY") || line.contains("CHANGE_ENTITY") {
            guard let m = match("(?:Creating ID=|\\bid=|Entity=)(\\d+)", line), let id = Int(m[1]) else { current = nil; return }
            current = id
            var e = entities[id] ?? Entity(id: id)
            if let c = match("CardID=([^\\s]*)", line), !c[1].isEmpty { e.card = c[1] }
            if let p = match("player=(\\d+)", line) { e.controller = Int(p[1]) ?? 0 }
            if let z = match("zone=([A-Z]+)", line) { e.zone = z[1] }
            if e.originalOwner != 0 && e.originalCard.isEmpty { e.originalCard = e.card }
            entities[id] = e
            if line.contains("SHOW_ENTITY"), e.zone == "DECK", dredgeCandidates.contains(id), blocks.contains(where: { dredgeCards.contains($0) }) {
                markTop(id); dredgeCandidates.remove(id)
            }
            identifyLocalPlayer(e)
            if !e.card.isEmpty {
                for index in playEvents.indices where playEvents[index].entity == id && playEvents[index].card.isEmpty { playEvents[index].card = e.card }
            }
            return
        }
        if line.contains("TAG_CHANGE") {
            current = nil
            guard let m = match("TAG_CHANGE Entity=(.+) tag=(\\w+) value=(\\S+)", line) else { return }
            let id = Int(m[1]) ?? match("\\bid=(\\d+)", m[1]).flatMap { Int($0[1]) }
            if let id { tag(id, m[2], m[3]) }
            return
        }
        if let m = match(" - \\s*tag=(\\w+) value=(\\S+)", line), let id = current { tag(id, m[1], m[2]); return }
        current = nil
        if line.contains("BLOCK_START BlockType=FATIGUE"), let m = match("Entity=(.+?) EffectCardId=", line) {
            let player = match("player=(\\d+)", m[1]).flatMap { Int($0[1]) }
                ?? (Int(m[1]).flatMap { entities[$0]?.controller })
                ?? match("\\bid=(\\d+)", m[1]).flatMap { Int($0[1]) }.flatMap { entities[$0]?.controller }
            if let player, player > 0 { fatigueCounts[player, default: 0] += 1 }
        }
        if line.contains("BLOCK_START BlockType=PLAY"), let m = match("Entity=(.+?) EffectCardId=", line),
           let id = Int(m[1]) ?? match("\\bid=(\\d+)", m[1]).flatMap({ Int($0[1]) }) {
            let player = match("player=(\\d+)", m[1]).flatMap { Int($0[1]) } ?? entities[id]?.controller ?? 0
            let card = match("cardId=([^\\s\\]]*)", m[1])?[1] ?? ""
            let e = entities[id]
            // Hero powers are PLAY blocks too; retain card plays from hand only.
            if e?.type != "HERO_POWER" && e?.type != "10" {
                playEvents.append(PlayEvent(entity: id, player: player, card: card.isEmpty ? (e?.card ?? "") : card))
            }
        }
    }
    func identifyLocalPlayer(_ e: Entity) {
        // Two distinct original hand cards revealed to one controller are evidence
        // of our perspective. Ambiguous/spectator streams retain manual selection.
        if playEvents.isEmpty && e.originalOwner > 0 && e.zone == "HAND" && !e.card.isEmpty && turn <= 1 {
            handEvidence.insert(e.id)
            let owners = Dictionary(grouping: handEvidence.compactMap { entities[$0]?.controller }, by: { $0 })
            if owners.count == 1, let (owner, evidence) = owners.first, evidence.count >= 2 { localPlayer = owner }
            else if owners.count > 1 { localPlayer = nil }
        }
    }
    func snapshot() -> Tracker {
        let t = Tracker(); t.entities = entities; t.playEvents = playEvents; t.current = current
        t.turn = turn; t.active = active; t.source = source; t.names = names
        t.processedLines = processedLines; t.localPlayer = localPlayer; t.handEvidence = handEvidence; t.fatigueCounts = fatigueCounts
        t.gameID = gameID; t.topCards = topCards; t.dredgeCards = dredgeCards; t.blocks = blocks; t.dredgeCandidates = dredgeCandidates
        return t
    }

    func tag(_ id: Int, _ key: String, _ value: String) {
        var e = entities[id] ?? Entity(id: id)
        switch key {
        case "CONTROLLER": e.controller = Int(value) ?? 0
        case "ZONE": e.zone = ["1":"PLAY", "2":"DECK", "3":"HAND", "4":"GRAVEYARD", "5":"REMOVEDFROMGAME", "6":"SETASIDE", "7":"SECRET"][value] ?? value
        case "CARDTYPE": e.type = value
        case "LINKED_ENTITY": e.linked = Int(value) ?? 0
        case "COPIED_FROM_ENTITY_ID": e.copiedFrom = Int(value) ?? 0
        case "CREATOR": e.creator = Int(value) ?? 0
        case "TURN": turn = Int(value) ?? 0
        case "FATIGUE": fatigueCounts[e.controller] = max(fatigueCounts[e.controller, default: 0], Int(value) ?? 0)
        case "STATE": if value == "COMPLETE" || value == "4" { active = false }
        default: break
        }
        if e.originalOwner == 0 && e.zone == "DECK" && e.controller > 0 && turn == 0 { e.originalOwner = e.controller; e.originalCard = e.card }
        entities[id] = e
        if e.linked > 0 && e.linked == e.copiedFrom && dredgeCards.contains(entities[e.creator]?.card ?? "") && entities[e.linked]?.zone == "DECK" {
            dredgeCandidates.insert(e.linked)
        }
        if key == "ZONE" && e.zone != "DECK" { for p in Array(topCards.keys) { topCards[p]?.removeAll { $0 == id } } }
        identifyLocalPlayer(e)
    }
    func markTop(_ id: Int) {
        guard let e = entities[id], e.zone == "DECK", !e.card.isEmpty else { return }
        topCards[e.controller, default: []].removeAll { $0 == id }
        topCards[e.controller, default: []].insert(id, at: 0)
    }
    func knownTop(_ player: Int) -> [Entity] { (topCards[player] ?? []).compactMap { entities[$0] }.filter { $0.zone == "DECK" && $0.controller == player && !$0.card.isEmpty } }
    func count(_ player: Int, _ zone: String) -> Int { entities.values.filter { $0.controller == player && $0.zone == zone }.count }
    func removed(_ player: Int, _ card: String) -> Int {
        entities.values.filter { $0.originalOwner == player && DeckLibrary.canonical($0.originalCard) == DeckLibrary.canonical(card) && !($0.zone == "DECK" && $0.controller == player) }.count
    }
    func fatigue(_ player: Int) -> Int { fatigueCounts[player, default: 0] }
    func nextFatigueDamage(_ player: Int) -> Int { fatigue(player) + 1 }
}
struct Card: Decodable {
    var id: String
    var name: String
    var cost: Int? = nil
    var dbfId: Int? = nil
    var text: String? = nil
    var flavor: String? = nil
    var type: String? = nil
    var rarity: String? = nil
    var cardClass: String? = nil
    var attack: Int? = nil
    var health: Int? = nil
}
struct DeckCard: Codable { var id: String; var name: String; var count: Int; var cost: Int; var sideboardOwner: String? = nil }

struct SavedDeck: Codable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var cards: [DeckCard]
    var source: String
    var updated = Date()
    var total: Int { cards.filter { $0.sideboardOwner == nil }.reduce(0) { $0 + $1.count } }
    var signature: String { cards.map { "\($0.sideboardOwner ?? "main"):\($0.id):\($0.count)" }.sorted().joined(separator: "|") }
}
struct DeckLibrary: Codable {
    var decks: [SavedDeck] = []
    var selected: String = ""
    mutating func save(_ item: SavedDeck) -> String {
        if let i = decks.firstIndex(where: { $0.signature == item.signature }) {
            decks[i].updated = Date(); selected = decks[i].id
        } else {
            var item = item
            let baseName = item.name
            var revision = 2
            while decks.contains(where: { $0.name == item.name }) { item.name = "\(baseName) · 版本 \(revision)"; revision += 1 }
            decks.append(item); selected = item.id
        }
        return selected
    }
    static func canonical(_ id: String) -> String {
        for prefix in ["CORE_", "VAN_", "LEGACY_"] where id.hasPrefix(prefix) { return String(id.dropFirst(prefix.count)) }
        return id
    }
    func candidates(for tracker: Tracker, player: Int) -> [SavedDeck] {
        let evidence = tracker.entities.values.filter { $0.originalOwner == player && !$0.originalCard.isEmpty }
        guard evidence.count >= 2 else { return [] }
        let observed = Dictionary(grouping: evidence, by: { Self.canonical($0.originalCard) }).mapValues { $0.count }
        return decks.filter { deck in
            let counts = Dictionary(grouping: deck.cards.filter { $0.sideboardOwner == nil }, by: { Self.canonical($0.id) }).mapValues { $0.reduce(0) { $0 + $1.count } }
            let originalCount = tracker.entities.values.filter { $0.originalOwner == player }.count
            return (originalCount < 30 || deck.total == originalCount) && observed.allSatisfy { counts[$0.key, default: 0] >= $0.value }
        }
    }
}

struct DeckImportError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
struct DeckEntry: Equatable { let dbfId: Int; let count: Int; let owner: Int? }
struct DeckCode {
    let entries: [DeckEntry]
    static func extract(_ text: String) throws -> String? {
        guard text.utf8.count <= 100_000 else { throw DeckImportError(message: "粘贴内容过长，请只粘贴一副牌组。") }
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        let codes = lines.filter { $0.hasPrefix("AA") && match("^[A-Za-z0-9+/]+={0,2}$", $0) != nil }
        if codes.count > 1 { throw DeckImportError(message: "检测到多段套牌代码，请一次导入一副牌组。") }
        return codes.first
    }
    init(_ code: String) throws {
        let invalid = DeckImportError(message: "套牌代码损坏、不完整或格式不受支持，请重新复制。")
        guard code.count <= 16_384 else { throw invalid }
        let padded = code + String(repeating: "=", count: (4 - code.count % 4) % 4)
        guard let data = Data(base64Encoded: padded), data.count > 5 else { throw invalid }
        let bytes = Array(data); var cursor = 0
        func number() throws -> Int {
            var value = 0
            for shift in stride(from: 0, through: 28, by: 7) {
                guard cursor < bytes.count else { throw invalid }
                let byte = bytes[cursor]; cursor += 1
                value |= Int(byte & 127) << shift
                if byte & 128 == 0 { return value }
            }
            throw invalid
        }
        guard try number() == 0, try number() == 1 else { throw invalid }
        let format = try number()
        guard (1...4).contains(format), try number() == 1, try number() > 0 else { throw invalid }
        var rows: [DeckEntry] = []
        func section(_ side: Bool) throws {
            var seen = Set<String>(); var total = 0
            for group in 1...3 {
                let length = try number(); guard length <= 100 else { throw invalid }
                for _ in 0..<length {
                    let id = try number(); let count = group == 3 ? try number() : group
                    let owner: Int? = side ? try number() : nil
                    guard id > 0, count > 0, count <= 60, owner == nil || owner! > 0 else { throw invalid }
                    guard seen.insert("\(owner ?? 0):\(id)").inserted else { throw invalid }
                    total += count; guard total <= (side ? 100 : 60) else { throw invalid }
                    rows.append(DeckEntry(dbfId: id, count: count, owner: owner))
                }
            }
            if !side && total == 0 { throw invalid }
        }
        try section(false)
        if cursor < bytes.count {
            let flag = try number(); guard flag <= 1 else { throw invalid }
            if flag == 1 { try section(true) }
        }
        guard cursor == bytes.count else { throw DeckImportError(message: "套牌代码包含尚未支持的扩展数据，未替换现有牌组。") }
        let main = Set(rows.filter { $0.owner == nil }.map { $0.dbfId })
        guard rows.allSatisfy({ $0.owner == nil || main.contains($0.owner!) }) else { throw invalid }
        entries = rows
    }
    func resolve(_ cards: [String: Card]) throws -> [DeckCard] {
        let index = Dictionary(cards.values.compactMap { c in c.dbfId.map { ($0, c) } }, uniquingKeysWith: { a, _ in a })
        let missing = entries.filter { index[$0.dbfId] == nil }.map { String($0.dbfId) }
        guard missing.isEmpty else { throw DeckImportError(message: "卡牌库缺少 \(missing.count) 条卡牌数据。请点击更新中文卡牌库，完成后再次保存；输入内容会保留。") }
        return entries.map { e in
            let c = index[e.dbfId]!
            return DeckCard(id: c.id, name: c.name, count: e.count, cost: c.cost ?? 0, sideboardOwner: e.owner.flatMap { index[$0]?.id })
        }
    }
}

struct OverlayLayout {
    static func frames(area: CGRect, scale: Double) -> [CGRect] {
        let margin: CGFloat = 12
        let factor = CGFloat(min(1.35, max(0.8, scale)))
        let width = min(max(190, area.width * 0.155) * factor, min(320, (area.width - 3 * margin) / 2))
        let height = min(area.height - 2 * margin, max(260, min(800, area.height * 0.82)))
        let y = area.minY + (area.height - height) / 2
        return [CGRect(x: area.minX + margin, y: y, width: width, height: height), CGRect(x: area.maxX - margin - width, y: y, width: width, height: height)]
    }
    static func clamped(_ rect: CGRect, to area: CGRect) -> CGRect {
        let width = min(rect.width, area.width), height = min(rect.height, area.height)
        return CGRect(x: min(max(rect.minX, area.minX), area.maxX - width), y: min(max(rect.minY, area.minY), area.maxY - height), width: width, height: height)
    }
}
