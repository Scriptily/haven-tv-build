import SwiftUI
import UIKit

// MARK: - the layout, from Home Assistant

/// The "Apple TV" dashboard (url apple-tv) as Home Assistant stores it - edited there (sidebar ▸ Apple TV), drawn
/// natively here: headings, tiles, the thermostat, the media hub, the weather forecast, the missed-calls list. It's
/// read again whenever it's saved in Home Assistant (lovelace_updated) and every 10 minutes.
@MainActor
final class DashboardModel: ObservableObject {
    struct Tile: Hashable {
        let entity: String, name: String?, icon: String?, color: String?, hideState: Bool, action: String?, features: [String]
    }
    struct MediaEntry: Hashable {
        let entity: String, name: String?, icon: String?, options: [String], toggles: [String]
    }
    enum Card: Hashable {
        case tile(Tile)
        case thermostat(String)
        case media([MediaEntry])
        case weather(String)
        case todo(entity: String, title: String?)
    }
    struct Shown: Hashable { let card: Card; let visibleWhen: [Condition] }
    struct Condition: Hashable { let entity: String, above: Double?, below: Double?, state: String?, stateNot: String? }
    struct Section: Identifiable, Hashable { let id: Int; let title: String?; let icon: String?; let cards: [Shown] }

    static let path = "apple-tv"
    @Published private(set) var sections: [Section] = []
    /// the PC asks to see a section (tv.py dashshots): its index in the list, scrolled to the top
    @Published var scrollTarget: Int?
    @Published private(set) var problem: String?
    private let ha: HAConnection
    private var loading = false

    init(ha: HAConnection) {
        self.ha = ha
        ha.onConnected.append { [weak self] in
            guard let self else { return }
            Task { await self.load() }
            self.ha.subscribe(["type": "subscribe_events", "event_type": "lovelace_updated"]) { [weak self] ev in
                let p = (ev["data"] as? [String: Any])?["url_path"] as? String
                if p == nil || p == Self.path { Task { await self?.load() } }
            }
        }
        Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in Task { @MainActor in await self?.load() } }
    }

    func load() async {
        guard !loading, ha.status == .connected else { return }
        loading = true
        defer { loading = false }
        do {
            let cfg = try await ha.command(["type": "lovelace/config", "url_path": Self.path]) as? [String: Any] ?? [:]
            let view = (cfg["views"] as? [[String: Any]])?.first ?? [:]
            var out: [Section] = []
            for (i, s) in ((view["sections"] as? [[String: Any]]) ?? []).enumerated() {
                var title: String?, icon: String?, cards: [Shown] = []
                for c in s["cards"] as? [[String: Any]] ?? [] {
                    if c["type"] as? String == "heading" { title = c["heading"] as? String; icon = c["icon"] as? String; continue }
                    if let card = Self.parse(c) { cards.append(Shown(card: card, visibleWhen: Self.conditions(c["visibility"]))) }
                }
                if !cards.isEmpty { out.append(Section(id: i, title: title, icon: icon, cards: cards)) }
            }
            if out != sections { sections = out; Log.shared.add("dashboard: \(out.count) sections, \(out.reduce(0) { $0 + $1.cards.count }) cards") }
            problem = nil
        } catch {
            problem = "The Apple TV dashboard couldn't be read: \(error.localizedDescription)"
            Log.shared.add("dashboard: \(error.localizedDescription)", level: .warning)
        }
    }

    private static func parse(_ c: [String: Any]) -> Card? {
        let e = c["entity"] as? String ?? ""
        switch c["type"] as? String ?? "" {
        case "tile":
            return .tile(Tile(entity: e, name: c["name"] as? String, icon: c["icon"] as? String, color: c["color"] as? String,
                              hideState: c["hide_state"] as? Bool ?? false,
                              action: (c["tap_action"] as? [String: Any])?["action"] as? String,
                              features: (c["features"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String }))
        case "thermostat": return .thermostat(e)
        case "weather-forecast": return .weather(e)
        case "todo-list": return .todo(entity: e, title: c["title"] as? String)
        case "custom:media-hub-card":
            let list = (c["entities"] as? [[String: Any]] ?? []).compactMap { m -> MediaEntry? in
                guard let id = m["entity"] as? String else { return nil }
                return MediaEntry(entity: id, name: m["name"] as? String, icon: m["icon"] as? String,
                                  options: (m["options"] as? [[String: Any]] ?? []).compactMap { $0["entity"] as? String },
                                  toggles: (m["toggles"] as? [[String: Any]] ?? []).compactMap { $0["entity"] as? String })
            }
            return list.isEmpty ? nil : .media(list)
        default: return nil                 // clock (the top bar has one), anything unknown
        }
    }

    private static func conditions(_ v: Any?) -> [Condition] {
        (v as? [[String: Any]] ?? []).compactMap { d in
            guard let e = d["entity"] as? String else { return nil }
            return Condition(entity: e, above: (d["above"] as? NSNumber)?.doubleValue, below: (d["below"] as? NSNumber)?.doubleValue,
                             state: d["state"] as? String, stateNot: d["state_not"] as? String)
        }
    }

    func visible(_ s: Shown) -> Bool {
        s.visibleWhen.allSatisfy { c in
            let st = ha.state(c.entity)?.state ?? ""
            if let a = c.above { guard let n = Double(st), n > a else { return false } }
            if let b = c.below { guard let n = Double(st), n < b else { return false } }
            if let x = c.state, st != x { return false }
            if let x = c.stateNot, st == x { return false }
            return true
        }
    }
}

// MARK: - the screen

/// The dashboard's focus: tvOS had nowhere to put it when the aerials (whose button had it) handed over, so every press
/// went nowhere (2026-11-05 12:24: woken, then 3 min without one registered press). Now the first tile is the default and
/// the focus is put back there whenever the dashboard comes up.
private struct HavenFocusNSKey: EnvironmentKey { static let defaultValue: Namespace.ID? = nil }
private struct HavenFirstTileKey: EnvironmentKey { static let defaultValue: String? = nil }
extension EnvironmentValues {
    var havenFocusNS: Namespace.ID? { get { self[HavenFocusNSKey.self] } set { self[HavenFocusNSKey.self] = newValue } }
    var havenFirstTile: String? { get { self[HavenFirstTileKey.self] } set { self[HavenFirstTileKey.self] = newValue } }
}
struct DefaultFocusHere: ViewModifier {
    let on: Bool
    @Environment(\.havenFocusNS) private var ns
    func body(content: Content) -> some View {
        if let ns { content.prefersDefaultFocus(on, in: ns) } else { content }
    }
}

/// the dashboard's focus, handed to every tile (and "Home") through the environment - nil in the screenshot renderer
private struct HavenTileFocusKey: EnvironmentKey { static let defaultValue: FocusState<String?>.Binding? = nil }
extension EnvironmentValues {
    var havenTileFocus: FocusState<String?>.Binding? { get { self[HavenTileFocusKey.self] } set { self[HavenTileFocusKey.self] = newValue } }
}
struct TileFocus: ViewModifier {
    let id: String
    @Environment(\.havenTileFocus) private var focus
    func body(content: Content) -> some View {
        if let focus {
            content.focused(focus, equals: id).environment(\.havenFocused, focus.wrappedValue == id)
        } else {
            content
        }
    }
}

struct DashboardScreen: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var dash: DashboardModel
    @FocusState private var focus: String?
    @State private var lastFocus: String?
    @State private var anchorOn = true
    @State private var scrollY = 0

    /// the first row of tiles (the first 4 of the first section that starts with tiles): focus there = the page's top
    private var firstRow: Set<String> {
        for s in dash.sections {
            let tiles = s.cards.filter { dash.visible($0) }.compactMap { c -> String? in if case .tile(let t) = c.card { return t.entity } else { return nil } }
            if !tiles.isEmpty { return Set(tiles.prefix(4)) }
        }
        return []
    }
    /// the first tile of the first section that starts with tiles
    private var firstTile: String? {
        for s in dash.sections {
            let shown = s.cards.filter { dash.visible($0) }
            guard let c = shown.first else { continue }
            if case .tile(let t) = c.card { return t.entity }
            return nil
        }
        return nil
    }
    private func focusFirst() {
        guard model.screen == .dashboard else { return }
        anchorOn = true                                  // the invisible anchor, in case nothing has the focus
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            focus = lastFocus ?? firstTile ?? "__home"   // where you were, else the first tile (the anchor makes it take)
        }
        // and again until a tile really has it: back from the background, tvOS sometimes put it on the anchor ("Home"
        // looked selected, 2026-11-10) - or that control is gone (a to-do done...): the first tile
        for t in [0.6, 1.2, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { offAnchor() }
        }
    }
    /// the focus is on the anchor (or nowhere) while there are tiles: on to where you were
    private func offAnchor() {
        guard model.screen == .dashboard, focus == nil || focus == "__home", let to = lastFocus ?? firstTile else { return }
        Log.shared.add("focus: off the anchor, to \(to)")
        focus = to
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { if focus == nil || focus == "__home" { focus = firstTile } }
    }

    var body: some View {
        ZStack {
            Theme.backdrop
            ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                DashboardContent(dash: dash)
            }
            .environment(\.havenTileFocus, $focus)
            .environment(\.havenAnchorOn, anchorOn)
            .defaultFocus($focus, firstTile ?? "__home")
            .onChange(of: focus) { _, f in
                // tvOS scrolls only as far as the focused tile: back on the first row, show the whole top (as on opening)
                if let f, firstRow.contains(f) { withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo("dash-top", anchor: .top) } }
            }
            .onChange(of: dash.scrollTarget) { _, i in
                guard let i, i >= 0, i < dash.sections.count else { return }
                withAnimation(.easeInOut(duration: 0.5)) { proxy.scrollTo(dash.sections[i].id, anchor: .top) }
            }
            .onScrollGeometryChange(for: Int.self) { Int(($0.contentOffset.y + $0.contentInsets.top).rounded()) } action: { _, y in scrollY = y }
            .onScrollPhaseChange { _, p in if p == .idle { Log.shared.add("scroll: \(scrollY)") } }
            }
        }
        .onAppear { Task { await dash.load() }; focusFirst() }
        .onChange(of: focus) { _, f in
            if let f, f != "__home" { lastFocus = f; anchorOn = false }   // a tile has it: the anchor switches off
            Log.shared.add("focus: \(f ?? "nothing")")
            if f == "__home", !dash.sections.isEmpty, lastFocus != nil {   // it never stays on the anchor once there are tiles
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { offAnchor() }
            }
        }
        .onChange(of: model.screen) { _, s in if s == .dashboard { focusFirst() } }
        .onChange(of: model.focusReset) { _, _ in focusFirst() }
        .onChange(of: dash.sections.isEmpty) { _, empty in if !empty { focusFirst() } }   // the tiles just arrived
    }
}

/// the whole page: top bar + every visible section, full width
struct DashboardContent: View {
    @ObservedObject var dash: DashboardModel
    var body: some View {
        // "dash-top" is the page's real top, above the margin: scrolled to the top bar itself, the page stopped 56 points
        // short of the top - back on the first row it slid down a little after tvOS had already shown the top (build 58)
        VStack(alignment: .leading, spacing: 0) {
        Color.clear.frame(height: 0).id("dash-top")
        VStack(alignment: .leading, spacing: 64) {
            DashTopBar()
            if let p = dash.problem, dash.sections.isEmpty {
                Text(p).font(.title3).foregroundStyle(Theme.warn)
            } else if dash.sections.isEmpty {
                ProgressView().frame(maxWidth: .infinity)
            }
            ForEach(dash.sections) { s in
                let shown = s.cards.filter { dash.visible($0) }
                if !shown.isEmpty { SectionView(section: s, cards: shown.map(\.card)).id(s.id) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 90).padding(.top, 56).padding(.bottom, 120)
        }
        .animation(.easeInOut(duration: 0.35), value: dash.sections)
    }
}

/// tvOS only picks a system button as the very first focus, and the tiles load a moment after the dashboard appears - so
/// this invisible one is there from the first frame to take it, and the dashboard moves the focus on to a tile at once.
/// It switches off as soon as a tile has the focus (you can't land on it, and .plain's white platter never shows).
private struct HavenAnchorOnKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var havenAnchorOn: Bool { get { self[HavenAnchorOnKey.self] } set { self[HavenAnchorOnKey.self] = newValue } }
}
struct FocusAnchor: View {
    @Environment(\.havenAnchorOn) private var on
    var body: some View {
        Button {} label: { Color.white.frame(width: 60, height: 50) }
            .buttonStyle(.plain).focusEffectDisabled().hoverEffectDisabled()
            .modifier(TileFocus(id: "__home"))
            .opacity(0.02)                              // invisible, but still a focus target
            .disabled(!on)
    }
}

struct DashTopBar: View {
    @EnvironmentObject var ha: HAConnection
    @EnvironmentObject var model: AppModel
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            HStack(alignment: .firstTextBaseline) {
                Text("Home").font(.system(size: 54, weight: .semibold, design: .rounded)).tracking(-0.8).foregroundStyle(Theme.text)
                    .overlay(alignment: .leading) { FocusAnchor() }
                Spacer()
                if ha.status != .connected {
                    Label("Reconnecting", systemImage: "wifi.exclamationmark").font(.system(size: 22, weight: .medium)).foregroundStyle(Theme.warn)
                        .padding(.trailing, 24)
                }
                Text(ctx.date, format: .dateTime.weekday(.wide).hour().minute())
                    .font(.system(size: 26, weight: .medium)).monospacedDigit().foregroundStyle(Theme.muted)
                    .contentTransition(.numericText())
                    .animation(.smooth(duration: 0.6), value: ctx.date.formatted(.dateTime.hour().minute()))
            }
        }
    }
}

struct SectionView: View {
    let section: DashboardModel.Section
    let cards: [DashboardModel.Card]

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            if let t = section.title {
                HStack(spacing: 14) {
                    if let i = section.icon { Image(systemName: Icons.sf(i, domain: "")).font(.system(size: 24, weight: .semibold)) }
                    Text(t.uppercased()).font(.system(size: 22, weight: .semibold)).tracking(2.4)
                }
                .foregroundStyle(Theme.muted)
            }
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                switch b {
                case .tiles(let tiles):
                    // plain rows of 4, not a LazyVGrid: SwiftUI never found a first focus inside the lazy grid (cells made on
                    // demand), so with the tiles first on the page Haven had no focus at all (build 32 vs 31-39)
                    VStack(alignment: .leading, spacing: 30) {
                        ForEach(Array(stride(from: 0, to: tiles.count, by: 4)), id: \.self) { i in
                            HStack(spacing: 30) {
                                ForEach(Array(tiles[i..<min(i + 4, tiles.count)]), id: \.self) { TileView(tile: $0).frame(maxWidth: .infinity) }
                                ForEach(0..<(4 - min(4, tiles.count - i)), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                            }
                        }
                    }
                case .wide(let c):
                    switch c {
                    case .thermostat(let e): ThermostatCard(entity: e)
                    case .media(let m): MediaHub(entries: m)
                    case .weather(let e): WeatherCard(entity: e)
                    case .todo(let e, let title): TodoCard(entity: e, title: title)
                    case .tile: EmptyView()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // (no .focusSection(): tvOS never chose a first focus inside one - with every control in a section, Haven had none)
    }

    enum Block { case tiles([DashboardModel.Tile]), wide(DashboardModel.Card) }
    /// runs of tiles become a grid; the big cards get a row each
    private var blocks: [Block] {
        var out: [Block] = [], run: [DashboardModel.Tile] = []
        for c in cards {
            if case .tile(let t) = c { run.append(t); continue }
            if !run.isEmpty { out.append(.tiles(run)); run = [] }
            out.append(.wide(c))
        }
        if !run.isEmpty { out.append(.tiles(run)) }
        return out
    }
}

// MARK: - focus look (Haven's glass, lifted and lit when focused)

/// SwiftUI's isFocused doesn't reliably reach a custom ButtonStyle on tvOS, so each control tracks its own focus with
/// @FocusState and hands it down: the glass lifts on it, and the log says where the focus is ("focus: Lights On").
private struct HavenFocusedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var havenFocused: Bool { get { self[HavenFocusedKey.self] } set { self[HavenFocusedKey.self] = newValue } }
}
@MainActor enum FocusLog {
    static var last = Date.distantPast
    static func note(_ name: String) {
        guard Date().timeIntervalSince(last) > 0.5 else { return }
        last = Date()
        Log.shared.add("focus: \(name)")
    }
}
struct FocusLift: ViewModifier {
    let name: String
    @FocusState private var focused: Bool
    @EnvironmentObject var model: AppModel
    func body(content: Content) -> some View {
        content
            .focused($focused)
            .environment(\.havenFocused, focused)
            .onChange(of: focused) { _, f in if f { model.touch(); FocusLog.note(name) } }
    }
}

/// Haven's glass. Every glass control joins the dashboard's one focus binding under an id (TileFocus): the glass lifts when
/// it has the focus, and after the aerials the focus goes back to the same control (the page stays where it was). tvOS
/// never picks one of these as the very first focus - "Home" (a .plain button) takes that, then the dashboard moves it.
extension View {
    func glassButton(_ id: String, radius: CGFloat = 30, tint: Color = .clear, on: Bool = false) -> some View {
        self.buttonStyle(GlassButton(radius: radius, tint: tint, on: on)).modifier(TileFocus(id: id))
    }
}
struct GlassButton: ButtonStyle {
    var radius: CGFloat = 30
    var tint: Color = .clear
    var on = false
    func makeBody(configuration: Configuration) -> some View { Chrome(configuration: configuration, radius: radius, tint: tint, on: on) }

    struct Chrome: View {
        let configuration: Configuration
        let radius: CGFloat, tint: Color, on: Bool
        @Environment(\.isFocused) private var systemFocused
        @Environment(\.havenFocused) private var ownFocused
        private var focused: Bool { systemFocused || ownFocused }
        var body: some View {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            configuration.label
                .background {
                    ZStack {
                        shape.fill(.ultraThinMaterial)
                        shape.fill(Color(red: 0.06, green: 0.06, blue: 0.09).opacity(focused ? 0.15 : 0.45))
                        if on { shape.fill(RadialGradient(colors: [tint.opacity(0.32), tint.opacity(0.06)], center: .topLeading, startRadius: 0, endRadius: 520)) }
                        if focused { shape.fill(.white.opacity(0.10)) }
                    }
                }
                .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(focused ? 0.5 : 0.16), .white.opacity(0.04)],
                                                           startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: focused ? 2 : 1))
                .clipShape(shape)
                // pressed only while it also has the focus: a long press with no menu to open left isPressed stuck on
                // until the next press (2026-11-10, the AC energy tile)
                .scaleEffect(configuration.isPressed && focused ? 0.97 : (focused ? 1.06 : 1))
                .shadow(color: .black.opacity(focused ? 0.55 : 0.3), radius: focused ? 36 : 16, y: focused ? 22 : 8)
                .animation(.spring(response: 0.32, dampingFraction: 0.78), value: focused)
                .animation(.spring(response: 0.2, dampingFraction: 0.9), value: configuration.isPressed)
                .animation(.easeInOut(duration: 0.35), value: on)
        }
    }
}

/// a long-press menu only when there's something in it: an empty .contextMenu still took the long press, opened
/// nothing, and the tile stayed pressed in until the next press (2026-11-10, the sensor tiles)
struct MenuIfAny<Items: View>: ViewModifier {
    let any: Bool
    @ViewBuilder let items: () -> Items
    func body(content: Content) -> some View {
        if any { content.contextMenu { items() } } else { content }
    }
}

// MARK: - tiles

struct TileView: View {
    let tile: DashboardModel.Tile
    @EnvironmentObject var model: AppModel
    var body: some View { TileBody(tile: tile, ha: model.ha) }
}

/// redraws when its own entity changes - not on every state change in HA (that rebuilt a held long-press menu constantly)
struct TileBody: View {
    let tile: DashboardModel.Tile
    let ha: HAConnection
    @StateObject private var watch: EntityGroup
    @EnvironmentObject var model: AppModel
    init(tile: DashboardModel.Tile, ha: HAConnection) {
        self.tile = tile; self.ha = ha
        _watch = StateObject(wrappedValue: EntityGroup([ha.box(tile.entity)]))
    }

    var body: some View {
        let e = ha.state(tile.entity)
        let domain = String(tile.entity.split(separator: ".").first ?? "")
        let on = Look.isOn(domain: domain, state: e?.state ?? "")
        let tint = Look.color(tile.color, domain: domain)
        Button { act(domain) } label: {
            HStack(spacing: 22) {
                ZStack {
                    Circle().fill(on ? tint.opacity(0.28) : .white.opacity(0.08))
                    Text(Image(systemName: Icons.sf(tile.icon ?? (e?.attr("icon") ?? ""), domain: domain, deviceClass: e?.attr("device_class"), state: e?.state ?? "")))   // as text: a borderless button blows up an Image
                        .font(.system(size: 28, weight: .semibold)).foregroundStyle(on ? tint : .white.opacity(0.8))
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(tile.name ?? e?.name ?? tile.entity).font(.system(size: 25, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(2)
                        .minimumScaleFactor(0.85).fixedSize(horizontal: false, vertical: true)
                    if !tile.hideState {
                        Text(Look.stateText(e, domain: domain)).font(.system(size: 21)).foregroundStyle(Theme.muted).lineLimit(1)
                            .contentTransition(domain == "sensor" ? .numericText() : .opacity)
                    }
                }
                Spacer(minLength: 0)
                if !modes(e, domain).isEmpty {
                    Image(systemName: "ellipsis").font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.faint)
                }
            }
            .padding(.horizontal, 24).frame(height: 116).frame(maxWidth: .infinity, alignment: .leading)
        }
        .glassButton(tile.entity, tint: tint, on: on)
        .modifier(MenuIfAny(any: !modes(e, domain).isEmpty) {
            ForEach(modes(e, domain), id: \.self) { m in
                Button { setMode(m, domain) } label: {
                    if m == currentMode(e, domain) { Label(m.capitalized, systemImage: "checkmark") } else { Text(m.capitalized) }
                }
            }
        })
        .animation(.easeInOut(duration: 0.3), value: e?.state)
    }

    private func modes(_ e: EntityState?, _ domain: String) -> [String] {
        guard let e else { return [] }
        if domain == "humidifier", tile.features.contains("humidifier-modes") { return e.attr("available_modes") ?? [] }
        if domain == "fan", tile.features.contains("fan-preset-modes") { return e.attr("preset_modes") ?? [] }
        return []
    }
    private func currentMode(_ e: EntityState?, _ domain: String) -> String? {
        domain == "humidifier" ? e?.attr("mode") : e?.attr("preset_mode")
    }
    private func setMode(_ m: String, _ domain: String) {
        Log.shared.add("dashboard: \(tile.entity) mode \(m)")
        Task {
            if domain == "humidifier" { await ha.call("humidifier", "set_mode", data: ["mode": m], target: ["entity_id": tile.entity]) }
            else { await ha.call("fan", "set_preset_mode", data: ["preset_mode": m], target: ["entity_id": tile.entity]) }
        }
    }

    /// what Select does - the tile's tap action (a toggle), or what fits the entity
    private func act(_ domain: String) {
        model.touch()
        guard model.pressesOK else { Log.shared.add("dashboard: the press that woke the aerials - not a tap"); return }
        if tile.action == "none" { return }
        let target = ["entity_id": tile.entity]
        let call: (String, String)?
        switch domain {
        case "script": call = ("script", "turn_on")
        case "scene": call = ("scene", "turn_on")
        case "button", "input_button": call = (domain, "press")
        case "light", "switch", "input_boolean", "fan", "humidifier", "media_player", "automation", "cover", "climate", "siren":
            call = (domain, "toggle")
        case "lock": call = ("lock", ha.state(tile.entity)?.state == "locked" ? "unlock" : "lock")
        default: call = nil                                 // sensors: nothing to do
        }
        guard let (d, s) = call else { return }
        Log.shared.add("dashboard: \(d).\(s) \(tile.entity)")
        Task { await ha.call(d, s, target: target) }
    }
}

enum Look {
    static func isOn(domain: String, state: String) -> Bool {
        ["on", "playing", "open", "unlocked", "home", "heat", "cool", "heat_cool", "dry", "fan_only", "auto", "active"].contains(state)
            && !["scene", "button", "input_button"].contains(domain)
    }

    static func color(_ name: String?, domain: String) -> Color {
        switch name ?? "" {
        case "light-blue": return Color(red: 0.42, green: 0.78, blue: 1.0)
        case "blue": return Color(red: 0.25, green: 0.55, blue: 1.0)
        case "orange": return Color(red: 1.0, green: 0.62, blue: 0.25)
        case "red": return Color(red: 1.0, green: 0.42, blue: 0.40)
        case "green": return Color(red: 0.40, green: 0.86, blue: 0.55)
        case "purple": return Color(red: 0.70, green: 0.52, blue: 1.0)
        case "yellow", "amber": return Color(red: 1.0, green: 0.80, blue: 0.30)
        default: break
        }
        switch domain {
        case "light": return Color(red: 1.0, green: 0.78, blue: 0.36)
        case "climate", "fan", "humidifier": return Color(red: 0.42, green: 0.78, blue: 1.0)
        case "media_player": return Color(red: 0.55, green: 0.65, blue: 1.0)
        default: return Theme.accent
        }
    }

    static func stateText(_ e: EntityState?, domain: String) -> String {
        guard let e else { return "Not found" }
        let s = e.state
        if s == "unavailable" { return "Unavailable" }
        if s == "unknown" { return "—" }
        switch domain {
        case "sensor":
            if let n = Double(s) {
                let unit: String = e.attr("unit_of_measurement") ?? ""
                let v = abs(n) >= 100 || n == n.rounded() ? String(Int(n.rounded())) : String(format: "%.1f", n)
                return unit.isEmpty ? v : (unit == "%" || unit.hasPrefix("°") ? "\(v)\(unit)" : "\(v) \(unit)")
            }
            return s.replacingOccurrences(of: "_", with: " ").capitalized
        case "binary_sensor":
            let dc: String = e.attr("device_class") ?? ""
            switch dc {
            case "occupancy", "motion", "presence": return s == "on" ? "Detected" : "Clear"
            case "door", "window", "opening": return s == "on" ? "Open" : "Closed"
            default: return s == "on" ? "On" : "Off"
            }
        case "light":
            if s == "on", let b = (e.attributes["brightness"] as? NSNumber)?.doubleValue { return "\(Int((b / 255 * 100).rounded()))%" }
            return s.capitalized
        case "humidifier":
            let m: String = e.attr("mode") ?? ""
            return s == "on" ? (m.isEmpty ? "On" : m.capitalized) : "Off"
        case "fan":
            let p: String = e.attr("preset_mode") ?? ""
            return s == "on" ? (p.isEmpty ? "On" : p.capitalized) : "Off"
        case "script": return s == "on" ? "Running" : "Run"
        case "scene": return "Activate"
        case "button", "input_button": return "Press"
        default: return s.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

// MARK: - thermostat

struct ThermostatCard: View {
    let entity: String
    @EnvironmentObject var model: AppModel
    var body: some View { ThermostatBody(entity: entity, ha: model.ha) }
}

/// redraws when its climate entity changes - nothing else (its Mode menu stays put while open)
struct ThermostatBody: View {
    let entity: String
    let ha: HAConnection
    @StateObject private var watch: EntityGroup
    @EnvironmentObject var model: AppModel
    @State private var open = false
    @Environment(\.havenTileFocus) private var tileFocus
    init(entity: String, ha: HAConnection) {
        self.entity = entity; self.ha = ha
        _watch = StateObject(wrappedValue: EntityGroup([ha.box(entity)]))
    }

    var body: some View {
        let e = ha.state(entity)
        let cur: Double? = (e?.attributes["current_temperature"] as? NSNumber)?.doubleValue
        let target: Double? = (e?.attributes["temperature"] as? NSNumber)?.doubleValue
        let step: Double = (e?.attributes["target_temp_step"] as? NSNumber)?.doubleValue ?? 1
        let mode = e?.state ?? "off"
        HStack(spacing: 40) {
            // the card's own control: Select opens the AC's full controls (mode, fan speed, vanes) - it used to switch the
            // AC on / off, too easy to do by accident (2026-11-10). It's also where Down lands from the left column.
            Button { model.touch(); if model.pressesOK { open = true } } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Text(e?.name ?? "Thermostat").font(.system(size: 25, weight: .semibold)).foregroundStyle(Theme.text)
                        Image(systemName: "chevron.right").font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.faint)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 18) {
                        Text(cur.map { "\(Self.fmt($0))°" } ?? "—").font(.system(size: 72, weight: .light, design: .rounded)).foregroundStyle(Theme.text)
                            .contentTransition(.numericText(value: cur ?? 0))
                        Text(mode == "off" ? "Off" : "\(Self.pretty(mode)) to \(target.map { "\(Self.fmt($0))°" } ?? "—")")
                            .font(.system(size: 26, weight: .medium)).foregroundStyle(mode == "off" ? Theme.muted : Look.color(nil, domain: "climate"))
                            .contentTransition(.numericText(value: target ?? 0))
                    }
                    if mode != "off", let fan: String = e?.attr("fan_mode") {
                        let v: String = e?.attr("swing_mode") ?? "", h: String = e?.attr("swing_horizontal_mode") ?? ""
                        // the vane arrows as symbols: "↕" drew as a blue emoji box (2026-11-10)
                        let vT = v.isEmpty ? Text(verbatim: "") : Text("  ·  \(Image(systemName: "arrow.up.and.down")) \(Self.pretty(v))")
                        let hT = h.isEmpty ? Text(verbatim: "") : Text("  ·  \(Image(systemName: "arrow.left.and.right")) \(Self.pretty(h))")
                        Text("Fan \(Self.pretty(fan))\(vT)\(hT)")
                            .font(.system(size: 20, weight: .medium)).foregroundStyle(Theme.muted)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 22).padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeInOut(duration: 0.35), value: mode)
                .animation(.easeInOut(duration: 0.35), value: target)
                .animation(.easeInOut(duration: 0.35), value: cur)
            }
            .glassButton("thermostat:\(entity)", radius: 26, tint: Look.color(nil, domain: "climate"), on: mode != "off")
            .padding(.leading, -22)
            // (no Mode button: it's in the full controls)
            Group {
                Button { set(target, -step) } label: { Image(systemName: "minus").font(.system(size: 30, weight: .bold)).frame(width: 92, height: 92) }.glassButton("thermostat-:\(entity)", radius: 46)
                Button { set(target, step) } label: { Image(systemName: "plus").font(.system(size: 30, weight: .bold)).frame(width: 92, height: 92) }.glassButton("thermostat+:\(entity)", radius: 46)
            }
            .foregroundStyle(Theme.text)
        }
        .padding(34)
        .background(RoundedRectangle(cornerRadius: 34, style: .continuous).fill(.white.opacity(0.05)))
        .fullScreenCover(isPresented: $open) {
            ClimateView(entity: entity, ha: ha, close: {
                open = false
                let id = "thermostat:\(entity)"           // back on the card (tvOS would pick the nearest tile)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { tileFocus?.wrappedValue = id }
            }).environmentObject(model)
        }
        .onChange(of: model.screen) { _, s in if s != .dashboard { open = false } }   // idle: the aerials, not this
    }
    /// "MiddleTop1" -> "Middle Top 1", "LOW_MID" -> "Low Mid", "fan_only" -> "Fan Only"
    static func pretty(_ s: String) -> String {
        var out = ""
        let chars = Array(s.replacingOccurrences(of: "_", with: " "))
        for (i, c) in chars.enumerated() {
            if i > 0, c != " ", chars[i - 1] != " " {
                let p = chars[i - 1]
                if (c.isUppercase && p.isLowercase) || (c.isNumber && !p.isNumber) || (!c.isNumber && p.isNumber) { out.append(" ") }
            }
            out.append(c)
        }
        return out.lowercased().split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    private func set(_ t: Double?, _ d: Double) {
        model.touch()
        guard let t, model.pressesOK else { return }
        Log.shared.add("dashboard: \(entity) target \(t + d)")
        Task { await ha.call("climate", "set_temperature", data: ["temperature": t + d], target: ["entity_id": entity]) }
    }
    static func fmt(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }
}

// MARK: - media hub

struct MediaHub: View {
    let entries: [DashboardModel.MediaEntry]
    @State private var atStart = true
    @State private var atEnd = true
    /// the page's side margin: the row runs out to the screen edges, its panels rest at this margin
    private let margin: CGFloat = 90

    var body: some View {
        // tvOS alone scrolls the row (to the focused panel, within the content margins) - nothing here moves it. The
        // fades sit only in the margins, so they never cover a panel at rest, and a side fades only while the visible
        // part hasn't reached that end (measured, not guessed from the focus).
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 30) { ForEach(entries, id: \.self) { MediaPanel(entry: $0) } }
                .padding(.vertical, 26)
        }
        .contentMargins(.horizontal, margin, for: .scrollContent)
        .scrollClipDisabled()
        .onScrollGeometryChange(for: [Bool].self) { g in
            // at rest the visible part starts at minus the leading margin (content x 0 = the first panel's edge)
            [g.visibleRect.minX <= -g.contentInsets.leading + 1, g.visibleRect.maxX >= g.contentSize.width + g.contentInsets.trailing - 1]
        } action: { _, v in
            atStart = v[0]; atEnd = v[1]
        }
        // the mask goes on the full-width row, BEFORE the negative padding: negative padding draws past the view's frame
        // without growing it, so a mask after it clipped every panel at the page margins (builds 50-51)
        .mask {
            GeometryReader { geo in
                let f = margin / max(geo.size.width, 1)
                LinearGradient(stops: [.init(color: atStart ? .black : .clear, location: 0), .init(color: .black, location: f),
                                       .init(color: .black, location: 1 - f), .init(color: atEnd ? .black : .clear, location: 1)],
                               startPoint: .leading, endPoint: .trailing)
            }
            .padding(.vertical, -60)            // the focused panel's lift and shadow aren't cut off above / below
        }
        .padding(.horizontal, -margin)
        .animation(.easeInOut(duration: 0.25), value: atStart)
        .animation(.easeInOut(duration: 0.25), value: atEnd)
    }
}

struct MediaPanel: View {
    let entry: DashboardModel.MediaEntry
    @EnvironmentObject var model: AppModel
    var body: some View { MediaPanelBody(entry: entry, ha: model.ha) }
}

/// redraws when the player, its option selects or its toggles change - nothing else
struct MediaPanelBody: View {
    let entry: DashboardModel.MediaEntry
    let ha: HAConnection
    @StateObject private var watch: EntityGroup
    @EnvironmentObject var model: AppModel
    init(entry: DashboardModel.MediaEntry, ha: HAConnection) {
        self.entry = entry; self.ha = ha
        _watch = StateObject(wrappedValue: EntityGroup(([entry.entity] + entry.options + entry.toggles).map { ha.box($0) }))
    }
    @State private var open = false
    @Environment(\.havenTileFocus) private var tileFocus

    var body: some View {
        let e = ha.state(entry.entity)
        let st = e?.state ?? "unavailable"
        let title: String = e?.attr("media_title") ?? (e?.attr("app_name") ?? (e?.attr("source") ?? ""))
        let artist: String = e?.attr("media_artist") ?? (e?.attr("media_series_title") ?? tvModes(e))
        let playing = st == "playing"
        let line1 = title.isEmpty ? Look.stateText(e, domain: "media_player") : title
        let line2 = artist.isEmpty ? (title.isEmpty ? " " : Look.stateText(e, domain: "media_player")) : artist
        Button { playPause() } label: {
            HStack(spacing: 22) {
                CoverArt(picture: e?.attr("entity_picture") ?? "") {
                    RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.08))
                    Image(systemName: Icons.sf(entry.icon ?? "", domain: "media_player")).font(.system(size: 40)).foregroundStyle(.white.opacity(0.7))
                }
                .frame(width: 128, height: 128)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Text(entry.name ?? e?.name ?? entry.entity).font(.system(size: 19, weight: .semibold)).tracking(1.4).textCase(.uppercase)
                            .foregroundStyle(playing ? Look.color(nil, domain: "media_player") : Theme.muted)
                        if playing {
                            Image(systemName: "waveform").font(.system(size: 17, weight: .bold)).foregroundStyle(Look.color(nil, domain: "media_player"))
                                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: playing)
                                .transition(.scale(scale: 0.5).combined(with: .opacity))
                        }
                    }
                    ZStack(alignment: .leading) {
                        Text(line1).font(.system(size: 27, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                            .id("t-" + line1).transition(.songText)
                    }
                    ZStack(alignment: .leading) {
                        Text(line2).font(.system(size: 21)).foregroundStyle(Theme.muted).lineLimit(1)
                            .id("s-" + line2).transition(.songText)
                    }
                }
                .frame(width: 330, alignment: .leading)
                .animation(.easeInOut(duration: 0.4), value: line1)
                .animation(.easeInOut(duration: 0.4), value: line2)
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: playing)
            }
            .padding(20)
        }
        .glassButton("media:\(entry.entity)", tint: Look.color(nil, domain: "media_player"), on: playing)
        .contextMenu { menu(e) }
        .fullScreenCover(isPresented: $open) {
            MediaPlayerView(entry: entry, ha: ha, close: {
                open = false
                // back on this panel (tvOS would pick the nearest tile)
                let id = "media:\(entry.entity)"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { tileFocus?.wrappedValue = id }
            }).environmentObject(model)
        }
        .onChange(of: model.screen) { _, s in if s != .dashboard { open = false } }   // idle: the aerials, not this
    }

    @ViewBuilder private func menu(_ e: EntityState?) -> some View {
        Button { model.touch(); open = true } label: { Label("Open player", systemImage: "arrow.up.left.and.arrow.down.right") }
        Button { svc("media_next_track") } label: { Label("Next", systemImage: "forward.fill") }
        Button { svc("media_previous_track") } label: { Label("Previous", systemImage: "backward.fill") }
        Button { svc("volume_up") } label: { Label("Volume up", systemImage: "speaker.plus.fill") }
        Button { svc("volume_down") } label: { Label("Volume down", systemImage: "speaker.minus.fill") }
        let sources: [String] = e?.attr("source_list") ?? []
        if !sources.isEmpty {
            Menu("Open / Source") {
                ForEach(sources, id: \.self) { s in Button(s) { svc("select_source", ["source": s]) } }
            }
        }
        ForEach(entry.options, id: \.self) { sel in
            let o = ha.state(sel)
            let opts: [String] = o?.attr("options") ?? []
            if !opts.isEmpty {
                Menu("\(o?.name ?? sel): \(o?.state ?? "")") {
                    ForEach(opts, id: \.self) { v in
                        Button(v) { Task { await ha.call("select", "select_option", data: ["option": v], target: ["entity_id": sel]) } }
                    }
                }
            }
        }
        ForEach(entry.toggles, id: \.self) { t in
            let o = ha.state(t)
            Button { Task { await ha.call("homeassistant", "toggle", target: ["entity_id": t]) } } label: {
                Label("\(o?.name ?? t): \(o?.state == "on" ? "On" : "Off")", systemImage: "power")
            }
        }
        Button { svc("toggle") } label: { Label(e?.state == "off" ? "Turn on" : "Turn off", systemImage: "power") }
    }

    /// a TV's picture + sound modes, each named: "Filmmaker picture · Cinema sound"
    private func tvModes(_ e: EntityState?) -> String {
        let pic = entry.options.first { $0.contains("picture") }.flatMap { ha.state($0)?.state }.flatMap { ["unknown", "unavailable"].contains($0) ? nil : $0 }
        let snd: String = e?.attr("sound_mode") ?? ""
        return [pic.map { "\($0) picture" }, snd.isEmpty ? nil : "\(snd) sound"].compactMap { $0 }.joined(separator: " · ")
    }

    private func playPause() {
        model.touch()
        guard model.pressesOK else { return }
        let st = ha.state(entry.entity)?.state ?? ""
        svc(st == "off" || st == "standby" ? "turn_on" : "media_play_pause")
    }
    private func svc(_ s: String, _ data: [String: Any] = [:]) {
        Log.shared.add("dashboard: media_player.\(s) \(entry.entity)")
        Task { await ha.call("media_player", s, data: data, target: ["entity_id": entry.entity]) }
    }
}

// MARK: - weather

struct WeatherCard: View {
    let entity: String
    @EnvironmentObject var ha: HAConnection
    @State private var days: [[String: Any]] = []
    @State private var sub: Int?
    @State private var open = false
    @EnvironmentObject var model: AppModel
    @Environment(\.havenTileFocus) private var tileFocus

    var body: some View {
        let e = ha.state(entity)
        let t = (e?.attributes["temperature"] as? NSNumber)?.doubleValue
        let h = (e?.attributes["humidity"] as? NSNumber)?.doubleValue
        Button { model.touch(); if model.pressesOK { open = true } } label: {
            HStack(spacing: 46) {
                HStack(spacing: 22) {
                    Image(systemName: InfoChips.weatherSymbol(e?.state ?? "")).symbolRenderingMode(.multicolor).font(.system(size: 64))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(t.map { "\(Int($0.rounded()))°" } ?? "—").font(.system(size: 64, weight: .light, design: .rounded)).foregroundStyle(Theme.text)
                        Text("\((e?.state ?? "").replacingOccurrences(of: "partlycloudy", with: "partly cloudy").replacingOccurrences(of: "-", with: " ").capitalized)\(h.map { " · \(Int($0))%" } ?? "")")
                            .font(.system(size: 21)).foregroundStyle(Theme.muted)
                    }
                }
                Spacer(minLength: 0)
                ForEach(Array(days.prefix(6).enumerated()), id: \.offset) { _, d in
                    VStack(spacing: 10) {
                        Text(Self.day(d["datetime"] as? String)).font(.system(size: 19, weight: .semibold)).foregroundStyle(Theme.muted)
                        Image(systemName: InfoChips.weatherSymbol((d["condition"] as? String ?? "").replacingOccurrences(of: "clear-night", with: "sunny"))).symbolRenderingMode(.multicolor).font(.system(size: 34))
                        Text("\((d["temperature"] as? NSNumber).map { "\(Int($0.doubleValue.rounded()))°" } ?? "")")
                            .font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.text)
                        Text("\((d["templow"] as? NSNumber).map { "\(Int($0.doubleValue.rounded()))°" } ?? "")")
                            .font(.system(size: 19)).foregroundStyle(Theme.faint)
                    }
                    .frame(width: 92)
                    .transition(.opacity)
                }
            }
            .padding(34)
            .animation(.easeInOut(duration: 0.5), value: days.count)
        }
        .glassButton("weather:\(entity)", radius: 34)
        .fullScreenCover(isPresented: $open) { WeatherDetailView(entity: entity, days: days, close: {
            open = false
            let id = "weather:\(entity)"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { tileFocus?.wrappedValue = id }
        }).environmentObject(ha).environmentObject(model) }
        .onAppear(perform: subscribe)
        .onChange(of: model.screen) { _, s in if s != .dashboard { open = false } }   // idle: the aerials, not this
        .onDisappear { if let s = sub { ha.unsubscribe(s) }; sub = nil }
        .onChange(of: ha.status) { _, s in if s == .connected { sub = nil; subscribe() } }   // a reconnect drops subscriptions
    }

    private func subscribe() {
        guard sub == nil, ha.status == .connected else { return }
        sub = ha.subscribe(["type": "weather/subscribe_forecast", "entity_id": entity, "forecast_type": "daily"]) { ev in
            days = ev["forecast"] as? [[String: Any]] ?? []
        }
    }
    static func day(_ iso: String?) -> String {
        guard let iso, let d = ISO8601DateFormatter().date(from: iso) else { return "" }
        return Calendar.current.isDateInToday(d) ? "Today" : d.formatted(.dateTime.weekday(.abbreviated))
    }
}

// MARK: - to-do (the missed calls)

struct TodoCard: View {
    let entity: String, title: String?
    @EnvironmentObject var ha: HAConnection
    @EnvironmentObject var model: AppModel
    @State private var items: [[String: Any]] = []

    var body: some View {
        let open = items.filter { ($0["status"] as? String) == "needs_action" }
        VStack(alignment: .leading, spacing: 18) {
            Text((title ?? ha.state(entity)?.name ?? "To-do").uppercased()).font(.system(size: 20, weight: .semibold)).tracking(2)
                .foregroundStyle(Color(red: 1, green: 0.55, blue: 0.52))
            // keyed by the item, so the one marked done is the one that leaves
            ForEach(open.map { (key: ($0["uid"] as? String) ?? ($0["summary"] as? String ?? ""), it: $0) }, id: \.key) { row in
                let it = row.it
                Button { done(it) } label: {
                    HStack(spacing: 18) {
                        Image(systemName: "phone.down.fill").foregroundStyle(Color(red: 1, green: 0.45, blue: 0.42))
                        Text(it["summary"] as? String ?? "").font(.system(size: 25, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                        Spacer()
                        Text(it["description"] as? String ?? "").font(.system(size: 21)).foregroundStyle(Theme.muted).lineLimit(1)
                        Image(systemName: "checkmark.circle").foregroundStyle(Theme.faint)
                    }
                    .padding(.horizontal, 26).frame(height: 84)
                }
                .glassButton("todo:\(it["uid"] as? String ?? (it["summary"] as? String ?? ""))", radius: 24)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -10)), removal: .opacity.combined(with: .scale(scale: 0.96))))
            }
        }
        .animation(Theme.soft, value: open.map { $0["uid"] as? String ?? "" })
        .task(id: ha.state(entity)?.lastUpdated ?? 0) { await load() }
    }

    private func load() async {
        let r = try? await ha.command(["type": "todo/item/list", "entity_id": entity]) as? [String: Any]
        items = r?["items"] as? [[String: Any]] ?? []
    }
    private func done(_ it: [String: Any]) {
        model.touch()
        guard let uid = it["uid"] as? String, model.pressesOK else { return }
        Log.shared.add("dashboard: missed call marked done")
        Task {
            await ha.call("todo", "update_item", data: ["item": uid, "status": "completed"], target: ["entity_id": entity])
            await load()
        }
    }
}

// MARK: - icons (Home Assistant's mdi: names -> SF Symbols)

enum Icons {
    static let mdi: [String: String] = [
        "home": "house.fill", "television": "tv", "lightbulb": "lightbulb.fill", "lightbulb-group": "lightbulb.2.fill",
        "spotify": "music.note", "apple": "appletv.fill", "speaker": "hifispeaker.fill", "air-conditioner": "air.conditioner.horizontal.fill",
        "fan": "fan.fill", "thermometer": "thermometer.medium", "water-percent": "humidity.fill", "sleep": "moon.zzz.fill",
        "power": "power", "microphone-off": "mic.slash.fill", "microphone": "mic.fill", "palette": "paintpalette.fill",
        "monitor-off": "display", "weather-partly-cloudy": "cloud.sun.fill", "television-ambient-light": "sparkles.tv",
        "message-text-outline": "text.bubble", "television-guide": "rectangle.on.rectangle", "bell-ring-outline": "bell.badge",
        "cellphone-message": "iphone.radiowaves.left.and.right", "air-filter": "aqi.medium", "air-purifier": "air.purifier.fill",
        "heart-pulse": "heart.text.square", "sofa": "sofa.fill", "desk": "desktopcomputer", "led-strip-variant": "light.strip.2.fill",
    ]

    static func sf(_ icon: String, domain: String, deviceClass: String? = nil, state: String = "") -> String {
        if icon.hasPrefix("mdi:"), let s = mdi[String(icon.dropFirst(4))] { return s }
        switch domain {
        case "light": return "lightbulb.fill"
        case "script": return "play.circle.fill"
        case "scene": return "sparkles"
        case "button", "input_button": return "button.programmable"
        case "switch", "input_boolean": return state == "on" ? "switch.2" : "switch.2"
        case "fan": return "fan.fill"
        case "humidifier": return "humidifier.and.droplets.fill"
        case "climate": return "thermometer.medium"
        case "media_player": return "play.rectangle.fill"
        case "lock": return state == "locked" ? "lock.fill" : "lock.open.fill"
        case "binary_sensor":
            switch deviceClass ?? "" {
            case "occupancy", "motion", "presence": return state == "on" ? "figure.stand" : "figure.stand.line.dotted.figure.stand"
            case "door": return "door.left.hand.closed"
            case "window": return "window.vertical.closed"
            default: return "circle.dotted"
            }
        case "sensor":
            switch deviceClass ?? "" {
            case "temperature": return "thermometer.medium"
            case "humidity": return "humidity.fill"
            case "illuminance": return "sun.max.fill"
            case "pm25", "pm10", "aqi": return "aqi.medium"
            case "energy", "power", "current": return "bolt.fill"
            default: return "gauge.with.dots.needle.33percent"
            }
        default: return "circle.grid.2x2.fill"
        }
    }
}


// MARK: - full-screen views (standard bordered buttons: tvOS gives them the focus as the view opens, and they read on
// anything - focused they turn white with a dark symbol, the tvOS player look)

/// The AC opened up (Select on its card): the room and the target temperature, then each setting it has as a row of
/// choices with the current one lit - mode (Off is one of them), fan speed, the up / down and the left / right vanes.
/// A choice shows at once and is confirmed by Home Assistant a moment later (it goes back if it never is). Back or Done
/// closes it; it opens on the current mode, so a stray Select changes nothing.
struct ClimateView: View {
    let entity: String
    let ha: HAConnection
    let close: () -> Void
    @StateObject private var watch: EntityGroup
    @EnvironmentObject var model: AppModel
    @FocusState private var focus: String?
    @State private var shown = false
    @State private var pending: [String: String] = [:]          // attribute -> what was just chosen
    @State private var pendingTarget: Double?
    @State private var targetSend: Task<Void, Never>?
    init(entity: String, ha: HAConnection, close: @escaping () -> Void) {
        self.entity = entity; self.ha = ha; self.close = close
        _watch = StateObject(wrappedValue: EntityGroup([ha.box(entity)]))
    }

    struct Row: Identifiable {
        let key: String, title: String, service: String, field: String, options: [String]
        var id: String { key }
    }

    var body: some View {
        let e = ha.state(entity)
        let a = e?.attributes ?? [:]
        let num = { (k: String) -> Double? in (a[k] as? NSNumber)?.doubleValue }
        let mode = value("hvac_mode", e)
        let on = mode != "off"
        let cur = num("current_temperature")
        let target = pendingTarget ?? num("temperature")
        let tint = Look.color(nil, domain: "climate")
        ZStack {
            Theme.backdrop.ignoresSafeArea()
            RadialGradient(colors: [tint.opacity(on ? 0.20 : 0), .clear], center: .topLeading, startRadius: 0, endRadius: 1200)
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 34) {
                HStack(alignment: .center, spacing: 56) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text((e?.name ?? "Air conditioner").uppercased()).font(.system(size: 24, weight: .semibold)).tracking(2).foregroundStyle(tint)
                        HStack(alignment: .firstTextBaseline, spacing: 16) {
                            Text(cur.map { "\(ThermostatBody.fmt($0))°" } ?? "—").font(.system(size: 120, weight: .thin, design: .rounded))
                                .foregroundStyle(Theme.text).contentTransition(.numericText(value: cur ?? 0))
                            Text("in the room").font(.system(size: 28, weight: .medium)).foregroundStyle(Theme.muted)
                        }
                        Text(Self.status(mode, target)).font(.system(size: 30, weight: .medium)).foregroundStyle(on ? tint : Theme.muted)
                            .contentTransition(.opacity)
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 34) {
                        Button { nudge(-1, a) } label: { Image(systemName: "minus").font(.system(size: 34, weight: .bold)).frame(width: 84, height: 84) }
                            .focused($focus, equals: "minus")
                        VStack(spacing: 0) {
                            Text(target.map { "\(ThermostatBody.fmt($0))°" } ?? "—").font(.system(size: 96, weight: .light, design: .rounded))
                                .monospacedDigit().foregroundStyle(Theme.text).contentTransition(.numericText(value: target ?? 0))
                            Text("TARGET").font(.system(size: 18, weight: .semibold)).tracking(2.4).foregroundStyle(Theme.muted)
                        }
                        .frame(minWidth: 210)
                        Button { nudge(1, a) } label: { Image(systemName: "plus").font(.system(size: 34, weight: .bold)).frame(width: 84, height: 84) }
                            .focused($focus, equals: "plus")
                    }
                    .buttonStyle(.bordered).buttonBorderShape(.circle)
                    .opacity(on ? 1 : 0.5)
                    Button("Done", action: close).buttonStyle(.bordered).focused($focus, equals: "done")
                }
                ForEach(rows(a)) { r in
                    let live = r.key == "hvac_mode" || on
                    VStack(alignment: .leading, spacing: 14) {
                        Text(r.title.uppercased()).font(.system(size: 19, weight: .semibold)).tracking(2.2).foregroundStyle(Theme.muted)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 16) {
                                ForEach(r.options, id: \.self) { o in
                                    let id = "\(r.key):\(o)"
                                    Button { choose(r, o, e) } label: {
                                        HStack(spacing: 10) {
                                            if r.key == "hvac_mode" { Image(systemName: Self.modeSymbol(o)).font(.system(size: 22, weight: .semibold)) }
                                            Text(ThermostatBody.pretty(o)).font(.system(size: 23, weight: .semibold)).lineLimit(1)
                                        }
                                        .padding(.horizontal, 26).frame(height: 64)
                                    }
                                    .buttonStyle(ChipStyle(selected: value(r.key, e) == o, focused: focus == id, tint: tint))
                                    .focused($focus, equals: id)
                                }
                            }
                            .padding(.vertical, 14)
                        }
                        .scrollClipDisabled()
                        .padding(.vertical, -14)
                    }
                    .disabled(!live)
                    .opacity(live ? 1 : 0.4)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 90).padding(.vertical, 60)
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 28)
        }
        .animation(.easeInOut(duration: 0.35), value: mode)
        .animation(.easeInOut(duration: 0.3), value: target)
        .animation(.easeInOut(duration: 0.3), value: cur)
        .onExitCommand(perform: close)
        .defaultFocus($focus, "hvac_mode:\(e?.state ?? "off")")
        .onAppear {
            withAnimation(.smooth(duration: 0.5)) { shown = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { focus = "hvac_mode:\(e?.state ?? "off")" }
        }
        .onChange(of: snapshot(e)) { _, _ in
            // confirmed by Home Assistant: no longer pending
            for (k, v) in pending where actual(k, ha.state(entity)) == v { pending[k] = nil }
            if let t = pendingTarget, (ha.state(entity)?.attributes["temperature"] as? NSNumber)?.doubleValue == t { pendingTarget = nil }
        }
        .onChange(of: focus) { _, f in if let f { model.touch(); FocusLog.note("climate " + f) } }
    }

    private func rows(_ a: [String: Any]) -> [Row] {
        let list = { (k: String) -> [String] in a[k] as? [String] ?? [] }
        return [Row(key: "hvac_mode", title: "Mode", service: "set_hvac_mode", field: "hvac_mode", options: list("hvac_modes")),
                Row(key: "fan_mode", title: "Fan speed", service: "set_fan_mode", field: "fan_mode", options: list("fan_modes")),
                Row(key: "swing_mode", title: "Up / down", service: "set_swing_mode", field: "swing_mode", options: list("swing_modes")),
                Row(key: "swing_horizontal_mode", title: "Left / right", service: "set_swing_horizontal_mode", field: "swing_horizontal_mode",
                    options: list("swing_horizontal_modes"))]
            .filter { !$0.options.isEmpty }
    }
    private func actual(_ key: String, _ e: EntityState?) -> String {
        key == "hvac_mode" ? (e?.state ?? "off") : (e?.attr(key) ?? "")
    }
    private func value(_ key: String, _ e: EntityState?) -> String { pending[key] ?? actual(key, e) }
    private func snapshot(_ e: EntityState?) -> [String] {
        ["hvac_mode", "fan_mode", "swing_mode", "swing_horizontal_mode"].map { actual($0, e) }
            + [(e?.attributes["temperature"] as? NSNumber).map { "\($0.doubleValue)" } ?? ""]
    }

    private func choose(_ r: Row, _ o: String, _ e: EntityState?) {
        model.touch()
        guard model.pressesOK, value(r.key, e) != o else { return }
        withAnimation(.easeInOut(duration: 0.25)) { pending[r.key] = o }
        Log.shared.add("climate: \(r.service) \(o) \(entity)")
        Task {
            let ok = await ha.call("climate", r.service, data: [r.field: o], target: ["entity_id": entity])
            if !ok { withAnimation { if pending[r.key] == o { pending[r.key] = nil } } }
        }
        // never confirmed (the AC didn't take it): back to what Home Assistant says
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { withAnimation { if pending[r.key] == o { pending[r.key] = nil } } }
    }

    /// minus / plus: shown at once, sent once the presses stop (three quick presses = one change of three steps)
    private func nudge(_ dir: Double, _ a: [String: Any]) {
        model.touch()
        guard model.pressesOK, let base = pendingTarget ?? (a["temperature"] as? NSNumber)?.doubleValue else { return }
        let step = (a["target_temp_step"] as? NSNumber)?.doubleValue ?? 1
        let lo = (a["min_temp"] as? NSNumber)?.doubleValue ?? 16, hi = (a["max_temp"] as? NSNumber)?.doubleValue ?? 30
        let t = min(hi, max(lo, base + dir * step))
        pendingTarget = t
        targetSend?.cancel()
        targetSend = Task {
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled else { return }
            Log.shared.add("climate: set_temperature \(t) \(entity)")
            await ha.call("climate", "set_temperature", data: ["temperature": t], target: ["entity_id": entity])
            try? await Task.sleep(for: .seconds(10))
            if pendingTarget == t { withAnimation { pendingTarget = nil } }
        }
    }

    static func status(_ mode: String, _ target: Double?) -> String {
        let t = target.map { "\(ThermostatBody.fmt($0))°" } ?? "—"
        switch mode {
        case "off": return "Off"
        case "cool": return "Cooling to \(t)"
        case "heat": return "Heating to \(t)"
        case "dry": return "Drying · \(t)"
        case "fan_only": return "Fan only"
        case "auto", "heat_cool": return "Auto · \(t)"
        default: return "\(ThermostatBody.pretty(mode)) · \(t)"
        }
    }
    static func modeSymbol(_ m: String) -> String {
        switch m {
        case "off": return "power"
        case "cool": return "snowflake"
        case "heat": return "sun.max.fill"
        case "dry": return "drop.fill"
        case "fan_only": return "fan.fill"
        case "auto", "heat_cool": return "arrow.triangle.2.circlepath"
        default: return "circle"
        }
    }
}

/// a choice in a row (the AC's settings): lit in the AC's color when it's the current one; focused it turns white with
/// dark text and lifts - the tvOS look. The focus is handed in (isFocused doesn't reliably reach a ButtonStyle here).
struct ChipStyle: ButtonStyle {
    let selected: Bool, focused: Bool, tint: Color
    func makeBody(configuration: Configuration) -> some View {
        let shape = Capsule()
        configuration.label
            .foregroundStyle(focused ? (selected ? tint.mix(with: .black, by: 0.35) : Color.black.opacity(0.85)) : .white.opacity(selected ? 1 : 0.85))
            .background {
                ZStack {
                    shape.fill(.white.opacity(0.08))
                    if selected { shape.fill(tint.opacity(0.38)) }
                    if focused { shape.fill(.white.opacity(0.96)) }
                }
            }
            .overlay(shape.strokeBorder(selected && !focused ? tint.opacity(0.85) : .white.opacity(focused ? 0 : 0.12), lineWidth: selected ? 2 : 1))
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 20, weight: .bold)).foregroundStyle(.white, tint)
                        .offset(x: 6, y: -6).transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
            .scaleEffect(configuration.isPressed && focused ? 0.96 : (focused ? 1.08 : 1))
            .shadow(color: .black.opacity(focused ? 0.45 : 0), radius: 18, y: 10)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: focused)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: selected)
            .animation(.spring(response: 0.2, dampingFraction: 0.9), value: configuration.isPressed)
    }
}

/// a media panel opened up: big artwork, what's playing, the controls - Back or Done closes it
struct MediaPlayerView: View {
    let entry: DashboardModel.MediaEntry
    let ha: HAConnection
    let close: () -> Void
    @StateObject private var watch: EntityGroup
    @EnvironmentObject var model: AppModel
    @FocusState private var onPlay: Bool
    @State private var shown = false
    init(entry: DashboardModel.MediaEntry, ha: HAConnection, close: @escaping () -> Void) {
        self.entry = entry; self.ha = ha; self.close = close
        _watch = StateObject(wrappedValue: EntityGroup([ha.box(entry.entity)]))
    }

    var body: some View {
        let e = ha.state(entry.entity)
        let st = e?.state ?? "unavailable"
        let title: String = e?.attr("media_title") ?? (e?.attr("app_name") ?? (e?.attr("source") ?? Look.stateText(e, domain: "media_player")))
        let artist: String = e?.attr("media_artist") ?? (e?.attr("media_series_title") ?? "")
        let album: String = e?.attr("media_album_name") ?? ""
        let vol = (e?.attributes["volume_level"] as? NSNumber)?.doubleValue
        let pic: String = e?.attr("entity_picture") ?? ""
        ZStack {
            Theme.backdrop.ignoresSafeArea()
            CoverArt(picture: pic, fade: 0.9) { Color.clear }.blur(radius: 80).opacity(0.45).ignoresSafeArea()
            HStack(spacing: 80) {
                CoverArt(picture: pic) {
                    RoundedRectangle(cornerRadius: 36, style: .continuous).fill(.white.opacity(0.08))
                    Image(systemName: Icons.sf(entry.icon ?? "", domain: "media_player")).font(.system(size: 120)).foregroundStyle(.white.opacity(0.7))
                }
                .frame(width: 560, height: 560)
                .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
                .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
                .scaleEffect(st == "playing" || !shown ? 1 : 0.94)
                .animation(.spring(response: 0.5, dampingFraction: 0.75), value: st)
                VStack(alignment: .leading, spacing: 18) {
                    Text(entry.name ?? e?.name ?? entry.entity).font(.system(size: 24, weight: .semibold)).tracking(2).textCase(.uppercase)
                        .foregroundStyle(Look.color(nil, domain: "media_player"))
                    // what's playing: a new song's words cross over the old ones (one block, so nothing below jumps)
                    ZStack(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 18) {
                            Text(title).font(.system(size: 60, weight: .bold)).foregroundStyle(Theme.text).lineLimit(2)
                            if !artist.isEmpty { Text(artist).font(.system(size: 34, weight: .medium)).foregroundStyle(Theme.text.opacity(0.8)).lineLimit(1) }
                            if !album.isEmpty { Text(album).font(.system(size: 26)).foregroundStyle(Theme.muted).lineLimit(1) }
                        }
                        .id(title + "|" + artist + "|" + album)
                        .transition(.songText)
                    }
                    .animation(.easeInOut(duration: 0.45), value: title + "|" + artist + "|" + album)
                    HStack(spacing: 30) {
                        Button { svc("media_previous_track") } label: { Image(systemName: "backward.fill").font(.system(size: 34)).frame(width: 70, height: 70) }
                        Button { svc(st == "off" || st == "standby" ? "turn_on" : "media_play_pause") } label: {
                            Image(systemName: st == "playing" ? "pause.fill" : "play.fill").font(.system(size: 44)).frame(width: 96, height: 96)
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .focused($onPlay)
                        Button { svc("media_next_track") } label: { Image(systemName: "forward.fill").font(.system(size: 34)).frame(width: 70, height: 70) }
                        Spacer().frame(width: 24)
                        Button { svc("volume_down") } label: { Image(systemName: "speaker.minus.fill").font(.system(size: 28)).frame(width: 64, height: 64) }
                        Button { svc("volume_up") } label: { Image(systemName: "speaker.plus.fill").font(.system(size: 28)).frame(width: 64, height: 64) }
                    }
                    .buttonStyle(.bordered).buttonBorderShape(.circle)
                    .padding(.top, 30)
                    if let vol { Text("Volume \(Int((vol * 100).rounded()))%").font(.system(size: 22)).foregroundStyle(Theme.muted) }
                    Button("Done", action: close).buttonStyle(.bordered).padding(.top, 20)
                }
                .frame(maxWidth: 900, alignment: .leading)
            }
            .padding(90)
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 28)
        }
        .onExitCommand(perform: close)
        .defaultFocus($onPlay, true)
        .onAppear {
            withAnimation(.smooth(duration: 0.5)) { shown = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { onPlay = true }
        }
    }

    private func svc(_ s: String) {
        model.touch()
        Log.shared.add("player: media_player.\(s) \(entry.entity)")
        Task { await ha.call("media_player", s, target: ["entity_id": entry.entity]) }
    }
}

/// the weather card opened up: now (whatever the weather source reports), the next hours, the coming days
struct WeatherDetailView: View {
    let entity: String
    let days: [[String: Any]]
    let close: () -> Void
    @EnvironmentObject var ha: HAConnection
    @State private var hours: [[String: Any]] = []
    @State private var sub: Int?
    @State private var shown = false

    var body: some View {
        let e = ha.state(entity)
        let a = e?.attributes ?? [:]
        let facts = Self.facts(a)
        let num = { (k: String) -> Double? in (a[k] as? NSNumber)?.doubleValue }
        ZStack {
            Theme.backdrop.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 46) {
                HStack(alignment: .center, spacing: 34) {
                    Image(systemName: InfoChips.weatherSymbol(e?.state ?? "")).symbolRenderingMode(.multicolor).font(.system(size: 110))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(num("temperature").map { "\(Int($0.rounded()))°" } ?? "—").font(.system(size: 110, weight: .thin, design: .rounded)).foregroundStyle(Theme.text)
                        Text(Self.condition(e?.state ?? "")).font(.system(size: 32, weight: .medium)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Button("Done", action: close).buttonStyle(.bordered)
                }
                // now
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 24), count: 4), alignment: .leading, spacing: 24) {
                    ForEach(facts, id: \.1) { f in
                        HStack(spacing: 16) {
                            Image(systemName: f.0).font(.system(size: 26)).foregroundStyle(Theme.muted).frame(width: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.1).font(.system(size: 19, weight: .semibold)).foregroundStyle(Theme.muted)
                                Text(f.2).font(.system(size: 28, weight: .semibold)).foregroundStyle(Theme.text)
                            }
                        }
                    }
                }
                // the next hours
                if !hours.isEmpty {
                    HStack(spacing: 0) {
                        ForEach(Array(hours.prefix(12).enumerated()), id: \.offset) { _, h in
                            VStack(spacing: 12) {
                                Text(Self.hour(h["datetime"] as? String)).font(.system(size: 19, weight: .semibold)).foregroundStyle(Theme.muted)
                                Image(systemName: InfoChips.weatherSymbol(Self.byHour(h["condition"] as? String ?? "", h["datetime"] as? String))).symbolRenderingMode(.multicolor).font(.system(size: 32))
                                Text((h["temperature"] as? NSNumber).map { "\(Int($0.doubleValue.rounded()))°" } ?? "").font(.system(size: 24, weight: .semibold)).foregroundStyle(Theme.text)
                                Text((h["precipitation_probability"] as? NSNumber).map { $0.intValue > 0 ? "\($0.intValue)%" : " " } ?? " ")
                                    .font(.system(size: 17)).foregroundStyle(Color(red: 0.45, green: 0.75, blue: 1))
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.vertical, 24)
                    .background(RoundedRectangle(cornerRadius: 30, style: .continuous).fill(.white.opacity(0.05)))
                    .transition(.opacity.combined(with: .offset(y: 12)))
                }
                // the coming days
                HStack(spacing: 0) {
                    ForEach(Array(days.prefix(7).enumerated()), id: \.offset) { _, d in
                        VStack(spacing: 12) {
                            Text(WeatherCard.day(d["datetime"] as? String)).font(.system(size: 21, weight: .semibold)).foregroundStyle(Theme.muted)
                            Image(systemName: InfoChips.weatherSymbol((d["condition"] as? String ?? "").replacingOccurrences(of: "clear-night", with: "sunny")))
                                .symbolRenderingMode(.multicolor).font(.system(size: 38))
                            Text((d["temperature"] as? NSNumber).map { "\(Int($0.doubleValue.rounded()))°" } ?? "").font(.system(size: 28, weight: .semibold)).foregroundStyle(Theme.text)
                            Text((d["templow"] as? NSNumber).map { "\(Int($0.doubleValue.rounded()))°" } ?? "").font(.system(size: 22)).foregroundStyle(Theme.faint)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 24)
                .background(RoundedRectangle(cornerRadius: 30, style: .continuous).fill(.white.opacity(0.05)))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 90).padding(.vertical, 60)
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 28)
            .animation(.easeInOut(duration: 0.4), value: hours.isEmpty)
        }
        .onExitCommand(perform: close)
        .onAppear {
            withAnimation(.smooth(duration: 0.5)) { shown = true }
            guard sub == nil else { return }
            sub = ha.subscribe(["type": "weather/subscribe_forecast", "entity_id": entity, "forecast_type": "hourly"]) { ev in
                hours = ev["forecast"] as? [[String: Any]] ?? []
            }
        }
        .onDisappear { if let s = sub { ha.unsubscribe(s) }; sub = nil }
    }

    /// what the weather source reports right now, as (symbol, name, value) - only the ones it has
    static func facts(_ a: [String: Any]) -> [(String, String, String)] {
        func num(_ k: String) -> Double? { (a[k] as? NSNumber)?.doubleValue }
        func unit(_ k: String) -> String { a[k] as? String ?? "" }
        func whole(_ v: Double) -> String { String(Int(v.rounded())) }
        var out: [(String, String, String)] = []
        if let v = num("apparent_temperature") { out.append(("thermometer.medium", "Feels like", whole(v) + "°")) }
        if let v = num("humidity") { out.append(("humidity.fill", "Humidity", whole(v) + "%")) }
        if let v = num("dew_point") { out.append(("drop.degreesign", "Dew point", whole(v) + "°")) }
        if let v = num("wind_speed") {
            let dir: String = compass(num("wind_bearing"))
            out.append(("wind", "Wind", whole(v) + " " + unit("wind_speed_unit") + dir))
        }
        if let v = num("pressure") { out.append(("gauge.with.dots.needle.50percent", "Pressure", whole(v) + " " + unit("pressure_unit"))) }
        if let v = num("uv_index") { out.append(("sun.max.fill", "UV index", String(format: "%.0f", v))) }
        if let v = num("cloud_coverage") { out.append(("cloud.fill", "Clouds", whole(v) + "%")) }
        if let v = num("visibility") { out.append(("eye.fill", "Visibility", whole(v) + " " + unit("visibility_unit"))) }
        return out
    }
    static func condition(_ s: String) -> String {
        s.replacingOccurrences(of: "partlycloudy", with: "partly cloudy").replacingOccurrences(of: "clear-night", with: "clear")
            .replacingOccurrences(of: "-", with: " ").capitalized
    }
    /// sun or moon by the hour itself (the source called every hour "clear-night" before sunrise)
    static func byHour(_ condition: String, _ iso: String?) -> String {
        guard let iso, let d = ISO8601DateFormatter().date(from: iso) else { return condition }
        let h = Calendar.current.component(.hour, from: d)
        let day = (6..<18).contains(h)
        if day && condition == "clear-night" { return "sunny" }
        if !day && condition == "sunny" { return "clear-night" }
        return condition
    }
    static func hour(_ iso: String?) -> String {
        guard let iso, let d = ISO8601DateFormatter().date(from: iso) else { return "" }
        return d.formatted(.dateTime.hour())
    }
    static func compass(_ deg: Double?) -> String {
        guard let deg else { return "" }
        let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        return " " + names[Int((deg / 45).rounded()) % 8]
    }
}
