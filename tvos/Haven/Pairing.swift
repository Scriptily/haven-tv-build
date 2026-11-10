import Foundation
import Network

/// Finding Home Assistant on the home network (it announces itself over Bonjour as _home-assistant._tcp) - so the app
/// never needs an address typed in, and finds it again if it ever moves.
@MainActor
final class Discovery: ObservableObject {
    struct Found: Equatable { let host: String; let port: Int; let name: String }
    @Published private(set) var found: [Found] = []
    private var browser: NWBrowser?
    private var resolving: [NWConnection] = []

    func start() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_home-assistant._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.resolve(results) }
        }
        b.stateUpdateHandler = { s in
            if case .failed(let e) = s { Log.shared.add("Bonjour: \(e)", level: .warning) }
        }
        b.start(queue: .main)
        browser = b
        Log.shared.add("looking for Home Assistant on the network")
    }

    func stop() { browser?.cancel(); browser = nil; resolving.forEach { $0.cancel() }; resolving = [] }

    /// a Bonjour result is a name: connect to it once to learn the address and port it resolves to. IPv4 only: Home
    /// Assistant also announces IPv6 addresses (link-local / ULA), and its certificate + the app's settings want the
    /// plain address (the first build took an IPv6 answer, dropped it, and searched forever).
    private func resolve(_ results: Set<NWBrowser.Result>) {
        for r in results {
            var label = "Home Assistant"
            if case .service(let n, _, _, _) = r.endpoint { label = n }
            let params = NWParameters.tcp
            if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
            let c = NWConnection(to: r.endpoint, using: params)
            c.stateUpdateHandler = { [weak self, weak c] st in
                guard let c else { return }
                if case .ready = st, let ep = c.currentPath?.remoteEndpoint, case .hostPort(let h, let p) = ep {
                    var host = "\(h)"
                    if let pct = host.firstIndex(of: "%") { host = String(host[..<pct]) }   // IPv6 zone
                    let f = Found(host: host, port: Int(p.rawValue), name: label)
                    Task { @MainActor in
                        guard let self else { return }
                        if host.contains(":") { Log.shared.add("Bonjour gave \(label) at an IPv6 address \(host) - skipped"); return }
                        if !self.found.contains(f) { self.found.append(f); Log.shared.add("found \(label) at \(host):\(p.rawValue) (Bonjour)") }
                    }
                    c.cancel()
                } else if case .failed(let e) = st { Log.shared.add("Bonjour: couldn't reach \(label): \(e)", level: .warning); c.cancel() }
            }
            c.start(queue: .main)
            resolving.append(c)
        }
    }

    /// Fallback when Bonjour finds nothing (multicast blocked, the local network permission not given yet): ask every
    /// address of this network (x.x.x.1-254) whether it's a Home Assistant with the haven integration on port 8123.
    func scan() async {
        guard let me = Self.ownIPv4(), found.isEmpty else { return }
        let prefix = me.split(separator: ".").prefix(3).joined(separator: ".")
        Log.shared.add("Bonjour found nothing - checking \(prefix).1-254 for Home Assistant")
        let session = URLSession(configuration: { let c = URLSessionConfiguration.ephemeral; c.timeoutIntervalForRequest = 2; return c }(),
                                 delegate: TrustDelegate(tlsName: { "" }), delegateQueue: nil)
        await withTaskGroup(of: String?.self) { g in
            for i in 1...254 {
                let host = "\(prefix).\(i)"
                if host == me { continue }
                g.addTask {
                    var r = URLRequest(url: URL(string: "https://\(host):8123/api/haven/pair")!)
                    r.httpMethod = "GET"; r.timeoutInterval = 2
                    guard let (_, resp) = try? await session.data(for: r), let h = resp as? HTTPURLResponse else { return nil }
                    return h.statusCode == 405 ? host : nil          // the haven integration answers GET with "use POST"
                }
            }
            for await h in g { if let h, !found.contains(where: { $0.host == h }) {
                found.append(Found(host: h, port: 8123, name: "Home Assistant")); Log.shared.add("found Home Assistant at \(h):8123 (scan)") } }
        }
        if found.isEmpty { Log.shared.add("no Home Assistant on \(prefix).x either", level: .warning) }
    }

    /// this Apple TV's own IPv4 address on the home network (Ethernet or Wi-Fi)
    static func ownIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var best: String?
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let a = p.pointee
            guard let sa = a.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: a.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa.pointee.sa_len), &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: buf)
            if ip.hasPrefix("169.254") { continue }
            if best == nil || name == "en0" { best = ip }
        }
        return best
    }
}

/// Pairing, once: the TV shows a 6-digit code and asks Home Assistant (the haven integration) for a key; once the
/// code is approved there, the answer carries the token and the name Home Assistant's certificate is issued for.
@MainActor
final class Pairing: ObservableObject {
    enum Phase: Equatable { case searching, waiting(code: String, ha: String), failed(String), done }
    @Published private(set) var phase: Phase = .searching
    let code = String(format: "%06d", Int.random(in: 0...999_999))
    private let settings: Settings
    private var polling = false

    init(settings: Settings) { self.settings = settings }

    private lazy var trust = TrustDelegate(tlsName: { "" })                // chain only: the name isn't known yet
    private lazy var session = URLSession(configuration: .ephemeral, delegate: trust, delegateQueue: .main)

    func begin(with ha: Discovery.Found) {
        guard !polling else { return }
        polling = true
        phase = .waiting(code: code, ha: ha.name)
        Log.shared.add("pairing with \(ha.name) - code shown on screen")
        Task { await poll(ha) }
    }

    private func poll(_ ha: Discovery.Found) async {
        let url = URL(string: "https://\(ha.host):\(ha.port)/api/haven/pair")!
        // the log so far goes along: before pairing it has nowhere else to go
        let body: [String: Any] = ["code": code, "device": Settings.deviceID, "name": "Apple TV",
                                   "app": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
                                   "log": String(Log.shared.text.suffix(6000))]
        for _ in 0..<240 {                                                  // 20 minutes
            var r = URLRequest(url: url); r.httpMethod = "POST"; r.timeoutInterval = 10
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: body)
            if let (d, resp) = try? await session.data(for: r), let h = resp as? HTTPURLResponse {
                if h.statusCode == 200, let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                   let token = o["token"] as? String, !token.isEmpty {
                    settings.save(host: ha.host, port: ha.port, tlsName: o["tls_name"] as? String ?? "", token: token)
                    Log.shared.add("paired")
                    phase = .done
                    return
                }
                if h.statusCode == 404 { phase = .failed("Home Assistant doesn't have the Haven integration yet."); polling = false; return }
            }
            try? await Task.sleep(for: .seconds(5))
        }
        phase = .failed("Not approved yet - the code expired. Restart the app for a new one.")
        polling = false
    }
}
