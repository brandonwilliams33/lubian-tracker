import Cocoa
import SwiftUI

extension Notification.Name {
    static let hideTrackerSettings = Notification.Name("app.lubian.tracker.hideSettings")
}

final class Model: ObservableObject {
    @Published var revision = 0
    @Published var status = "选择炉石 Logs 文件夹，开始监听"
    @Published var player = 1
    @Published var deck: [DeckCard] = []
    @Published var library = DeckLibrary()
    @Published var autoDeck = true
    @Published var autoCapture = UserDefaults.standard.bool(forKey: "autoCaptureDecks") { didSet { UserDefaults.standard.set(autoCapture, forKey: "autoCaptureDecks"); clipboardChange = NSPasteboard.general.changeCount } }
    @Published var deckStatus = "等待开局识别套牌"
    @Published var captureStatus = "收藏内复制套牌，可自动收录；无需返回粘贴"
    private var clipboardChange = NSPasteboard.general.changeCount
    private var matchedGame: UUID?
    private var captureTick = 0
    private var collectionFile: URL?
    private var collectionOffset: UInt64 = 0
    private var collectionPending = Data()
    private var libraryWritable = true
    var selectedDeck: SavedDeck? { library.decks.first { $0.id == library.selected } }
    @Published var demo = false
    @Published var path = ""
    @Published var databaseStatus = "卡牌库未下载，可用卡牌 ID 导入"
    var tracker = Tracker()
    @Published var connectionText = "未连接日志"
    @Published var lastLogUpdate: Date?
    @Published var autoPlayer = true
    private let reader = LogReader()
    private let logQueue = DispatchQueue(label: "app.lubian.log-reader", qos: .userInitiated)
    private var reading = false
    private var generation = 0
    var cards: [String: Card] = [:]
    private var dredgeIDs = Set<String>()
    var root: URL?
    var file: URL?
    var offset: UInt64 = 0
    var pending = Data()
    var fileIdentity: UInt64 = 0
    var timer: Timer?
    let storage = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LubianTracker")
    init() {
        try? FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: storage.appendingPathComponent("cards.json")) { loadCards(data) }
        if let data = try? Data(contentsOf: storage.appendingPathComponent("deck.json")), let d = try? JSONDecoder().decode([DeckCard].self, from: data) { deck = d }
        let libraryURL = storage.appendingPathComponent("decks.json")
        if FileManager.default.fileExists(atPath: libraryURL.path) {
            if let data = try? Data(contentsOf: libraryURL), let saved = try? JSONDecoder().decode(DeckLibrary.self, from: data) {
                library = saved; deck = selectedDeck?.cards ?? []
            } else { libraryWritable = false; captureStatus = "套牌收藏文件无法读取，已保留原文件；请先恢复文件" }
        } else if !deck.isEmpty {
            _ = library.save(SavedDeck(name: "原有套牌", cards: deck, source: "旧版迁移"))
            try? persistLibrary()
        }
        if let p = UserDefaults.standard.string(forKey: "logRoot") { root = URL(fileURLWithPath: p); path = p }
        if let root { self.root = LogReader.normalizedRoot(root); path = self.root!.path }
        discoverLogs()
        timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer!, forMode: .common)
        poll()
    }
    func loadCards(_ data: Data) {
        if let all = try? JSONDecoder().decode([Card].self, from: data) {
            cards = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            dredgeIDs = Set(all.filter { ($0.text ?? "").contains("探底") }.map { $0.id })
            databaseStatus = "已载入 \(cards.count) 张中文卡牌"
        }
    }
    func updateCards() {
        databaseStatus = "正在下载中文卡牌库…"
        URLSession.shared.dataTask(with: URL(string: "https://api.hearthstonejson.com/v1/latest/zhCN/cards.json")!) { data, response, error in
            DispatchQueue.main.async {
                guard let data, (response as? HTTPURLResponse)?.statusCode == 200, (try? JSONDecoder().decode([Card].self, from: data)) != nil else { self.databaseStatus = "下载失败，请检查网络后重试"; return }
                self.loadCards(data); try? data.write(to: self.storage.appendingPathComponent("cards.json"), options: .atomic)
            }
        }.resume()
    }
    func chooseLogs() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = true; p.message = "选择 Hearthstone/Logs 文件夹或 Power.log；将自动跟随最新对局"
        if p.runModal() == .OK, let u = p.url { root = LogReader.normalizedRoot(u); path = root!.path; UserDefaults.standard.set(path, forKey: "logRoot"); resumeLive() }
    }
    func configure() {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/Blizzard/Hearthstone/log.config")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if !old.isEmpty { try old.write(to: url.appendingPathExtension("backup-\(Int(Date().timeIntervalSince1970))"), atomically: true, encoding: .utf8) }
            var lines = old.components(separatedBy: .newlines)
            var start: Int?; var end = lines.count
            for (i, line) in lines.enumerated() {
                let s = line.trimmingCharacters(in: .whitespaces)
                if s.lowercased() == "[power]" { start = i }
                else if start != nil && s.hasPrefix("[") { end = i; break }
            }
            let section = ["[Power]", "LogLevel=1", "FilePrinting=true", "ConsolePrinting=false", "ScreenPrinting=false", "Verbose=true"]
            if let start { lines.replaceSubrange(start..<end, with: section) } else { lines += [""] + section }
            for name in ["Decks", "LoadingScreen"] {
                if let begin = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == "[\(name.lowercased())]" }) {
                    let finish = lines.indices.dropFirst(begin + 1).first { lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.count
                    lines.replaceSubrange(begin..<finish, with: ["[\(name)]", "LogLevel=1", "FilePrinting=true", "ConsolePrinting=false", "ScreenPrinting=false", "Verbose=true"])
                } else { lines += ["", "[\(name)]", "LogLevel=1", "FilePrinting=true", "ConsolePrinting=false", "ScreenPrinting=false", "Verbose=true"] }
            }
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            status = "日志已开启（原配置已备份）。请完全退出并重启炉石。"
        } catch { status = "配置失败：\(error.localizedDescription)" }
    }
    func discoverLogs() {
        if let root, FileManager.default.fileExists(atPath: root.path) { return }
        var candidates = [URL(fileURLWithPath: "/Applications/Hearthstone/Logs")]
        for app in NSWorkspace.shared.runningApplications where app.localizedName?.lowercased() == "hearthstone" || app.bundleIdentifier?.lowercased() == "com.blizzard.hearthstone" {
            if let url = app.bundleURL { candidates.insert(url.deletingLastPathComponent().appendingPathComponent("Logs"), at: 0) }
        }
        if let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            root = found; path = found.path; UserDefaults.standard.set(path, forKey: "logRoot")
        }
    }
    func resumeLive() {
        generation += 1; demo = false; tracker = Tracker(); file = nil
        connectionText = "正在连接当前对局…"
        status = "正在查找当前炉石日志…"
        logQueue.async { self.reader.reset() }
        discoverLogs(); poll()
    }
    func poll() {
        captureTick += 1
        if captureTick % 4 == 0 { captureDecks() }
        guard !demo, !reading else { return }
        discoverLogs()
        guard let root else { status = "未连接游戏日志，请点击选择日志"; connectionText = "未连接 · 选择日志"; return }
        reading = true
        let token = generation
        let dredge = dredgeIDs
        logQueue.async {
            self.reader.dredgeCards = dredge
            let result = self.reader.read(root: root)
            DispatchQueue.main.async {
                self.reading = false
                guard !self.demo, self.generation == token else { return }
                self.tracker = result.tracker; self.file = result.file; self.lastLogUpdate = result.modified
                if self.autoPlayer, let player = result.tracker.localPlayer { self.player = player }
                self.identifyDeck()
                self.status = result.message
                self.connectionText = result.file == nil ? "未连接 · 等待日志" : result.bytes < result.total ? "正在恢复对局" : result.tracker.processedLines == 0 ? "等待开局数据" : "已连接 · \(result.tracker.processedLines) 条事件"
                self.revision += 1
            }
        }
    }
    func importDeck(_ input: String, title: String = "", source: String = "手动导入") throws {
        guard libraryWritable else { throw DeckImportError(message: "套牌收藏文件无法读取，未覆盖原文件。请恢复 decks.json 后重启。") }
        var result: [DeckCard] = []
        if let code = try DeckCode.extract(input) {
            result = try DeckCode(code).resolve(cards)
        } else {
        for line in input.components(separatedBy: .newlines) {
            let s = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty || s.hasPrefix("#") { continue }
            guard let m = match("^(\\d+)\\s*[x×]?\\s+(.+)$", s), let count = Int(m[1]), count > 0, count <= 60 else { throw NSError(domain: "Deck", code: 1, userInfo: [NSLocalizedDescriptionKey: "请粘贴完整套牌代码或游戏复制的整段牌组文本；也支持 2 CS2_029 或 2 火球术。"] ) }
            let name = m[2]
            let found = cards[name] ?? cards.values.first(where: { $0.name == name })
            guard found != nil || match("^[A-Za-z0-9]+_[A-Za-z0-9_]+$", name) != nil else { throw NSError(domain: "Deck", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法识别 \(name)，请先下载卡牌库，或使用卡牌 ID。"] ) }
            let item = DeckCard(id: found?.id ?? name, name: found?.name ?? name, count: count, cost: found?.cost ?? 0)
            if let i = result.firstIndex(where: { $0.id == item.id }) { result[i].count += count } else { result.append(item) }
        }
        }
        guard !result.isEmpty, result.filter({ $0.sideboardOwner == nil }).reduce(0, { $0 + $1.count }) <= 60 else { throw NSError(domain: "Deck", code: 3, userInfo: [NSLocalizedDescriptionKey: "牌组不能为空，且不能超过 60 张。"] ) }
        let exportedName = input.components(separatedBy: .newlines).first { $0.hasPrefix("### ") }.map { String($0.dropFirst(4)) }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = SavedDeck(name: name.isEmpty ? (exportedName ?? "套牌 \(library.decks.count + 1)") : name,
                              cards: result.sorted { ($0.cost, $0.name) < ($1.cost, $1.name) }, source: source)
        var next = library
        _ = next.save(saved)
        try JSONEncoder().encode(next).write(to: storage.appendingPathComponent("decks.json"), options: .atomic)
        library = next; deck = selectedDeck?.cards ?? []
        let total = deck.filter { $0.sideboardOwner == nil }.reduce(0) { $0 + $1.count }
        status = "已导入 \(total) 张主牌；请在下一局使用这副牌组"
    }
    func persistLibrary() throws {
        guard libraryWritable else { throw DeckImportError(message: "套牌收藏文件无法读取，未覆盖原文件") }
        try JSONEncoder().encode(library).write(to: storage.appendingPathComponent("decks.json"), options: .atomic)
    }
    func selectDeck(_ id: String) {
        guard let chosen = library.decks.first(where: { $0.id == id }) else { return }
        let previous = library.selected
        library.selected = id
        do { try persistLibrary(); deck = chosen.cards; deckStatus = "已选择：\(chosen.name)" }
        catch { library.selected = previous; status = "套牌保存失败：\(error.localizedDescription)" }
    }
    func renameDeck(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let i = library.decks.firstIndex(where: { $0.id == library.selected }) else { return }
        let old = library; library.decks[i].name = name
        do { try persistLibrary() } catch { library = old; status = "重命名保存失败" }
    }
    func identifyDeck() {
        guard autoDeck, tracker.active, !demo else { return }
        if matchedGame != tracker.gameID { matchedGame = tracker.gameID; deck = []; deckStatus = "等待起手牌识别套牌" }
        guard tracker.localPlayer != nil || !autoPlayer else { return }
        let options = library.candidates(for: tracker, player: player)
        if options.count == 1 {
            let chosen = options[0]
            if library.selected != chosen.id || deck.isEmpty { selectDeck(chosen.id) }
            deckStatus = "自动识别 · \(chosen.name)"
        } else {
            deck = []
            deckStatus = options.isEmpty ? "尚未匹配 · 显示日志已知卡牌" : "\(options.count) 副套牌相似 · 等待更多抽牌"
        }
    }
    func captureDecks() {
        guard autoCapture else { return }
        let pasteboard = NSPasteboard.general
        if clipboardChange != pasteboard.changeCount {
            clipboardChange = pasteboard.changeCount
            let foreground = NSWorkspace.shared.frontmostApplication
            if foreground?.localizedName?.lowercased() == "hearthstone" || foreground?.bundleIdentifier?.lowercased() == "com.blizzard.hearthstone" {
                if let text = pasteboard.string(forType: .string), (try? DeckCode.extract(text)) != nil {
                    do { try importDeck(text, source: "收藏复制"); captureStatus = "已收录：\(selectedDeck?.name ?? "套牌")" }
                    catch { captureStatus = error.localizedDescription }
                }
            }
        }
        // Some clients emit deck strings in Decks.log. Never infer a full deck
        // from an incomplete card list or from unrelated logs.
        guard let root else { return }
        let sessions = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []).filter { $0.lastPathComponent.hasPrefix("Hearthstone_") }
        let folder = sessions.max(by: { $0.lastPathComponent < $1.lastPathComponent }) ?? root
        let url = folder.appendingPathComponent("Decks.log")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), let size = (attrs[.size] as? NSNumber)?.uint64Value else { return }
        if collectionFile != url || size < collectionOffset { collectionFile = url; collectionOffset = 0; collectionPending = Data() }
        guard size > collectionOffset, let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: collectionOffset)
            let data = try handle.read(upToCount: 256 * 1024) ?? Data(); collectionOffset += UInt64(data.count); collectionPending.append(data)
            if let end = collectionPending.lastIndex(of: 10) {
                for line in collectionPending[...end].split(separator: 10) {
                    let text = String(decoding: line, as: UTF8.self)
                    if let code = match("(?:DeckString|deckString|deckstring|DeckCode)[:=]\\s*([A-Za-z0-9+/]+=*)", text)?[1] {
                        do { try importDeck(code, source: "收藏日志"); captureStatus = "收藏日志已收录：\(selectedDeck?.name ?? "套牌")" }
                        catch { captureStatus = error.localizedDescription }
                    }
                }
                collectionPending = Data(collectionPending[collectionPending.index(after: end)...])
            }
            if collectionPending.count > 1024 * 1024 { collectionPending = Data() }
        } catch { captureStatus = "收藏日志读取失败，可在炉石中复制套牌收录" }
    }
    func name(_ id: String) -> String { cards[id]?.name ?? deck.first(where: { $0.id == id })?.name ?? id }
    func demonstrate() {
        generation += 1; demo = true; tracker.reset()
        let lines = ["CREATE_GAME", "FULL_ENTITY - Creating ID=10 CardID=CS2_029", "tag=CONTROLLER value=1", "tag=ZONE value=DECK", "FULL_ENTITY - Creating ID=11 CardID=CS2_023", "tag=CONTROLLER value=1", "tag=ZONE value=DECK", "TAG_CHANGE Entity=10 tag=ZONE value=HAND", "TAG_CHANGE Entity=1 tag=TURN value=3", "BLOCK_START BlockType=PLAY Entity=[entityName=Fireball id=20 zone=HAND zonePos=1 cardId=CS2_029 player=2] EffectCardId= EffectIndex=0"]
        for l in lines { tracker.ingest("D 00:00:00 GameState.DebugPrintPower() - " + l) }
        status = "演示数据 · 不代表真实对局"; revision += 1
    }
}
struct ContentView: View {
    @ObservedObject var m: Model
    @State var importing = false
    @State var input = ""
    @State var error = ""
    @State var deckName = ""
    @State var showSettings = false
    @ObservedObject var overlay: OverlayController
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                HStack(spacing: 14) {
                    Image(systemName: "flame.fill").font(.system(size: 29)).foregroundStyle(Tavern.gold).padding(13).background(Tavern.wood, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(Tavern.gold.opacity(0.5)))
                    VStack(alignment: .leading, spacing: 4) { Text("炉边 · 旅店手札").font(.system(size: 29, weight: .bold, design: .serif)).foregroundStyle(Tavern.cream); Text("套牌收藏  /  实时记牌  /  0.6").font(.caption).foregroundStyle(Tavern.gold) }
                }
                Spacer()
                Text(m.demo ? "演示" : "回合 \(m.tracker.turn)").font(.headline).padding(10).background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            }
            Text(m.status).font(.callout).foregroundStyle(m.demo ? .orange : .secondary).textSelection(.enabled)
            HStack {
                Button("开启游戏日志") { m.configure() }
                Button("选择日志") { m.chooseLogs() }
                Button("导入牌组") { importing = true }
                Spacer()
                Button("进入对局视图") {
                    m.resumeLive()
                    overlay.enabled = true
                    NotificationCenter.default.post(name: .hideTrackerSettings, object: nil)
                }
            }
            DeckShelf(m: m)
            DisclosureGroup("悬浮窗与外观设置", isExpanded: $showSettings) { OverlaySettings(overlay: overlay, m: m) }.foregroundStyle(Tavern.cream)
            HStack {
                Text("我方玩家编号")
                Picker("", selection: $m.player) { Text("玩家 1").tag(1); Text("玩家 2").tag(2) }.pickerStyle(.segmented).frame(width: 180).disabled(m.autoPlayer)
                Toggle("自动识别我方", isOn: $m.autoPlayer)
                Text("自动识别有误时关闭并手动选择").font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 16) {
                column(title: "我的牌库", subtitle: "牌库 \(m.tracker.count(m.player, "DECK"))  ·  手牌 \(m.tracker.count(m.player, "HAND"))") {
                    TopDeckView(m: m)
                    if m.deck.isEmpty { Text("导入牌组后显示原始牌组剩余张数。\n日志中的已知牌库显示在下方。").foregroundStyle(.secondary).padding(.vertical) }
                    ForEach(m.deck.filter { $0.sideboardOwner == nil }, id: \.id) { c in
                        row(m.name(c.id), cost: c.cost, count: max(0, c.count - m.tracker.removed(m.player, c.id)))
                    }
                    if m.deck.contains(where: { $0.sideboardOwner != nil }) {
                        Divider()
                        Text("备选牌 · 导入清单，不计入主牌剩余").font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(m.deck.filter { $0.sideboardOwner != nil }.enumerated()), id: \.offset) { _, c in
                            VStack(alignment: .leading) {
                                row(m.name(c.id), cost: c.cost, count: c.count)
                                Text("所属：" + m.name(c.sideboardOwner!)).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Divider()
                    Text("日志中已知的牌库卡牌").font(.caption).foregroundStyle(.secondary)
                    let known = Dictionary(grouping: m.tracker.entities.values.filter { $0.controller == m.player && $0.zone == "DECK" && !$0.card.isEmpty }, by: { $0.card })
                    ForEach(known.keys.sorted(), id: \.self) { id in row(m.name(id), cost: m.cards[id]?.cost ?? 0, count: known[id]?.count ?? 0) }
                }
                column(title: "对手已打出", subtitle: "牌库 \(m.tracker.count(3-m.player, "DECK"))  ·  手牌 \(m.tracker.count(3-m.player, "HAND"))") {
                    let plays = Dictionary(grouping: m.tracker.plays.filter { $0.player == 3-m.player }, by: { $0.card })
                    if plays.isEmpty { Text("等待对手出牌…").foregroundStyle(.secondary).padding(.vertical) }
                    ForEach(plays.keys.sorted(), id: \.self) { id in row(m.name(id), cost: m.cards[id]?.cost ?? 0, count: plays[id]?.count ?? 0) }
                }
            }
            Text("原始牌组为估算：请在开局前连接日志。变形、洗牌与生成牌等复杂效果可能影响统计；本版不支持酒馆战棋。").font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack { Button("更新中文卡牌库") { m.updateCards() }; Text(m.databaseStatus).font(.caption).foregroundStyle(.secondary); Spacer(); Button(m.demo ? "退出演示" : "查看演示") { if m.demo { m.resumeLive() } else { m.demonstrate() } } }
            if !m.path.isEmpty { Text(m.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled) }
        }.padding(24).frame(minWidth: 850, minHeight: 800).background(Tavern.background).preferredColorScheme(.dark).tint(Tavern.gold)
        .sheet(isPresented: $importing) {
            VStack(alignment: .leading, spacing: 14) {
                Text("导入牌组").font(.title2.bold())
                TextField("套牌名称（留空则读取游戏中的名称）", text: $deckName).textFieldStyle(.roundedBorder)
                Text("在炉石中复制套牌，然后粘贴整段文本或 AAE / AAECA 等开头的套牌代码。\n首次使用请先更新中文卡牌库。也保留“2 火球术”的逐行导入方式。").font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("从剪贴板粘贴") {
                        if let text = NSPasteboard.general.string(forType: .string) { input = text; error = "" }
                        else { error = "剪贴板中没有文本，请先在炉石中复制套牌。" }
                    }
                    Button("更新中文卡牌库") { m.updateCards() }
                }
                Text(m.databaseStatus).font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $input).font(.system(.body, design: .monospaced)).frame(height: 220).border(.gray.opacity(0.3))
                Text(error).foregroundStyle(.red)
                HStack { Button("取消") { importing = false }; Spacer(); Button("保存到套牌收藏") { do { try m.importDeck(input, title: deckName); error = ""; importing = false; input = ""; deckName = "" } catch { self.error = error.localizedDescription } }.keyboardShortcut(.defaultAction) }
            }.padding(24).frame(width: 520)
        }
    }
    func column<Content: View>(title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) { Text(title).font(.title3.bold()); Text(subtitle).font(.callout).foregroundStyle(.secondary); ScrollView { VStack(alignment: .leading, spacing: 7, content: content).frame(maxWidth: .infinity, alignment: .leading) } }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
    }
    func row(_ name: String, cost: Int, count: Int) -> some View { HStack { Text("\(cost)").font(.system(.caption, design: .rounded).bold()).frame(width: 25, height: 25).background(.blue.opacity(0.2), in: Circle()); Text(name).lineLimit(1); Spacer(); Text("×\(count)").monospacedDigit() }.padding(7).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7)).opacity(count == 0 ? 0.4 : 1) }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let model = Model()
    let overlays = OverlayController()
    var statusItem: NSStatusItem!
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu(); let item = NSMenuItem(); menu.addItem(item); let submenu = NSMenu(); submenu.addItem(withTitle: "退出炉边记牌器", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); item.submenu = submenu
        let edit = NSMenuItem(); menu.addItem(edit); let edits = NSMenu(title: "编辑"); edits.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c"); edits.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v"); edits.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"); edit.submenu = edits; NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 850), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "炉边记牌器"; window.contentView = NSHostingView(rootView: ContentView(m: model, overlay: overlays)); window.level = .normal; window.isReleasedWhenClosed = false; window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.addObserver(self, selector: #selector(hideSettings), name: .hideTrackerSettings, object: nil)
        overlays.setup(model)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: "炉边记牌器")
        let tray = NSMenu()
        for (title, action) in [("打开设置", #selector(showSettings)), ("显示 / 隐藏左右面板", #selector(togglePanels)), ("点击穿透 / 交互模式", #selector(toggleLock)), ("折叠 / 展开左侧", #selector(toggleOwnCollapse)), ("折叠 / 展开右侧", #selector(toggleOpponentCollapse)), ("恢复两侧位置", #selector(resetPanels))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; tray.addItem(item)
        }
        tray.addItem(.separator()); tray.addItem(withTitle: "退出炉边记牌器", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = tray
    }
    @objc func showSettings() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func hideSettings() { window.close() }
    @objc func togglePanels() { overlays.enabled.toggle() }
    @objc func toggleLock() { overlays.locked.toggle() }
    @objc func toggleOwnCollapse() { overlays.toggleCollapsed(opponent: false) }
    @objc func toggleOpponentCollapse() { overlays.toggleCollapsed(opponent: true) }
    @objc func resetPanels() { overlays.resetLayout() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSettings(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
@main struct Main {
    static func main() { let app = NSApplication.shared; let delegate = AppDelegate(); app.delegate = delegate; app.setActivationPolicy(.regular); app.run() }
}
