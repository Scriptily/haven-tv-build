import Foundation
import SwiftUI
import UIKit

/// Plain HTTPS calls to Home Assistant (the haven integration's endpoints), with the same certificate check as the
/// WebSocket.
@MainActor
final class HAREST {
    private let settings: Settings
    private lazy var trust = TrustDelegate(tlsName: { [weak self] in self?.settings.tlsName ?? "" })
    private lazy var session = URLSession(configuration: .default, delegate: trust, delegateQueue: .main)
    init(settings: Settings) { self.settings = settings }

    func request(_ path: String, method: String = "POST", json: Any? = nil, query: [String: String] = [:], timeout: Double = 20) async throws -> (Data, Int) {
        guard let base = settings.baseURL, var c = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        if !query.isEmpty { c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var r = URLRequest(url: c.url!)
        r.httpMethod = method; r.timeoutInterval = timeout
        r.setValue("Bearer \(settings.token)", forHTTPHeaderField: "Authorization")
        if let json {
            r.httpBody = try JSONSerialization.data(withJSONObject: json)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (d, resp) = try await session.data(for: r)
        return (d, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// a big file straight to disk (an aerial): the file name goes in the query, every reserved character escaped
    func download(_ path: String, query: [String: String] = [:], to dest: URL) async throws {
        guard let base = settings.baseURL, var c = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        c.percentEncodedQueryItems = query.map { URLQueryItem(name: $0.key, value: $0.value.addingPercentEncoding(withAllowedCharacters: allowed)) }
        var r = URLRequest(url: c.url!)
        r.timeoutInterval = 120                      // between bytes; the whole file may take minutes
        r.setValue("Bearer \(settings.token)", forHTTPHeaderField: "Authorization")
        let (tmp, resp) = try await session.download(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            try? FileManager.default.removeItem(at: tmp)
            throw URLError(.badServerResponse)
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
    }

    func json(_ path: String, method: String = "POST", body: Any? = nil, query: [String: String] = [:], timeout: Double = 20) async throws -> [String: Any] {
        let (d, code) = try await request(path, method: method, json: body, query: query, timeout: timeout)
        guard (200..<300).contains(code) else { throw URLError(.badServerResponse) }
        return (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
    }
}

/// What the app tells Home Assistant about itself, and what it can be asked to do from the PC:
/// - a heartbeat every 60 s (version, what's on screen, connection, memory) - Home Assistant knows it's alive
/// - the log in batches (Log.shared), and a crash from the last run
/// - a live channel: screenshots of its own screen, a message shown on screen, reload, go to a screen
@MainActor
final class Remote {
    private let rest: HAREST
    private let app: AppModel
    private var since = 0
    private var running = false
    let started = Date()

    init(rest: HAREST, app: AppModel) { self.rest = rest; self.app = app }

    static var version: String {
        let i = Bundle.main.infoDictionary
        return "\(i?["CFBundleShortVersionString"] as? String ?? "?") (\(i?["CFBundleVersion"] as? String ?? "?"))"
    }

    func start() {
        guard !running else { return }
        running = true
        Log.shared.sender = { [weak self] batch in await self?.send(batch) ?? false }
        if let crash = Log.takeCrash() {
            Log.shared.add("the last run crashed:\n" + crash, level: .error)
        }
        Task { await heartbeatLoop() }
        Task { await liveLoop() }
        Task { await Log.shared.flush() }
    }

    private func send(_ batch: [[String: Any]]) async -> Bool {
        (try? await rest.json("api/haven/log", body: ["device": Settings.deviceID, "lines": batch])) != nil
    }

    /// one heartbeat now (also sent when the app comes to the front / leaves it, so HA knows what's on screen)
    func hello(foreground: Bool? = nil) async {
        let info: [String: Any] = [
            "device": Settings.deviceID, "version": Self.version, "screen": app.screen.rawValue,
            "uptime": Int(Date().timeIntervalSince(started)), "connected": app.ha.status == .connected,
            "latency": app.ha.latency ?? -1, "entities": app.ha.states.count, "memory_mb": Self.memoryMB(),
            "foreground": foreground ?? (UIApplication.shared.applicationState == .active),
            "expires": Self.signatureExpiry.map { ISO8601DateFormatter().string(from: $0) } ?? "",
            "keep_awake": app.keepAwake,
        ]
        _ = try? await rest.json("api/haven/hello", body: info)
    }

    /// when this install's signature runs out (atvloadly re-signs it a day before): the provisioning profile inside
    /// the app says so - read once
    static let signatureExpiry: Date? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let d = try? Data(contentsOf: url), let s = String(data: d, encoding: .isoLatin1),
              let k = s.range(of: "<key>ExpirationDate</key>"),
              let a = s.range(of: "<date>", range: k.upperBound..<s.endIndex),
              let b = s.range(of: "</date>", range: a.upperBound..<s.endIndex) else { return nil }
        return ISO8601DateFormatter().date(from: String(s[a.upperBound..<b.lowerBound]))
    }()

    private func heartbeatLoop() async {
        while running {
            let info: [String: Any] = [
                "device": Settings.deviceID, "version": Self.version, "screen": app.screen.rawValue,
                "uptime": Int(Date().timeIntervalSince(started)), "connected": app.ha.status == .connected,
                "latency": app.ha.latency ?? -1, "entities": app.ha.states.count, "memory_mb": Self.memoryMB(),
                "foreground": UIApplication.shared.applicationState == .active,
                "expires": Self.signatureExpiry.map { ISO8601DateFormatter().string(from: $0) } ?? "",
                "keep_awake": app.keepAwake,
            ]
            _ = try? await rest.json("api/haven/hello", body: info)
            try? await Task.sleep(for: .seconds(60))
        }
    }

    private func liveLoop() async {
        while running {
            do {
                let o = try await rest.json("api/haven/live", method: "GET", query: ["side": "app", "since": "\(since)", "wait": since == 0 ? "0" : "25"], timeout: 35)
                since = (o["seq"] as? NSNumber)?.intValue ?? since
                for m in o["messages"] as? [[String: Any]] ?? [] { await handle(m) }
            } catch {
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private func handle(_ m: [String: Any]) async {
        let cmd = m["cmd"] as? String ?? ""
        Log.shared.add("live: \(cmd)")
        switch cmd {
        case "shot":
            let jpg = Self.screenshot()
            _ = try? await rest.json("api/haven/live", body: ["to": "pc", "shot": jpg?.base64EncodedString() ?? "", "screen": app.screen.rawValue,
                                                             "reply_to": m["seq"] ?? 0])
        // (no "dashrender": rendering the whole dashboard off screen crashed Haven in SwiftUI's teardown - 2026-11-07)
        case "say":
            app.toast = m["text"] as? String ?? ""
        case "screen":
            if let s = AppModel.Screen(rawValue: (m["screen"] ?? m["to"]) as? String ?? "") { app.touch(); app.screen = s }
        case "where":
            let w = await MainActor.run { app.whereHook?() ?? "no hook" }
            Log.shared.add("where: \(w) | screen \(await MainActor.run { app.screen.rawValue })")
        case "refocus":
            await MainActor.run { app.refocus() }
        case "reload":
            await app.reloadConfig()
        case "scroll":
            app.touch()
            if app.screen != .dashboard { app.screen = .dashboard }
            app.dashboard.scrollTarget = nil
            try? await Task.sleep(for: .milliseconds(80))
            app.dashboard.scrollTarget = (m["section"] as? NSNumber)?.intValue ?? 0
        case "quit":
            // before an update: an open app blocks the Apple TV's install step until it closes. Flush the log, then leave
            Log.shared.add("closing for an update")
            await Log.shared.flush()
            try? await Task.sleep(for: .milliseconds(300))
            exit(0)
        case "status":
            _ = try? await rest.json("api/haven/live", body: ["to": "pc", "status": String(Log.shared.text.suffix(4000)), "reply_to": m["seq"] ?? 0])
        default: break
        }
    }

    /// the app's own screen as a JPEG (1280 px wide). Video layers come out black - the rest is exact.
    static func screenshot() -> Data? {
        guard let w = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return nil }
        let size = CGSize(width: 1280, height: 1280 * w.bounds.height / max(w.bounds.width, 1))
        let img = UIGraphicsImageRenderer(size: size).image { _ in
            w.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: false)
        }
        return img.jpegData(compressionQuality: 0.7)
    }

    static func memoryMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return r == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }
}
