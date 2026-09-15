// Pass a local Power.log file. This test never uploads or prints player details.
import Foundation
@main struct ReplayTests {
 static func main() throws {
  guard CommandLine.arguments.count >= 2 else { fatalError("Pass Power.log path") }
  let text = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
  let tracker = Tracker(); var draws = 0; var drawsWithIdentity = 0; var maxPlays = 0
  for line in text.components(separatedBy: .newlines) {
   let before = tracker.entities
   tracker.ingest(line)
   if line.contains("GameState.DebugPrintPower()") && line.contains("TAG_CHANGE") && line.contains("tag=ZONE value=HAND"),
      let m = match("Entity=(.+) tag=ZONE", line), let id = Int(m[1]) ?? match("\\bid=(\\d+)", m[1]).flatMap({ Int($0[1]) }),
      let old = before[id], let new = tracker.entities[id], old.zone == "DECK" {
       assert(new.zone == "HAND")
       draws += 1
       if !new.originalCard.isEmpty {
        assert(tracker.removed(new.originalOwner, new.originalCard) > 0)
        drawsWithIdentity += 1
       }
   }
   if line.contains("GameState.DebugPrintPower()"), line.contains("SHOW_ENTITY"),
      let m = match("Entity=(\\d+)", line), let id = Int(m[1]), let e = tracker.entities[id],
      e.originalOwner > 0, !e.originalCard.isEmpty, before[id]?.originalCard.isEmpty == true,
      e.zone != "DECK" {
       assert(tracker.removed(e.originalOwner, e.originalCard) > 0)
       drawsWithIdentity += 1
   }
   maxPlays = max(maxPlays, tracker.plays.count)
  }
  assert(draws > 0 && maxPlays > 0)
  assert(tracker.localPlayer != nil)
  if CommandLine.arguments.count > 2 {
    let deck = try JSONDecoder().decode([DeckCard].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
    let p = tracker.localPlayer!
    let removed = deck.filter { $0.sideboardOwner == nil }.reduce(0) { $0 + min($1.count, tracker.removed(p, $1.id)) }
    print("Imported deck reductions:", removed)
    var shelf = DeckLibrary()
    _ = shelf.save(SavedDeck(name: "Local deck", cards: deck, source: "test"))
    let observations = tracker.entities.values.filter { $0.originalOwner == p && !$0.originalCard.isEmpty }.count
    print("Original card evidence:", observations, "Matching saved decks:", shelf.candidates(for: tracker, player: p).count)
  }
  print("PASS real-log replay: draws=\(draws), identified-draws=\(drawsWithIdentity), max-known-plays=\(maxPlays), local-player=\(tracker.localPlayer!)")
 }
}
