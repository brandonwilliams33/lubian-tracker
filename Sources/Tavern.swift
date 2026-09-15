import SwiftUI

enum Tavern {
    static let gold = Color(red: 0.84, green: 0.65, blue: 0.34)
    static let cream = Color(red: 0.96, green: 0.89, blue: 0.74)
    static let wood = Color(red: 0.22, green: 0.145, blue: 0.09)
    static let background = LinearGradient(colors: [Color(red: 0.19, green: 0.13, blue: 0.10), Color(red: 0.075, green: 0.085, blue: 0.105), Color(red: 0.12, green: 0.085, blue: 0.07)], startPoint: .topLeading, endPoint: .bottomTrailing)
}

struct DeckShelf: View {
    @ObservedObject var m: Model
    @State private var renaming = false
    @State private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("套牌收藏", systemImage: "books.vertical.fill").font(.headline).foregroundStyle(Tavern.gold)
                Text("\(m.library.decks.count) 副").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle("开局自动识别", isOn: $m.autoDeck).onChange(of: m.autoDeck) { enabled in
                    if enabled { m.identifyDeck() } else { m.selectDeck(m.library.selected) }
                }
                Toggle("收藏自动收录", isOn: $m.autoCapture)
            }.font(.callout)
            HStack {
                Picker("当前套牌", selection: Binding(get: { m.library.selected }, set: { m.selectDeck($0); m.autoDeck = false })) {
                    if m.library.decks.isEmpty { Text("导入你的第一副套牌").tag("") }
                    ForEach(m.library.decks) { deck in Text("\(deck.name) · \(deck.total) 张").tag(deck.id) }
                }
                Button("重命名") { name = m.selectedDeck?.name ?? ""; renaming = true }.disabled(m.selectedDeck == nil)
            }
            HStack {
                Circle().fill(m.deckStatus.hasPrefix("自动识别") ? .green : Tavern.gold).frame(width: 6, height: 6)
                Text(m.deckStatus).font(.caption)
                Spacer()
                Text(m.autoCapture ? m.captureStatus : "开启自动收录后，在炉石收藏中复制套牌即可保存").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }.padding(14).background(Tavern.wood.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tavern.gold.opacity(0.3)))
            .sheet(isPresented: $renaming) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("为套牌命名").font(.title2.bold())
                    TextField("套牌名称", text: $name).textFieldStyle(.roundedBorder)
                    HStack { Button("取消") { renaming = false }; Spacer(); Button("保存") { m.renameDeck(name); renaming = false }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty) }
                }.padding(24).frame(width: 360)
            }
    }
}

struct TopDeckView: View {
    @ObservedObject var m: Model
    @State private var preview: OverlayCard?
    private var top: [OverlayCard] {
        if m.demo { return [OverlayCard(id: "CS2_029", name: "火球术", cost: 4, count: 1)] }
        return m.tracker.knownTop(m.player).map { OverlayCard(id: $0.card, name: m.name($0.card), cost: m.cards[$0.card]?.cost, count: 1) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack { Image(systemName: "arrow.up.to.line"); Text("已知牌库顶").fontWeight(.semibold); Spacer() }.foregroundStyle(Tavern.gold)
            if let card = top.first {
                Button { preview = card } label: {
                    HStack { Text(card.cost.map(String.init) ?? "?").foregroundStyle(.cyan); Text(card.name).lineLimit(1); Spacer(); Image(systemName: "eye") }
                }.buttonStyle(.plain).onHover { inside in preview = inside ? card : nil }
            } else { Text("未知 · 等待探底揭示").foregroundStyle(.secondary) }
        }.font(.system(size: 11)).padding(9).background(Tavern.gold.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Tavern.gold.opacity(0.22)))
            .popover(item: $preview) { card in CardPreview(card: m.cards[card.id], fallback: card) }
    }
}
