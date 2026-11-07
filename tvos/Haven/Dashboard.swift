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
    @EnvironmentObject var ha: HAConnection
    @ObservedObject var dash: DashboardModel
    @FocusState private var focus: String?
    @State private var lastFocus: String?

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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            focus = lastFocus ?? firstTile ?? "__home"   // where you were, else the first tile
            model.refocus()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {   // that control is gone (a to-do done...): the first tile
            if focus == nil, model.screen == .dashboard { focus = firstTile ?? "__home" }
        }
    }

    var body: some View {
        ZStack {
            Theme.backdrop
            ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                DashboardContent(dash: dash)
            }
            .environment(\.havenTileFocus, $focus)
            .defaultFocus($focus, firstTile ?? "__home")
            .onChange(of: dash.scrollTarget) { _, i in
                guard let i, i >= 0, i < dash.sections.count else { return }
                withAnimation(.easeInOut(duration: 0.5)) { proxy.scrollTo(dash.sections[i].id, anchor: .top) }
            }
            }
        }
        .onAppear { Task { await dash.load() }; focusFirst() }
        .onChange(of: focus) { _, f in
            if let f, f != "__home" { lastFocus = f }
            Log.shared.add("focus: \(f ?? "nothing")")
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
}

struct DashTopBar: View {
    @EnvironmentObject var ha: HAConnection
    @EnvironmentObject var model: AppModel
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            HStack(alignment: .firstTextBaseline) {
                // a real button that's there from the first frame, so tvOS always has somewhere to put the focus
                Button { model.touch(); model.screen = .ambient } label: {
                    Text("Home").font(.system(size: 54, weight: .semibold, design: .rounded)).tracking(-0.8).foregroundStyle(Theme.text)
                        .padding(.horizontal, 18).padding(.vertical, 6)
                }
                .buttonStyle(.plain).focusEffectDisabled()
                .modifier(TileFocus(id: "__home"))
                .padding(.leading, -18)
                Spacer()
                if ha.status != .connected {
                    Label("Reconnecting", systemImage: "wifi.exclamationmark").font(.system(size: 22, weight: .medium)).foregroundStyle(Theme.warn)
                        .padding(.trailing, 24)
                }
                Text(ctx.date, format: .dateTime.weekday(.wide).hour().minute())
                    .font(.system(size: 26, weight: .medium)).monospacedDigit().foregroundStyle(Theme.muted)
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
                .scaleEffect(configuration.isPressed ? 0.97 : (focused ? 1.06 : 1))
                .shadow(color: .black.opacity(focused ? 0.55 : 0.3), radius: focused ? 36 : 16, y: focused ? 22 : 8)
                .animation(.spring(response: 0.32, dampingFraction: 0.78), value: focused)
                .animation(.spring(response: 0.2, dampingFraction: 0.9), value: configuration.isPressed)
        }
    }
}

// MARK: - tiles

struct TileView: View {
    let tile: DashboardModel.Tile
    @EnvironmentObject var ha: HAConnection
    @EnvironmentObject var model: AppModel
    @Environment(\.havenFirstTile) private var firstTile

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
                }
                .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(tile.name ?? e?.name ?? tile.entity).font(.system(size: 25, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                        .minimumScaleFactor(0.78)
                    if !tile.hideState {
                        Text(Look.stateText(e, domain: domain)).font(.system(size: 21)).foregroundStyle(Theme.muted).lineLimit(1)
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
        .contextMenu {
            let ms = modes(e, domain)
            ForEach(ms, id: \.self) { m in
                Button { setMode(m, domain) } label: {
                    if m == currentMode(e, domain) { Label(m.capitalized, systemImage: "checkmark") } else { Text(m.capitalized) }
                }
            }
        }
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
    @EnvironmentObject var ha: HAConnection
    @EnvironmentObject var model: AppModel

    var body: some View {
        let e = ha.state(entity)
        let cur: Double? = (e?.attributes["current_temperature"] as? NSNumber)?.doubleValue
        let target: Double? = (e?.attributes["temperature"] as? NSNumber)?.doubleValue
        let step: Double = (e?.attributes["target_temp_step"] as? NSNumber)?.doubleValue ?? 1
        let mode = e?.state ?? "off"
        let modes: [String] = e?.attr("hvac_modes") ?? []
        HStack(spacing: 40) {
            VStack(alignment: .leading, spacing: 8) {
                Text(e?.name ?? "Thermostat").font(.system(size: 25, weight: .semibold)).foregroundStyle(Theme.text)
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    Text(cur.map { "\(Self.fmt($0))°" } ?? "—").font(.system(size: 72, weight: .light, design: .rounded)).foregroundStyle(Theme.text)
                    Text(mode == "off" ? "Off" : "\(mode.replacingOccurrences(of: "_", with: " ").capitalized) to \(target.map { "\(Self.fmt($0))°" } ?? "—")")
                        .font(.system(size: 26, weight: .medium)).foregroundStyle(mode == "off" ? Theme.muted : Look.color(nil, domain: "climate"))
                }
            }
            Spacer()
            Group {
                Button { set(target, -step) } label: { Image(systemName: "minus").font(.system(size: 30, weight: .bold)).frame(width: 92, height: 92) }.glassButton("thermostat-:\(entity)", radius: 46)
                Button { set(target, step) } label: { Image(systemName: "plus").font(.system(size: 30, weight: .bold)).frame(width: 92, height: 92) }.glassButton("thermostat+:\(entity)", radius: 46)
                Menu {
                    ForEach(modes, id: \.self) { m in
                        Button(m.replacingOccurrences(of: "_", with: " ").capitalized) {
                            Task { await ha.call("climate", "set_hvac_mode", data: ["hvac_mode": m], target: ["entity_id": entity]) }
                        }
                    }
                } label: {
                    Label(mode == "off" ? "Mode" : mode.replacingOccurrences(of: "_", with: " ").capitalized, systemImage: "slider.horizontal.3")
                        .font(.system(size: 24, weight: .semibold)).padding(.horizontal, 28).frame(height: 92)
                }
            }
            .foregroundStyle(Theme.text)
        }
        .padding(34)
        .background(RoundedRectangle(cornerRadius: 34, style: .continuous).fill(.white.opacity(0.05)))
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
    var body: some View {
        // edge to edge (out past the page margin) with a soft fade, so a panel running off the side fades out instead of
        // being cut off at the margin
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 30) { ForEach(entries, id: \.self) { MediaPanel(entry: $0) } }
                .padding(.vertical, 26).padding(.horizontal, 90)
        }
        .padding(.horizontal, -90)
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.035),
                                     .init(color: .black, location: 0.93), .init(color: .clear, location: 1)],
                             startPoint: .leading, endPoint: .trailing))
    }
}

struct MediaPanel: View {
    let entry: DashboardModel.MediaEntry
    @EnvironmentObject var ha: HAConnection
    @EnvironmentObject var model: AppModel
    @State private var art: UIImage?
    @State private var artFor = ""

    var body: some View {
        let e = ha.state(entry.entity)
        let st = e?.state ?? "unavailable"
        let title: String = e?.attr("media_title") ?? (e?.attr("app_name") ?? (e?.attr("source") ?? ""))
        let artist: String = e?.attr("media_artist") ?? (e?.attr("media_series_title") ?? tvModes(e))
        let playing = st == "playing"
        Button { playPause() } label: {
            HStack(spacing: 22) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.08))
                    if let art { Image(uiImage: art).resizable().scaledToFill() }
                    else { Image(systemName: Icons.sf(entry.icon ?? "", domain: "media_player")).font(.system(size: 40)).foregroundStyle(.white.opacity(0.7)) }
                }
                .frame(width: 128, height: 128)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Text(entry.name ?? e?.name ?? entry.entity).font(.system(size: 19, weight: .semibold)).tracking(1.4).textCase(.uppercase)
                            .foregroundStyle(playing ? Look.color(nil, domain: "media_player") : Theme.muted)
                        if playing { Image(systemName: "waveform").font(.system(size: 17, weight: .bold)).foregroundStyle(Look.color(nil, domain: "media_player")) }
                    }
                    Text(title.isEmpty ? Look.stateText(e, domain: "media_player") : title)
                        .font(.system(size: 27, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(artist.isEmpty ? (title.isEmpty ? " " : Look.stateText(e, domain: "media_player")) : artist)
                        .font(.system(size: 21)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                .frame(width: 330, alignment: .leading)
            }
            .padding(20)
        }
        .glassButton("media:\(entry.entity)", tint: Look.color(nil, domain: "media_player"), on: playing)
        .contextMenu { menu(e) }
        .task(id: (e?.attr("entity_picture") as String?) ?? "") { await loadArt(e?.attr("entity_picture") ?? "") }
    }

    @ViewBuilder private func menu(_ e: EntityState?) -> some View {
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
    private func loadArt(_ pic: String) async {
        guard !pic.isEmpty else { art = nil; artFor = ""; return }
        guard pic != artFor else { return }
        artFor = pic
        var path = pic, query: [String: String] = [:]
        if let c = URLComponents(string: pic) { path = c.path; for q in c.queryItems ?? [] { query[q.name] = q.value ?? "" } }
        if let (d, code) = try? await model.rest.request(path, method: "GET", query: query, timeout: 15), code == 200, let img = UIImage(data: d) {
            withAnimation(Theme.soft) { art = img }
        }
    }
}

// MARK: - weather

struct WeatherCard: View {
    let entity: String
    @EnvironmentObject var ha: HAConnection
    @State private var days: [[String: Any]] = []
    @State private var sub: Int?

    var body: some View {
        let e = ha.state(entity)
        let t = (e?.attributes["temperature"] as? NSNumber)?.doubleValue
        let h = (e?.attributes["humidity"] as? NSNumber)?.doubleValue
        Button {} label: {
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
                        Image(systemName: InfoChips.weatherSymbol(d["condition"] as? String ?? "")).symbolRenderingMode(.multicolor).font(.system(size: 34))
                        Text("\((d["temperature"] as? NSNumber).map { "\(Int($0.doubleValue.rounded()))°" } ?? "")")
                            .font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.text)
                        Text("\((d["templow"] as? NSNumber).map { "\(Int($0.doubleValue.rounded()))°" } ?? "")")
                            .font(.system(size: 19)).foregroundStyle(Theme.faint)
                    }
                    .frame(width: 92)
                }
            }
            .padding(34)
        }
        .glassButton("weather:\(entity)", radius: 34)
        .onAppear(perform: subscribe)
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
            ForEach(Array(open.enumerated()), id: \.offset) { _, it in
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
            }
        }
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
