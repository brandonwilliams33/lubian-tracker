import Cocoa
import SwiftUI
import Combine

struct OverlayCard: Identifiable {
    var id: String; var name: String; var cost: Int?; var count: Int
}
extension Model {
    func overlayCards(opponent: Bool) -> [OverlayCard] {
        if demo {
            let names = ["奥术飞弹", "法力浮龙", "镜像", "寒冰箭", "巫师学徒", "奥术智慧", "寒冰屏障", "火球术", "变形术", "水元素", "碧蓝幼龙", "暴风雪", "烈焰风暴", "大法师安东尼达斯", "炎爆术"]
            let costs = [1,1,1,2,2,3,3,4,4,4,5,6,7,7,10]
            let ids = ["EX1_277", "NEW1_012", "CS2_027", "CS2_024", "EX1_608", "CS2_023", "EX1_289", "CS2_029", "CS2_022", "CS2_033", "EX1_284", "CS2_028", "CS2_032", "EX1_559", "EX1_279"]
            let indices = opponent ? [1,3,5,7,9] : Array(names.indices)
            return indices.map { OverlayCard(id: ids[$0], name: cards[ids[$0]]?.name ?? names[$0], cost: cards[ids[$0]]?.cost ?? costs[$0], count: opponent ? 1 : ($0 == 1 || $0 == 3 ? 0 : 2)) }
        }
        if opponent {
            let grouped = Dictionary(grouping: tracker.plays.filter { $0.player == 3-player }, by: { $0.card })
            return grouped.map { OverlayCard(id: $0.key, name: name($0.key), cost: cards[$0.key]?.cost, count: $0.value.count) }.sorted { ($0.cost ?? 99, $0.name) < ($1.cost ?? 99, $1.name) }
        }
        if !deck.isEmpty {
            return deck.filter { $0.sideboardOwner == nil }.map { OverlayCard(id: $0.id, name: name($0.id), cost: $0.cost, count: max(0, $0.count-tracker.removed(player, $0.id))) }.sorted { ($0.cost ?? 99, $0.name) < ($1.cost ?? 99, $1.name) }
        }
        let grouped = Dictionary(grouping: tracker.entities.values.filter { $0.controller == player && $0.zone == "DECK" && !$0.card.isEmpty }, by: { $0.card })
        return grouped.map { OverlayCard(id: $0.key, name: name($0.key), cost: cards[$0.key]?.cost, count: $0.value.count) }.sorted { ($0.cost ?? 99, $0.name) < ($1.cost ?? 99, $1.name) }
    }
}
final class OverlayController: NSObject, ObservableObject, NSWindowDelegate {
    @Published var enabled = false { didSet { refresh() } }
    @Published var locked = true { didSet { UserDefaults.standard.set(locked, forKey: "overlayLocked"); refresh() } }
    @Published var follow = true { didSet { UserDefaults.standard.set(follow, forKey: "overlayFollow"); lastArea = nil; refresh() } }
    @Published var opacity = 0.92 { didSet { UserDefaults.standard.set(opacity, forKey: "overlayOpacity"); refresh() } }
    @Published var scale = 1.0 { didSet { UserDefaults.standard.set(scale, forKey: "overlayScale"); lastArea = nil; refresh() } }
    @Published var locationStatus = "开启后显示左右记牌面板"
    @Published var collapsedOwn = false { didSet { UserDefaults.standard.set(collapsedOwn, forKey: "overlayCollapsedOwn"); lastArea = nil; refresh() } }
    @Published var collapsedOpponent = false { didSet { UserDefaults.standard.set(collapsedOpponent, forKey: "overlayCollapsedOpponent"); lastArea = nil; refresh() } }
    private var panels: [NSPanel] = []
    private var timer: Timer?
    private var placing = false
    private var lastArea: CGRect?
    private weak var model: Model?
    var showMain: (() -> Void)?
    func setup(_ model: Model) {
        self.model = model
        let d = UserDefaults.standard
        locked = d.object(forKey: "overlayLocked") == nil ? true : d.bool(forKey: "overlayLocked")
        if !d.bool(forKey: "overlayInteractionV5Migrated") {
            locked = false
            d.set(true, forKey: "overlayInteractionV5Migrated")
        }
        follow = d.object(forKey: "overlayFollow") == nil ? true : d.bool(forKey: "overlayFollow")
        opacity = d.object(forKey: "overlayOpacity") == nil ? 0.92 : min(1, max(0.55, d.double(forKey: "overlayOpacity")))
        scale = d.object(forKey: "overlayScale") == nil ? 1 : min(1.35, max(0.8, d.double(forKey: "overlayScale")))
        collapsedOwn = d.bool(forKey: "overlayCollapsedOwn")
        collapsedOpponent = d.bool(forKey: "overlayCollapsedOpponent")
        for i in 0..<2 {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 600), styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
            p.title = i == 0 ? "炉边 · 我的牌库" : "炉边 · 对手已出"
            p.titleVisibility = .hidden; p.titlebarAppearsTransparent = true
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { p.standardWindowButton(button)?.isHidden = true }
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
            p.isFloatingPanel = true; p.hidesOnDeactivate = false; p.becomesKeyOnlyIfNeeded = true
            p.level = .floating; p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.isMovableByWindowBackground = true; p.isReleasedWhenClosed = false
            p.minSize = NSSize(width: 180, height: 112); p.maxSize = NSSize(width: 420, height: 1200)
            p.contentView = NSHostingView(rootView: FloatingDeckView(m: model, overlay: self, opponent: i == 1))
            panels.append(p)
            if let saved = d.string(forKey: "overlayFrame\(i)") {
                let frame = NSRectFromString(saved)
                if frame.width >= 180 && frame.height >= 260 { p.setFrame(frame, display: false) }
            }
            p.delegate = self
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in self?.refresh() }
    }
    private func gameFrame() -> CGRect? {
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            let name = app.localizedName?.lowercased() ?? ""
            return name == "hearthstone" || name == "炉石传说" || app.bundleIdentifier?.lowercased() == "com.blizzard.hearthstone"
        }
        let ids = Set(apps.map { $0.processIdentifier })
        guard !ids.isEmpty, let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]], let main = NSScreen.screens.first else { return nil }
        return windows.compactMap { info -> CGRect? in
            guard let pid = info[kCGWindowOwnerPID as String] as? Int32, ids.contains(pid), (info[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.width > 500, rect.height > 300 else { return nil }
            return CGRect(x: rect.minX, y: main.frame.maxY-rect.maxY, width: rect.width, height: rect.height)
        }.max { $0.width * $0.height < $1.width * $1.height }
    }
    func refresh() {
        guard panels.count == 2 else { return }
        guard enabled else { panels.forEach { $0.orderOut(nil) }; return }
        let game = gameFrame()
        let screen = NSScreen.screens.max { a, b in
            let target = game ?? CGRect(origin: NSEvent.mouseLocation, size: CGSize(width: 1, height: 1))
            let ra = a.frame.intersection(target), rb = b.frame.intersection(target)
            return (ra.isNull ? 0 : ra.width*ra.height) < (rb.isNull ? 0 : rb.width*rb.height)
        } ?? NSScreen.main
        guard let screen else { return }
        let area = game.map { $0.intersection(screen.visibleFrame) }.flatMap { $0.isNull || $0.width < 450 || $0.height < 280 ? nil : $0 } ?? screen.visibleFrame
        let message = game == nil ? "未找到炉石窗口 · 已放在屏幕两侧" : (follow ? "已贴合炉石窗口两侧" : "使用自定义位置")
        if locationStatus != message { locationStatus = message }
        placing = true
        if follow && lastArea != area {
            let base = OverlayLayout.frames(area: area, scale: scale)
            for (index, panel) in panels.enumerated() {
                var frame = base[index]
                if isCollapsed(opponent: index == 1) { frame = CGRect(x: frame.minX, y: frame.maxY - 112, width: frame.width, height: 112) }
                panel.setFrame(frame, display: true)
            }
            lastArea = area
        } else if !follow {
            for panel in panels {
                let available = NSScreen.screens.first { $0.visibleFrame.intersects(panel.frame) }?.visibleFrame ?? screen.visibleFrame
                let clamped = OverlayLayout.clamped(panel.frame, to: available)
                if panel.frame != clamped { panel.setFrame(clamped, display: true) }
            }
        }
        for p in panels {
            p.alphaValue = opacity; p.ignoresMouseEvents = locked; p.isMovable = !locked
            // Locked overlays yield all clicks to the game. Hide when another app is active,
            // except our settings window or an explicit demo/desktop preview.
            let front = NSWorkspace.shared.frontmostApplication
            let name = front?.localizedName?.lowercased() ?? ""
            let gameFront = name == "hearthstone" || name == "炉石传说" || front?.bundleIdentifier?.lowercased() == "com.blizzard.hearthstone"
            let show = game == nil || model?.demo == true || gameFront || front?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            if show { if !p.isVisible { p.orderFrontRegardless() } } else { p.orderOut(nil) }
        }
        placing = false
    }
    func resetLayout() { follow = true; lastArea = nil; refresh() }
    func isCollapsed(opponent: Bool) -> Bool { opponent ? collapsedOpponent : collapsedOwn }
    func toggleCollapsed(opponent: Bool) {
        if opponent { collapsedOpponent.toggle() } else { collapsedOwn.toggle() }
    }
    func windowWillMove(_ notification: Notification) { if !placing && !locked { follow = false } }
    func windowWillStartLiveResize(_ notification: Notification) { if !placing && !locked { follow = false } }
    func windowDidMove(_ notification: Notification) { saveFrames() }
    func windowDidEndLiveResize(_ notification: Notification) { saveFrames() }
    private func saveFrames() {
        guard !placing, !follow else { return }
        for (i, p) in panels.enumerated() { UserDefaults.standard.set(NSStringFromRect(p.frame), forKey: "overlayFrame\(i)") }
    }
}
struct FloatingDeckView: View {
    @ObservedObject var m: Model
    @ObservedObject var overlay: OverlayController
    let opponent: Bool
    @State private var hoveredCard: OverlayCard?
    private var accent: Color { opponent ? Color(red: 0.88, green: 0.46, blue: 0.30) : Tavern.gold }
    var body: some View {
        GeometryReader { geo in
            let rows = m.overlayCards(opponent: opponent)
            let collapsed = overlay.isCollapsed(opponent: opponent)
            let height = min(31.0, max(23.0, (geo.size.height-215) / Double(max(1, rows.count))))
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: opponent ? "eye" : "square.stack.3d.up").foregroundStyle(accent)
                    Text(opponent ? "对手已出" : "我的牌库").font(.system(size: 15, weight: .semibold))
                    Spacer(minLength: 0)
                    Button { overlay.toggleCollapsed(opponent: opponent) } label: {
                        Image(systemName: collapsed ? "chevron.down" : "chevron.up").font(.system(size: 10, weight: .bold)).frame(width: 22, height: 22).background(.white.opacity(0.07), in: Circle())
                    }.buttonStyle(.plain).help(collapsed ? "展开卡牌列表" : "折叠卡牌列表")
                    Image(systemName: overlay.locked ? "lock.fill" : "hand.point.up.left.fill").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                }.padding(.top, 12)
                HStack {
                    Text(m.demo ? "演示 · 示例牌组" : "回合 \(m.tracker.turn)")
                    Spacer()
                    Circle().fill(m.demo ? Color.orange : (m.tracker.active ? accent : .gray)).frame(width: 5, height: 5)
                    Text(m.demo ? "PREVIEW" : (m.tracker.active && m.file != nil ? "LIVE" : "未就绪"))
                }.font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.45))
                if !collapsed {
                    Text(m.demo ? "演示数据 · 非实时对局" : m.connectionText).font(.system(size: 9)).foregroundStyle(m.file == nil && !m.demo ? .orange : .white.opacity(0.5)).lineLimit(1)
                    HStack(spacing: 6) {
                        metric("牌库", value: deckCount)
                        metric("手牌", value: handCount)
                    }
                    fatigueStrip
                    if !opponent {
                        Text(m.demo ? "演示套牌" : m.deckStatus).font(.system(size: 9)).foregroundStyle(Tavern.gold).lineLimit(1)
                        TopDeckView(m: m)
                    }
                    Rectangle().fill(accent.opacity(0.25)).frame(height: 1)
                    if rows.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: opponent ? "eye.slash" : "rectangle.stack.badge.plus").font(.system(size: 28, weight: .ultraLight)).foregroundStyle(accent.opacity(0.55))
                            Text(opponent ? "等待对手出牌" : "尚未导入牌组").font(.system(size: 13, weight: .medium))
                            Text(opponent ? "公开的出牌会记录在这里" : "在主窗口粘贴套牌代码\n即可显示完整清单").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4)).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 3) {
                                ForEach(rows) { c in
                                    Button { hoveredCard = c } label: { cardRow(c, height: height) }
                                        .buttonStyle(.plain)
                                        .contentShape(Rectangle())
                                        .onHover { inside in if !overlay.locked { hoveredCard = inside ? c : nil } }
                                        .help("预览 \(c.name)")
                                }
                            }
                        }
                        .scrollIndicators(.visible)
                        .help(overlay.locked ? "请在设置中关闭点击穿透，才能滚动和预览" : "滚轮浏览；把鼠标停在卡牌上查看图片与效果")
                    }
                    HStack {
                        Text("炉边").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(accent.opacity(0.8))
                        Spacer()
                        Text(overlay.locked ? "点击穿透" : "滚动 · 悬停预览").font(.system(size: 9)).foregroundStyle(.white.opacity(0.35))
                    }.padding(.bottom, 3)
                } else {
                    HStack(spacing: 8) {
                        Label("\(deckCount)", systemImage: "square.stack.3d.up").foregroundStyle(accent)
                        Label("\(handCount)", systemImage: "hand.raised.fill")
                        Spacer()
                        Label("下次疲劳 \(nextFatigue)", systemImage: "flame.fill").foregroundStyle(fatigueCount > 0 ? .orange : .white.opacity(0.45))
                    }.font(.system(size: 10, weight: .semibold)).lineLimit(1)
                }
            }.padding(.horizontal, 13).padding(.bottom, 10)
            .background(Tavern.background)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Tavern.gold.opacity(0.6), lineWidth: 1.5))
            .overlay(alignment: .top) { Capsule().fill(accent.opacity(0.8)).frame(width: 34, height: 2).padding(.top, 1) }
        }.foregroundStyle(.white).preferredColorScheme(.dark)
        .popover(item: $hoveredCard, attachmentAnchor: .rect(.bounds), arrowEdge: opponent ? .leading : .trailing) { card in
            CardPreview(card: m.cards[card.id], fallback: card).preferredColorScheme(.dark)
        }
    }
    private var playerID: Int { opponent ? 3-m.player : m.player }
    private var deckCount: Int { m.demo ? (opponent ? 23 : 26) : m.tracker.count(playerID, "DECK") }
    private var handCount: Int { m.demo ? (opponent ? 6 : 4) : m.tracker.count(playerID, "HAND") }
    private var fatigueCount: Int { m.demo ? (opponent ? 1 : 0) : m.tracker.fatigue(playerID) }
    private var nextFatigue: Int { fatigueCount + 1 }
    private var fatigueStrip: some View {
        HStack(spacing: 6) {
            Image(systemName: "flame.fill").foregroundStyle(fatigueCount > 0 ? .orange : .white.opacity(0.35))
            Text("疲劳").foregroundStyle(.white.opacity(0.55))
            Text("已触发 \(fatigueCount) 次").monospacedDigit()
            Spacer()
            Text("下次 \(nextFatigue) 点").foregroundStyle(fatigueCount > 0 ? .orange : .white.opacity(0.45)).monospacedDigit()
        }.font(.system(size: 9, weight: .medium)).padding(.horizontal, 9).padding(.vertical, 6).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
    }
    private func metric(_ label: String, value: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text("\(value)").font(.system(size: 21, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(label).font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
            Spacer(minLength: 0)
        }.padding(.horizontal, 10).padding(.vertical, 7).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
    }
    private func cardRow(_ card: OverlayCard, height: Double) -> some View {
        HStack(spacing: 7) {
            Text(card.cost.map(String.init) ?? "?").font(.system(size: 12, weight: .bold, design: .rounded)).frame(width: 24, height: height).background(accent.opacity(0.15)).foregroundStyle(accent)
            Text(card.name).font(.system(size: height < 24 ? 10 : 12, weight: .medium)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            Text(card.count == 0 ? "—" : "\(card.count)").font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(card.count == 0 ? .white.opacity(0.4) : accent).padding(.trailing, 8)
        }.frame(height: height).background(LinearGradient(colors: [.white.opacity(0.065), .white.opacity(0.025)], startPoint: .leading, endPoint: .trailing)).clipShape(RoundedRectangle(cornerRadius: 5)).opacity(card.count == 0 ? 0.38 : 1)
    }
}

struct CardPreview: View {
    let card: Card?
    let fallback: OverlayCard
    private var imageURL: URL? {
        let escaped = fallback.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fallback.id
        return URL(string: "https://art.hearthstonejson.com/v1/render/latest/zhCN/256x/\(escaped).png")
    }
    private var cleanText: String {
        guard var value = card?.text, !value.isEmpty else { return "暂无效果文字" }
        value = value.replacingOccurrences(of: "<br>", with: "\n").replacingOccurrences(of: "<br/>", with: "\n")
        value = value.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: "#", with: "")
        value = value.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
        return value
    }
    var body: some View {
        VStack(spacing: 10) {
            AsyncImage(url: imageURL) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFit()
                case .failure: previewPlaceholder
                case .empty: ProgressView().frame(height: 220)
                @unknown default: previewPlaceholder
                }
            }.frame(width: 230, height: 300)
            VStack(alignment: .leading, spacing: 6) {
                HStack { Text(card?.name ?? fallback.name).font(.headline); Spacer(); Text("\(card?.cost ?? fallback.cost ?? 0) 费").foregroundStyle(.cyan) }
                Text(cleanText).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if card?.attack != nil || card?.health != nil {
                    Text("攻击 \(card?.attack ?? 0)  ·  生命 \(card?.health ?? 0)").font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(12).frame(width: 260).background(Color(nsColor: .windowBackgroundColor))
    }
    private var previewPlaceholder: some View {
        VStack(spacing: 8) { Image(systemName: "photo").font(.largeTitle); Text("卡图暂时无法加载").font(.caption) }.foregroundStyle(.secondary).frame(width: 230, height: 220)
    }
}
struct OverlaySettings: View {
    @ObservedObject var overlay: OverlayController
    @ObservedObject var m: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "rectangle.lefthalf.inset.filled").foregroundStyle(.teal)
                Text("对局悬浮面板").font(.headline)
                Spacer()
                Toggle("显示左右面板", isOn: $overlay.enabled).toggleStyle(.switch).controlSize(.small)
            }
            HStack(spacing: 16) {
                Toggle("点击穿透", isOn: $overlay.locked)
                Toggle("跟随游戏窗口", isOn: $overlay.follow)
                Button(overlay.collapsedOwn ? "展开左侧" : "折叠左侧") { overlay.toggleCollapsed(opponent: false) }
                Button(overlay.collapsedOpponent ? "展开右侧" : "折叠右侧") { overlay.toggleCollapsed(opponent: true) }
                Spacer()
                Button("恢复两侧位置") { overlay.resetLayout() }
            }.font(.callout)
            HStack(spacing: 12) {
                Text("尺寸").font(.caption).foregroundStyle(.secondary)
                Slider(value: $overlay.scale, in: 0.8...1.35).frame(maxWidth: 160).disabled(!overlay.follow)
                Text("\(Int(overlay.scale*100))%").font(.caption.monospacedDigit()).frame(width: 38)
                Text("透明度").font(.caption).foregroundStyle(.secondary)
                Slider(value: $overlay.opacity, in: 0.55...1).frame(maxWidth: 160)
                Text("\(Int(overlay.opacity*100))%").font(.caption.monospacedDigit()).frame(width: 38)
                Spacer()
            }
            Text(overlay.enabled ? overlay.locationStatus + "。关闭点击穿透后，可滚轮浏览、悬停预览卡图与效果，也能拖动和缩放；开启点击穿透后鼠标直接操作游戏。" : "左侧显示己方牌库，右侧显示对手已出牌；设置完成后可关闭主窗口，菜单栏随时找回。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(16).background(Color.teal.opacity(0.055), in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.teal.opacity(0.15)))
    }
}
