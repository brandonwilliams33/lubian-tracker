import Foundation
import CoreGraphics
@main struct Tests {
 static func main() throws {
  let t = Tracker()
  var shelf = DeckLibrary()
  let a = DeckCard(id: "TEST_A", name: "A", count: 2, cost: 1)
  let b = DeckCard(id: "TEST_B", name: "B", count: 1, cost: 2)
  let c = DeckCard(id: "TEST_C", name: "C", count: 1, cost: 3)
  let savedA = shelf.save(SavedDeck(name: "第一副", cards: [a, b], source: "test"))
  let savedB = shelf.save(SavedDeck(name: "第二副", cards: [a, c], source: "test"))
  assert(savedA != savedB && shelf.decks.count == 2)
  assert(shelf.save(SavedDeck(name: "重复", cards: [b, a], source: "test")) == savedA)
  assert(shelf.decks.count == 2, "reordered duplicate must not create another deck")
  let restored = try JSONDecoder().decode(DeckLibrary.self, from: JSONEncoder().encode(shelf))
  assert(restored.selected == savedA && restored.decks.count == 2)
  let evidence = Tracker()
  evidence.entities[10] = Entity(id: 10, card: "CORE_TEST_A", controller: 1, zone: "HAND", originalOwner: 1, originalCard: "CORE_TEST_A")
  evidence.entities[11] = Entity(id: 11, card: "TEST_A", controller: 1, zone: "HAND", originalOwner: 1, originalCard: "TEST_A")
  assert(shelf.candidates(for: evidence, player: 1).count == 2, "similar decks remain ambiguous")
  assert(evidence.removed(1, "TEST_A") == 2, "core and original editions share remaining-card counts")
  evidence.entities[12] = Entity(id: 12, card: "TEST_C", controller: 1, zone: "HAND", originalOwner: 0)
  assert(shelf.candidates(for: evidence, player: 1).count == 2, "generated cards are not deck evidence")
  evidence.entities[13] = Entity(id: 13, card: "TEST_B", controller: 1, zone: "HAND", originalOwner: 1, originalCard: "TEST_B")
  assert(shelf.candidates(for: evidence, player: 1).map { $0.id } == [savedA])
  evidence.entities[14] = Entity(id: 14, card: "TEST_C", controller: 1, zone: "HAND", originalOwner: 1, originalCard: "TEST_C")
  assert(shelf.candidates(for: evidence, player: 1).isEmpty, "unsaved or changed deck must not be forced to match")
  let top = Tracker(); top.dredgeCards = ["TEST_DREDGE"]
  func topEvent(_ body: String) { top.ingest("D 00:00:00 GameState.DebugPrintPower() - " + body) }
  topEvent("CREATE_GAME")
  topEvent("FULL_ENTITY - Creating ID=10 CardID=TEST_A"); topEvent("tag=CONTROLLER value=1"); topEvent("tag=ZONE value=DECK")
  topEvent("TAG_CHANGE Entity=10 tag=ZONE_POSITION value=1")
  assert(top.knownTop(1).isEmpty, "ordinary zone position is not evidence of deck order")
  topEvent("FULL_ENTITY - Creating ID=20 CardID=TEST_DREDGE"); topEvent("tag=CONTROLLER value=1")
  topEvent("BLOCK_START BlockType=POWER Entity=20 EffectCardId= EffectIndex=0")
  topEvent("FULL_ENTITY - Creating ID=30 CardID=TEST_A"); topEvent("tag=CONTROLLER value=1"); topEvent("tag=ZONE value=SETASIDE")
  topEvent("tag=CREATOR value=20"); topEvent("tag=COPIED_FROM_ENTITY_ID value=10"); topEvent("tag=LINKED_ENTITY value=10")
  assert(top.knownTop(1).isEmpty, "offered dredge cards are still on the bottom")
  topEvent("SHOW_ENTITY - Updating Entity=10 CardID=TEST_A")
  assert(top.knownTop(1).map { $0.id } == [10])
  assert(top.snapshot().knownTop(1).count == 1)
  topEvent("BLOCK_END")
  topEvent("TAG_CHANGE Entity=10 tag=ZONE value=HAND")
  assert(top.knownTop(1).isEmpty, "drawing removes the top marker")
  topEvent("TAG_CHANGE Entity=10 tag=ZONE value=DECK"); top.markTop(10)
  topEvent("SHUFFLE_DECK PlayerID=1")
  assert(top.knownTop(1).isEmpty, "shuffle invalidates known order")
  top.markTop(10); topEvent("CREATE_GAME")
  assert(top.knownTop(1).isEmpty && top.dredgeCandidates.isEmpty)
  print("PASS: multiple decks, persistence, duplicate imports, ambiguous/unique matching, generated cards, dredge top, draw/shuffle/new-game invalidation")
  func feed(_ s: String) { t.ingest("D 12:00:00 GameState.DebugPrintPower() - " + s) }
  feed("CREATE_GAME")
  feed("FULL_ENTITY - Creating ID=10 CardID=")
  feed("tag=ZONE value=DECK"); feed("tag=CONTROLLER value=1")
  assert(t.count(1, "DECK") == 1)
  feed("SHOW_ENTITY - Updating Entity=[entityName=UNKNOWN id=10 zone=DECK zonePos=0 cardId= player=1] CardID=CS2_029")
  feed("TAG_CHANGE Entity=[entityName=Fireball id=10 zone=DECK zonePos=0 cardId=CS2_029 player=1] tag=ZONE value=HAND")
  assert(t.count(1, "HAND") == 1 && t.removed(1, "CS2_029") == 1)
  feed("TAG_CHANGE Entity=10 tag=ZONE value=DECK")
  assert(t.removed(1, "CS2_029") == 0, "mulligan return")
  feed("TAG_CHANGE Entity=1 tag=TURN value=2")
  feed("FULL_ENTITY - Creating ID=11 CardID=CS2_029"); feed("tag=CONTROLLER value=1"); feed("tag=ZONE value=HAND")
  assert(t.removed(1, "CS2_029") == 0, "generated card must not consume original")
  let play = "BLOCK_START BlockType=PLAY Entity=[entityName=Fireball id=20 zone=HAND zonePos=1 cardId=CS2_029 player=2] EffectCardId= EffectIndex=0"
  feed(play); t.ingest("PowerTaskList.DebugPrintPower() - " + play)
  assert(t.plays.count == 1, "duplicate log streams")
  feed("TAG_CHANGE Entity=1 tag=STATE value=COMPLETE"); assert(!t.active)
  feed("CREATE_GAME"); assert(t.entities.isEmpty && t.plays.isEmpty && t.turn == 0 && t.active)
  feed("FULL_ENTITY - Creating ID=42 CardID=CS2_029"); feed("tag=CONTROLLER value=2"); feed("tag=ZONE value=2")
  assert(t.count(2, "DECK") == 1)
  feed("TAG_CHANGE Entity=unknown tag=ZONE value=HAND")
  assert(t.count(2, "DECK") == 1)
  let delayed = Tracker()
  func event(_ body: String) { delayed.ingest("D 00:00:00 GameState.DebugPrintPower() - " + body) }
  event("CREATE_GAME")
  for id in [10, 11] {
    event("FULL_ENTITY - Creating ID=\(id) CardID=")
    event("tag=ZONE value=DECK"); event("tag=CONTROLLER value=2")
    event("TAG_CHANGE Entity=\(id) tag=ZONE value=HAND")
    event("SHOW_ENTITY - Updating Entity=\(id) CardID=TEST_\(id)")
  }
  assert(delayed.localPlayer == 2)
  event("FULL_ENTITY - Creating ID=20 CardID=")
  event("tag=ZONE value=HAND"); event("tag=CONTROLLER value=1")
  event("BLOCK_START BlockType=PLAY Entity=[entityName=UNKNOWN id=20 zone=HAND cardId= player=1] EffectCardId= EffectIndex=0")
  assert(delayed.plays.isEmpty)
  event("SHOW_ENTITY - Updating Entity=20 CardID=TEST_ENEMY")
  assert(delayed.plays.count == 1 && delayed.plays[0].card == "TEST_ENEMY" && delayed.plays[0].player == 1)
  assert(delayed.localPlayer == 2)
  event("CHANGE_ENTITY - Updating Entity=20 CardID=TEST_TRANSFORM")
  assert(delayed.plays[0].card == "TEST_ENEMY")
  event("FULL_ENTITY - Creating ID=2 CardID=")
  event("tag=CONTROLLER value=2")
  event("tag=CARDTYPE value=PLAYER")
  event("BLOCK_START BlockType=FATIGUE Entity=[entityName=Player id=2 zone=PLAY cardId= player=2] EffectCardId= EffectIndex=0")
  assert(delayed.fatigue(2) == 1 && delayed.nextFatigueDamage(2) == 2)
  event("BLOCK_START BlockType=FATIGUE Entity=2 EffectCardId= EffectIndex=0")
  assert(delayed.fatigue(2) == 2 && delayed.nextFatigueDamage(2) == 3)
  let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: temp) }
  let root = temp.appendingPathComponent("Logs")
  let session1 = root.appendingPathComponent("Hearthstone_2026_01_01_00_00_00")
  try FileManager.default.createDirectory(at: session1, withIntermediateDirectories: true)
  let log = session1.appendingPathComponent("Power.log")
  let prefix = "D 00:00:00 GameState.DebugPrintPower() - "
  let initial = ["CREATE_GAME", "FULL_ENTITY - Creating ID=10 CardID=TEST_1", "tag=CONTROLLER value=1", "tag=ZONE value=DECK"].map { prefix + $0 }.joined(separator: "\n") + "\n"
  try Data(initial.utf8).write(to: log)
  let reader = LogReader()
  var update = reader.read(root: log, limit: 13)
  while update.bytes < update.total { update = reader.read(root: log, limit: 13) }
  assert(update.tracker.count(1, "DECK") == 1)
  let handle = try FileHandle(forWritingTo: log); try handle.seekToEnd()
  try handle.write(contentsOf: Data((prefix + "TAG_CHANGE Entity=10 tag=ZONE value=HA").utf8))
  update = reader.read(root: log); assert(update.tracker.count(1, "DECK") == 1)
  try handle.write(contentsOf: Data("ND\n".utf8)); try handle.close()
  update = reader.read(root: log); assert(update.tracker.count(1, "HAND") == 1)
  let session2 = root.appendingPathComponent("Hearthstone_2026_01_02_00_00_00")
  try FileManager.default.createDirectory(at: session2, withIntermediateDirectories: true)
  update = reader.read(root: log)
  assert(update.file == nil && update.tracker.entities.isEmpty, "do not show an old session as live")
  let next = session2.appendingPathComponent("Power.log")
  try Data(initial.utf8).write(to: next)
  update = reader.read(root: log); assert(update.file?.standardizedFileURL.path == next.standardizedFileURL.path && update.tracker.count(1, "DECK") == 1)
  try Data((prefix + "CREATE_GAME\n").utf8).write(to: next)
  update = reader.read(root: log); assert(update.tracker.entities.isEmpty)
  print("PASS: delayed opponent identity, local player inference, split lines, small chunk reads, session rotation, truncation")
  for size in [CGSize(width: 1280, height: 720), CGSize(width: 1440, height: 900), CGSize(width: 2560, height: 1440)] {
    for factor in [0.8, 1.0, 1.35] {
      let area = CGRect(origin: CGPoint(x: -1440, y: 200), size: size)
      let panels = OverlayLayout.frames(area: area, scale: factor)
      assert(panels.allSatisfy { area.contains($0) })
      assert(!panels[0].intersects(panels[1]))
      assert(panels[0].width == panels[1].width && panels[0].height == panels[1].height)
    }
  }
  let visible = CGRect(x: 0, y: 0, width: 1280, height: 800)
  let recovered = OverlayLayout.clamped(CGRect(x: -2000, y: 1600, width: 230, height: 600), to: visible)
  assert(visible.contains(recovered))
  print("PASS: overlay sizing on 720p/900p/1440p, scale range, negative monitor coordinates, offscreen recovery")
  // Interoperability vectors: HearthSim/python-hearthstone tests/test_deckstrings.py.
  let normal = "AAECAQcABAECAwQAAA=="
  let decoded = try DeckCode(normal)
  assert(decoded.entries == (1...4).map { DeckEntry(dbfId: $0, count: 2, owner: nil) })
  let wrapped = "### 我的牌组\r\n# 职业：战士\r\n# 2x 卡牌\r\n" + normal + "\r\n# 将此套牌复制到剪贴板"
  let extracted = try DeckCode.extract(wrapped)
  assert(extracted == normal)
  let unpadded = try DeckCode(String(normal.dropLast(2)))
  assert(unpadded.entries == decoded.entries)
  let triples = try DeckCode("AAEBAQcAAAQBAwIDAwMEAwA=")
  assert(triples.entries.allSatisfy { $0.count == 3 } && triples.entries.count == 4)
  let side = try DeckCode("AAEBAZCaBgjlsASotgSX7wTvkQXipAX9xAXPxgXGxwUQvp8EobYElrcE+dsEuNwEutwE9vAEhoMFopkF4KQFlMQFu8QFu8cFuJ4Gz54G0Z4GAAED8J8E/cQFuNkE/cQF/+EE/cQFAAA=")
  assert(side.entries.filter { $0.owner == nil }.reduce(0) { $0 + $1.count } == 40)
  assert(Set(side.entries.filter { $0.owner != nil }.map { $0.dbfId }) == Set([76984, 78079, 69616]))
  assert(side.entries.filter { $0.owner != nil }.allSatisfy { $0.owner == 90749 && $0.count == 1 })
  let database = Dictionary((1...4).map { (value: Int) in ("TEST_\(value)", Card(id: "TEST_\(value)", name: "测试\(value)", cost: value, dbfId: value)) }, uniquingKeysWith: { a, _ in a })
  let resolved = try decoded.resolve(database)
  assert(resolved.count == 4 && resolved[0].id == "TEST_1")
  func rejects(_ action: () throws -> Void) {
    do { try action(); assertionFailure("Expected rejection") } catch { }
  }
  rejects { _ = try decoded.resolve([:]) }
  rejects { _ = try DeckCode.extract(normal + "\n" + normal) }
  rejects { _ = try DeckCode("AAE=") }
  rejects { _ = try DeckCode("not-a-code") }
  let validData = Data(base64Encoded: normal)!
  for end in 0..<(validData.count - 1) { rejects { _ = try DeckCode(validData.prefix(end).base64EncodedString()) } }
  rejects { _ = try DeckCode((validData + Data([99])).base64EncodedString()) }
  let oldSaved = Data("[{\"id\":\"CS2_029\",\"name\":\"火球术\",\"count\":2,\"cost\":4}]".utf8)
  let oldDeck = try JSONDecoder().decode([DeckCard].self, from: oldSaved)
  assert(oldDeck[0].sideboardOwner == nil)
  print("PASS: deck code vectors, pasted export, padding, 40-card sideboard, card mapping, missing database, malformed/truncated codes, legacy saved deck")
  print("PASS: draw, mulligan, generated cards, stream deduplication, new game, numeric zones, malformed entity")
 }
}
