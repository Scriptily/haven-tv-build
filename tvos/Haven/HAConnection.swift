import Foundation

/// One entity as Home Assistant reports it
struct EntityState {
    var state: String
    var attributes: [String: Any]
    var lastChanged: Double
    var lastUpdated: Double
    var name: String { attributes["friendly_name"] as? String ?? "" }
    func attr<T>(_ k: String) -> T? { attributes[k] as? T }
    var number: Double? { Double(state) }
}

/// The live connection to Home Assistant's WebSocket API: login, every entity's state (kept up to date by
/// subscribe_entities), calling services, one-off commands.
///
/// It never trusts a connection just because it hasn't closed: a ping every 20 s must be answered within 10 s, and a
/// login must finish within 15 s - otherwise it's dropped and a new one opened (the tablet's clock once froze for 30 h
/// on a connection that died without closing, when the mini PC crashed). After every reconnect the full state comes
/// again, so nothing stays stale.
@MainActor
final class HAConnection: ObservableObject {
    enum Status: Equatable { case idle, connecting, connected, authFailed, offline(String) }
    @Published private(set) var status: Status = .idle
    @Published private(set) var states: [String: EntityState] = [:]
    /// bumped on every state change (cheap for views to watch)
    @Published private(set) var revision = 0
    /// round trip of the last ping (ms)
    @Published private(set) var latency: Int?
    @Published private(set) var haVersion = ""

    private let settings: Settings
    private lazy var trust = TrustDelegate(tlsName: { [weak self] in self?.settings.tlsName ?? "" })
    private lazy var session = URLSession(configuration: .default, delegate: trust, delegateQueue: .main)
    private var task: URLSessionWebSocketTask?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Any?, Error>] = [:]
    private var subscriptions: [Int: ([String: Any]) -> Void] = [:]
    private var generation = 0
    private var delay: Double = 2
    private var pingTimer: Timer?
    private var pongDeadline: Timer?
    private var authDeadline: Timer?
    private var pingSent = Date()
    private var lastHeard = Date.distantPast
    /// when the connection was last lost (nil while connected)
    private(set) var offlineSince: Date?
    private var rediscovering = false
    /// set by the app: finds Home Assistant on the network again (Bonjour, then a scan)
    var findAgain: (@MainActor () async -> (host: String, port: Int)?)?

    private func rediscover() {
        guard let find = findAgain else { return }
        rediscovering = true
        Task { [weak self] in
            let r = await find()
            guard let self else { return }
            self.rediscovering = false
            if let r, r.host != self.settings.host || r.port != self.settings.port {
                Log.shared.add("Home Assistant is at \(r.host):\(r.port) now (was \(self.settings.host):\(self.settings.port)) - moving there", level: .warning)
                self.settings.move(host: r.host, port: r.port)
                self.delay = 2
                if self.task == nil { self.open() }
            }
        }
    }

    /// called once per (re)connect, after the states subscription - for anything else that must be subscribed again
    var onConnected: [() -> Void] = []

    init(settings: Settings) { self.settings = settings }

    func start() {
        guard settings.paired, task == nil else { return }
        open()
    }

    func stop() {
        generation += 1
        drop(reason: "stopped", reconnect: false)
        status = .idle
    }

    // MARK: connection lifecycle

    private func open() {
        guard let base = settings.baseURL, var c = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return }
        c.scheme = "wss"; c.path = "/api/websocket"
        generation += 1
        let gen = generation
        status = .connecting
        let t = session.webSocketTask(with: c.url!)
        t.maximumMessageSize = 64 * 1024 * 1024
        task = t
        t.resume()
        authDeadline = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.drop(reason: "no login within 15 s", reconnect: true) }
        }
        receive(t, gen: gen)
    }

    private func receive(_ t: URLSessionWebSocketTask, gen: Int) {
        t.receive { [weak self] result in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                switch result {
                case .failure(let e):
                    self.drop(reason: "closed: \(e.localizedDescription)", reconnect: true)
                case .success(let m):
                    var data: Data?
                    switch m {
                    case .string(let s): data = s.data(using: .utf8)
                    case .data(let d): data = d
                    @unknown default: break
                    }
                    if let data { self.handle(data) }
                    self.receive(t, gen: gen)
                }
            }
        }
    }

    /// the connection is gone (or declared dead): forget it, fail what was waiting, try again with back-off
    private func drop(reason: String, reconnect: Bool) {
        let wasConnected = status == .connected
        [pingTimer, pongDeadline, authDeadline].forEach { $0?.invalidate() }
        pingTimer = nil; pongDeadline = nil; authDeadline = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        generation += 1
        for (_, k) in pending { k.resume(throwing: URLError(.networkConnectionLost)) }
        pending = [:]; subscriptions = [:]
        guard reconnect else { return }
        if status != .authFailed { status = .offline(reason) }
        if offlineSince == nil { offlineSince = Date() }
        // offline for 3 min: Home Assistant may have come back at another address - look for it on the network
        if let since = offlineSince, Date().timeIntervalSince(since) > 180, !rediscovering { rediscover() }
        Log.shared.add("connection lost (\(reason)) - again in \(Int(delay)) s", level: wasConnected ? .warning : .info)
        let wait = delay
        delay = min(delay * 2, 30)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, self.task == nil, self.settings.paired, self.status != .authFailed else { return }
            self.open()
        }
    }

    /// the Wi-Fi came back / the app came to the front: check the connection now instead of at the next ping
    /// The app left the screen: tvOS is about to freeze it and the socket won't survive. Close it cleanly, so nothing can
    /// be sent into a dead connection later (on 2026-11-04 a Top Shelf tap after the Apple TV had slept was lost that way).
    func suspend() {
        guard task != nil || status != .idle else { return }
        generation += 1
        drop(reason: "in background", reconnect: false)
        status = .idle
    }

    /// back on screen: a fresh connection, straight away
    func resume() {
        guard settings.paired, status != .authFailed else { return }
        if task == nil { delay = 2; open() } else if status == .connected { ping() }
    }

    /// Is there a connection that really works, right now? A quiet one is proved with a ping first; a dead one is replaced.
    /// Waits for it (up to `timeout`). Everything that must reach Home Assistant goes through this.
    func ready(timeout: Double = 12) async -> Bool {
        guard settings.paired else { return false }
        if status == .connected, task != nil {
            if Date().timeIntervalSince(lastHeard) < 10 { return true }
            if (try? await command(["type": "ping"], timeout: 3)) != nil || status == .connected && Date().timeIntervalSince(lastHeard) < 3 { return true }
            drop(reason: "no answer to a check", reconnect: true)
        } else if task == nil, status != .authFailed {
            delay = 2; open()
        }
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if status == .connected { return true }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return false
    }

    func checkNow() {
        if task == nil { if settings.paired && status != .authFailed { delay = 2; open() } }
        else if status == .connected { ping() }
    }

    private func ping() {
        guard let t = task, status == .connected else { return }
        pongDeadline?.invalidate()
        pingSent = Date()
        let id = nextID; nextID += 1
        t.send(.string(#"{"id":\#(id),"type":"ping"}"#)) { _ in }
        pongDeadline = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.drop(reason: "no pong within 10 s", reconnect: true) }
        }
    }

    // MARK: messages

    private func handle(_ data: Data) {
        lastHeard = Date()
        guard let o = try? JSONSerialization.jsonObject(with: data) else { return }
        // Home Assistant may batch several messages into one array
        let msgs = (o as? [[String: Any]]) ?? [(o as? [String: Any]) ?? [:]]
        for m in msgs { handleOne(m) }
    }

    private func handleOne(_ m: [String: Any]) {
        switch m["type"] as? String {
        case "auth_required":
            haVersion = m["ha_version"] as? String ?? ""
            sendRaw(["type": "auth", "access_token": settings.token])
        case "auth_ok":
            authDeadline?.invalidate()
            if let since = offlineSince {
                Log.shared.add("back after \(Int(Date().timeIntervalSince(since))) s without Home Assistant")
                offlineSince = nil
            }
            status = .connected; delay = 2
            Log.shared.add("connected to Home Assistant \(haVersion)")
            // ids must keep rising on a connection (HA refuses a lower one): this one takes the next id like any other
            let fid = nextID; nextID += 1
            sendRaw(["id": fid, "type": "supported_features", "features": ["coalesce_messages": 1]])
            pingTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in Task { @MainActor in self?.ping() } }
            subscribeEntities()
            onConnected.forEach { $0() }
        case "auth_invalid":
            Log.shared.add("Home Assistant refused the token: \(m["message"] as? String ?? "") - trying again in 10 min", level: .error)
            status = .authFailed
            drop(reason: "auth invalid", reconnect: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 600) { [weak self] in
                guard let self, self.task == nil, self.status == .authFailed, self.settings.paired else { return }
                Log.shared.add("trying the key again")
                self.delay = 2; self.open()
            }
        case "pong":
            if let id = m["id"] as? Int, let k = pending.removeValue(forKey: id) { k.resume(returning: true) }
            pongDeadline?.invalidate()
            latency = Int(Date().timeIntervalSince(pingSent) * 1000)
        case "result":
            guard let id = m["id"] as? Int else { return }
            if m["success"] as? Bool == false, pending[id] == nil {        // a subscription (or fire-and-forget) Home Assistant refused
                let e = m["error"] as? [String: Any]
                Log.shared.add("Home Assistant refused message \(id)\(subscriptions[id] != nil ? " (a subscription)" : ""): \(e?["code"] as? String ?? "") \(e?["message"] as? String ?? "")", level: .error)
                subscriptions[id] = nil
                return
            }
            guard let k = pending.removeValue(forKey: id) else { return }
            if m["success"] as? Bool == true { k.resume(returning: m["result"]) }
            else {
                let e = m["error"] as? [String: Any]
                k.resume(throwing: HAError.failed(e?["message"] as? String ?? "failed", code: e?["code"] as? String ?? ""))
            }
        case "event":
            guard let id = m["id"] as? Int, let ev = m["event"] as? [String: Any] else { return }
            subscriptions[id]?(ev)
        default: break
        }
    }

    private func sendRaw(_ o: [String: Any]) {
        guard let t = task, let d = try? JSONSerialization.data(withJSONObject: o), let s = String(data: d, encoding: .utf8) else { return }
        t.send(.string(s)) { [weak self] e in
            if let e { Task { @MainActor in self?.drop(reason: "send failed: \(e.localizedDescription)", reconnect: true) } }
        }
    }

    /// a command with an answer (throws when Home Assistant says no, or the connection drops meanwhile)
    @discardableResult
    func command(_ o: [String: Any], timeout: Double = 20) async throws -> Any? {
        guard task != nil, status == .connected else { throw URLError(.notConnectedToInternet) }
        let id = nextID; nextID += 1
        var msg = o; msg["id"] = id
        return try await withCheckedThrowingContinuation { (k: CheckedContinuation<Any?, Error>) in
            pending[id] = k
            sendRaw(msg)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                if let k = self?.pending.removeValue(forKey: id) { k.resume(throwing: URLError(.timedOut)) }
            }
        }
    }

    /// a subscription: `handler` gets every event; returns the subscription id
    @discardableResult
    func subscribe(_ o: [String: Any], handler: @escaping ([String: Any]) -> Void) -> Int {
        let id = nextID; nextID += 1
        subscriptions[id] = handler
        var msg = o; msg["id"] = id
        sendRaw(msg)
        return id
    }

    /// ends a subscription (a card that's no longer on screen)
    func unsubscribe(_ id: Int) {
        guard subscriptions.removeValue(forKey: id) != nil, status == .connected else { return }
        let uid = nextID; nextID += 1
        sendRaw(["id": uid, "type": "unsubscribe_events", "subscription": id])
    }

    /// true only once Home Assistant has confirmed it
    @discardableResult
    func call(_ domain: String, _ service: String, data: [String: Any] = [:], target: [String: Any]? = nil) async -> Bool {
        guard await ready() else {
            Log.shared.add("\(domain).\(service) not sent: no connection to Home Assistant", level: .warning)
            return false
        }
        var o: [String: Any] = ["type": "call_service", "domain": domain, "service": service, "service_data": data]
        if let target { o["target"] = target }
        do { try await command(o); return true }
        catch { Log.shared.add("\(domain).\(service) failed: \(error.localizedDescription)", level: .warning); return false }
    }

    // MARK: entity states

    private func subscribeEntities() {
        var fresh: [String: EntityState] = [:]
        var first = true
        subscribe(["type": "subscribe_entities"]) { [weak self] ev in
            guard let self else { return }
            if first { fresh = [:]; first = false } else { fresh = self.states }
            EntityDiff.apply(ev, to: &fresh)
            self.states = fresh
            self.revision &+= 1
        }
    }

    func state(_ id: String) -> EntityState? { states[id] }
}

enum HAError: LocalizedError {
    case failed(String, code: String)
    var errorDescription: String? { if case .failed(let m, _) = self { return m }; return nil }
}

/// subscribe_entities' compact format: "a" = added / replaced (s, a, lc, lu), "c" = changed ("+" new values,
/// "-" removed attributes), "r" = removed entities
enum EntityDiff {
    static func apply(_ ev: [String: Any], to states: inout [String: EntityState]) {
        if let added = ev["a"] as? [String: [String: Any]] {
            for (id, v) in added { states[id] = make(v) }
        }
        if let changed = ev["c"] as? [String: [String: Any]] {
            for (id, diff) in changed {
                guard var e = states[id] else { continue }
                if let plus = diff["+"] as? [String: Any] {
                    if let s = plus["s"] as? String { e.state = s }
                    if let a = plus["a"] as? [String: Any] { for (k, v) in a { e.attributes[k] = v } }
                    if let lc = number(plus["lc"]) { e.lastChanged = lc; e.lastUpdated = lc }
                    if let lu = number(plus["lu"]) { e.lastUpdated = lu }
                }
                if let minus = diff["-"] as? [String: Any], let gone = minus["a"] as? [String] {
                    for k in gone { e.attributes.removeValue(forKey: k) }
                }
                states[id] = e
            }
        }
        if let removed = ev["r"] as? [String] { for id in removed { states.removeValue(forKey: id) } }
    }

    private static func make(_ v: [String: Any]) -> EntityState {
        let lc = number(v["lc"]) ?? 0
        return EntityState(state: v["s"] as? String ?? "unknown", attributes: v["a"] as? [String: Any] ?? [:],
                           lastChanged: lc, lastUpdated: number(v["lu"]) ?? lc)
    }

    private static func number(_ x: Any?) -> Double? { (x as? NSNumber)?.doubleValue }
}
