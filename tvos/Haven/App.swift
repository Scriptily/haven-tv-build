import SwiftUI
import UIKit

@main
struct HavenApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    init() { Log.installCrashHandlers() }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.ha)
                .onAppear { model.launch() }
        }
        .onChange(of: phase) { _, p in model.scenePhase(p) }
    }
}

/// Everything the app is doing: pairing or connected, which screen is up, the toast from the PC.
@MainActor
final class AppModel: ObservableObject {
    enum Screen: String { case pairing, home, ambient, dashboard }
    @Published var screen: Screen = .pairing { didSet { if screen != oldValue { Log.shared.add("screen: \(screen.rawValue)") } } }
    @Published var toast = "" { didSet { if !toast.isEmpty { toastClear() } } }

    let settings = Settings()
    lazy var ha = HAConnection(settings: settings)
    lazy var rest = HAREST(settings: settings)
    lazy var remote = Remote(rest: rest, app: self)
    let discovery = Discovery()
    lazy var pairing = Pairing(settings: settings)
    lazy var alerts = Alerts(ha: ha, rest: rest)
    lazy var aerials = AerialLibrary(rest: rest)
    lazy var dashboard = DashboardModel(ha: ha)
    lazy var upNext = UpNextModel(ha: ha)
    private var topShelf: TopShelfWriter?
    /// the last remote press - the dashboard goes back to the ambient screen after `ambientAfter` without one
    private(set) var lastInput = Date()
    var ambientAfter: TimeInterval = 180
    func touch() { lastInput = Date() }

    /// any press or swipe on the remote while the aerials show: back to the dashboard
    func wake() {
        touch()
        if screen == .ambient { Log.shared.add("woken by the remote"); wokeAt = Date(); screen = .dashboard }
    }
    /// the press that woke the aerials ends on the dashboard a moment later - it must not also press whatever got the focus
    private(set) var wokeAt = Date.distantPast
    var pressesOK: Bool { Date().timeIntervalSince(wokeAt) > 0.8 }
    /// bumped whenever the dashboard should put the focus back on its first tile (shown again, Haven back in front)
    @Published var focusReset = 0
    /// Make tvOS look for a focus again. It picks one once; if nothing was focusable at that moment (at launch the tiles
    /// are still loading from Home Assistant) it stays on nothing, and every press goes nowhere - the dashboard and the
    /// aerials never reacted to the remote until build 33. Set by the window watcher.
    var refocusHook: (() -> Void)?
    func refocus() { if let h = refocusHook { h() } else { Log.shared.add("refocus: no hook yet") } }
    var whereHook: (() -> String)?
    private var launched = false

    func launch() {
        guard !launched else { return }
        launched = true
        Log.shared.add("Haven \(Remote.version) started")
        Log.shared.add("signing: \(SharedStore.diagnosis)")
        applyAwake()                                             // stays on - except by the rules in keepAwake
        if settings.paired { connect() } else { startPairing() }
    }

    /// Haven keeps the Apple TV (and so the TV) awake - except in Sleep mode, or (Auto-Sleep When Away on) once the
    /// room has been empty for an hour: then the Apple TV's own sleep timer applies again (Home Assistant also puts it
    /// to sleep at the hour and wakes it when you're back - automation "Apple TV: Haven sleep, wake & re-sign")
    var keepAwake: Bool {
        if ha.state("input_boolean.sleep_mode")?.state == "on" { return false }
        if ha.state("input_boolean.apple_tv_auto_sleep_when_away")?.state != "off",
           let r = ha.state("input_boolean.user_in_room"), r.state == "off",
           Date().timeIntervalSince1970 - r.lastChanged >= 60 * 60 { return false }
        return true
    }
    private var awakeShown: Bool?
    private var leftAt: Date?
    private var awakeTimer: Timer?

    func applyAwake() {
        let k = keepAwake
        UIApplication.shared.isIdleTimerDisabled = k
        if awakeShown != k {
            if awakeShown != nil { Log.shared.add(k ? "keeping the Apple TV awake again" : "letting the Apple TV sleep (sleep mode / room empty 1 h)") }
            awakeShown = k
        }
    }

    private func connect() {
        screen = .dashboard                                     // like the tablet: the dashboard first, aerials when idle
        touch()
        aerials.start()
        Task { await loadConfig() }
        awakeTimer?.invalidate()
        awakeTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        ha.findAgain = {
            let d = Discovery()
            d.start()
            for i in 1...20 {                                  // 20 s of Bonjour, then the network scan
                if let f = d.found.first { d.stop(); return (host: f.host, port: f.port) }
                try? await Task.sleep(for: .seconds(1))
                if i == 15 { await d.scan() }
            }
            d.stop()
            return d.found.first.map { (host: $0.host, port: $0.port) }
        }
        _ = alerts                                              // subscribes on every (re)connect
        _ = dashboard                                           // reads the Apple TV dashboard on every (re)connect
        if topShelf == nil { topShelf = TopShelfWriter(model: self) }
        ha.start()
        remote.start()
    }

    private func startPairing() {
        screen = .pairing
        discovery.start()
        Task {
            // the first Home Assistant found on the network (there's one); no Bonjour answer in 15 s -> scan the network
            var waited = 0
            while discovery.found.isEmpty {
                try? await Task.sleep(for: .seconds(1)); waited += 1
                if waited == 15 || waited % 120 == 0 { await discovery.scan() }
            }
            pairing.begin(with: discovery.found[0])
            while pairing.phase != .done {
                try? await Task.sleep(for: .seconds(1))
                if case .failed = pairing.phase { return }
            }
            discovery.stop()
            connect()
        }
    }

    func scenePhase(_ p: ScenePhase) {
        switch p {
        case .active:
            Log.shared.add("app in front")
            applyAwake()
            if settings.paired {
                Task { await remote.hello(foreground: true) }
                // opening Haven = the dashboard, like the tablet - also after a system dialog, Siri or the screensaver
                // (those only make it "inactive"; it used to need a full trip to the background)
                if let t = leftAt, Date().timeIntervalSince(t) > 2, screen == .ambient { screen = .dashboard }
                leftAt = nil
                focusReset += 1
                touch()
                ha.resume()
            }
        case .inactive:
            if leftAt == nil { leftAt = Date() }
        case .background:
            Log.shared.add("app in background")
            if leftAt == nil { leftAt = Date() }
            if settings.paired { Task { await remote.hello(foreground: false) } }
            Task { await Log.shared.flush() }
            ha.suspend()
        default: break
        }
    }

    private func tick() {
        applyAwake()
        if (screen == .dashboard || screen == .home), Date().timeIntervalSince(lastInput) > ambientAfter {
            Log.shared.add("idle \(Int(ambientAfter / 60)) min - back to the ambient screen")
            screen = .ambient
        }
    }

    /// Haven's settings in Home Assistant (haven/save_config): how long the dashboard waits before the ambient screen
    func loadConfig() async {
        guard let o = try? await rest.json("api/haven/config", method: "GET") else { return }
        if let m = (o["ambient_after_min"] as? NSNumber)?.doubleValue, m >= 0.5 { ambientAfter = m * 60 }
    }

    func reloadConfig() async { Log.shared.add("reload requested"); await loadConfig() }

    /// a haven:// link (the Top Shelf): haven://ambient, haven://dashboard, haven://run?entity=script.lights_on
    func open(_ url: URL) {
        guard url.scheme == "haven" else { return }
        Log.shared.add("opened from the Top Shelf: \(url.host ?? "")")
        touch()
        switch url.host {
        case "ambient": screen = .ambient
        case "dashboard": screen = .dashboard
        case "run":
            let e = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "entity" }?.value ?? ""
            guard e.contains(".") else { return }
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            run(e, name: q?.first { $0.name == "name" }?.value)
        default: break
        }
    }

    private func run(_ entity: String, name given: String?) {
        let domain = String(entity.split(separator: ".").first ?? "")
        let service: (String, String)
        switch domain {
        case "script": service = ("script", "turn_on")
        case "scene": service = ("scene", "turn_on")
        case "button", "input_button": service = (domain, "press")
        default: service = (domain, "toggle")
        }
        let name = given ?? ha.state(entity)?.name ?? entity
        Log.shared.add("top shelf: \(service.0).\(service.1) \(entity)")
        toast = "\(name)…"
        Task {
            // ✓ only once Home Assistant has confirmed it (call() first makes sure the connection is really alive)
            let ok = await ha.call(service.0, service.1, target: ["entity_id": entity])
            toast = ok ? "\(name) ✓" : "Couldn't reach Home Assistant - \(name) wasn't sent"
            await topShelf?.write()
        }
    }

    /// Play/Pause on the remote: whatever the ambient screen shows as playing
    func playPause() {
        guard let np = NowPlaying.pick(ha) else { return }
        Log.shared.add("play/pause \(np.entity)")
        Task { await ha.call("media_player", "media_play_pause", target: ["entity_id": np.entity]) }
    }

    private var toastTask: Task<Void, Never>?
    private func toastClear() {
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth) { self?.toast = "" }
        }
    }
}
