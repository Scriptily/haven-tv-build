import SwiftUI
import UIKit

/// iPhone notifications + calls on the TV - the same stream the tablet gets (the ANCS bridge), filtered in Home
/// Assistant by the Apple TV's own toggles (Alerts / Message Previews / Big Alerts on Ambient).
///
/// Haven's look, not the tablet's: notes are lit glass cards that drift in at the top-right with a light spine in the
/// app's color; A call is a small glass capsule at the top (a pulsing
/// dot while it rings); answered, it runs a timer. Nothing takes focus - the remote keeps doing what it was doing.
@MainActor
final class Alerts: ObservableObject {
    struct Note: Identifiable, Equatable {
        let id: String
        let uid: String
        let appID: String
        let app: String
        let symbol: String
        let tint: Color
        let title: String
        let subtitle: String
        let message: String
        let big: Bool
        let received: Date
        let life: Double
    }
    struct Call: Equatable {
        enum Phase { case ringing, onCall }
        var uid: String
        var phase: Phase
        let caller: String
        let app: String
        let big: Bool
        var since: Date
    }

    @Published private(set) var notes: [Note] = []         // newest first
    @Published private(set) var call: Call?
    @Published private(set) var icons: [String: UIImage] = [:]

    static let noteSeconds = 9.0, bigSeconds = 12.0, ringMax = 75.0, onCallMax = 4 * 3600.0, maxShown = 3

    private let ha: HAConnection
    private let rest: HAREST
    private var timers: [String: Task<Void, Never>] = [:]
    private var callTimer: Task<Void, Never>?
    private var storeNames: [String: String] = [:]
    private var iconTried: Set<String> = []

    init(ha: HAConnection, rest: HAREST) {
        self.ha = ha; self.rest = rest
        ha.onConnected.append { [weak self] in self?.subscribe() }
        if ha.status == .connected { subscribe() }
    }

    private func subscribe() {
        if call != nil {
            Log.shared.add("call card removed after a reconnect (its end may have been missed meanwhile)")
            callTimer?.cancel()
            withAnimation(Haven.leave) { call = nil }
        }
        ha.subscribe(["type": "haven/notifications"]) { [weak self] ev in self?.handle(ev) }
        Log.shared.add("listening for iPhone notifications")
        if storeNames.isEmpty { Task { await loadStoreNames() } }
    }

    // MARK: the stream (same rules as the tablet's banners)

    func handle(_ d: [String: Any]) {
        let s = { (k: String) in d[k] as? String ?? "" }
        let kind = s("kind"), uid = s("uid"), big = false        // no big alerts on a 55" TV
        switch kind {
        case "notification":
            let key = "n:\(uid)"
            guard !notes.contains(where: { $0.id == key }) || uid.isEmpty else { return }      // ANCS can resend a uid
            let info = AppInfo.of(s("app_id"), category: s("category"), storeNames: storeNames)
            let life = big ? Self.bigSeconds : Self.noteSeconds
            let n = Note(id: uid.isEmpty ? UUID().uuidString : key, uid: uid, appID: s("app_id"), app: info.name, symbol: info.symbol, tint: info.tint,
                         title: s("title"), subtitle: s("subtitle"), message: s("message"), big: big, received: Date(), life: life)
            withAnimation(Haven.arrive) {
                notes.insert(n, at: 0)
                if notes.count > Self.maxShown { notes.removeLast(notes.count - Self.maxShown) }
            }
            schedule(n.id, after: life)
            loadIcon(n.appID)
            Log.shared.add("alert: \(info.name) (uid \(uid))\(big ? " big" : "")\(n.message.isEmpty ? " title only" : "")")
        case "call":
            if call?.uid == uid { return }
            let info = AppInfo.of(s("app_id"), category: "incoming_call", storeNames: storeNames)
            withAnimation(Haven.arrive) { call = Call(uid: uid, phase: .ringing, caller: s("title"), app: info.name, big: big, since: Date()) }
            callTimer?.cancel()
            callTimer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.ringMax))
                guard !Task.isCancelled, self?.call?.phase == .ringing else { return }
                Log.shared.add("call card: ringing for \(Int(Self.ringMax)) s with no end - removed")
                withAnimation(Haven.leave) { self?.call = nil }
            }
            Log.shared.add("call card: ringing (uid \(uid))\(big ? " big" : "")")
        case "call_active":
            callTimer?.cancel()
            if var c = call {
                if c.phase == .onCall && c.uid == uid { return }
                c.uid = uid
                if c.phase == .ringing { c.phase = .onCall; c.since = Date() }
                withAnimation(Haven.arrive) { call = c }
                capOnCall()
                Log.shared.add("call card: answered (uid \(uid)) - on-call timer")
            } else {
                let info = AppInfo.of(s("app_id"), category: "incoming_call", storeNames: storeNames)
                withAnimation(Haven.arrive) { call = Call(uid: uid, phase: .onCall, caller: s("title"), app: info.name, big: false, since: Date()) }
                capOnCall()
                Log.shared.add("call card: outgoing / connected (uid \(uid)) - on-call timer")
            }
        case "call_ended":
            guard let c = call, c.uid == uid || uid.isEmpty else { return }
            // iOS can hand an answered call to a new notification a moment later (call_active): wait for that first
            callTimer?.cancel()
            callTimer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(c.phase == .ringing ? 2.5 : 0.4))
                guard !Task.isCancelled, let self, let now = self.call, now.uid == c.uid else { return }
                Log.shared.add("call card: \(now.phase == .ringing ? "missed or declined" : "call ended") (uid \(c.uid)) - removed")
                withAnimation(Haven.leave) { self.call = nil }
            }
        default:
            Log.shared.add("alert: unknown kind \(kind)", level: .warning)
        }
    }

    /// if the iPhone's "call ended" is ever lost, the on-call capsule still goes away
    private func capOnCall() {
        callTimer?.cancel()
        callTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.onCallMax))
            guard !Task.isCancelled, self?.call?.phase == .onCall else { return }
            Log.shared.add("call card: on a call for 4 h with no end from the iPhone - removed", level: .warning)
            withAnimation(Haven.leave) { self?.call = nil }
        }
    }

    func dismiss(_ id: String) {
        timers.removeValue(forKey: id)?.cancel()
        withAnimation(Haven.leave) { notes.removeAll { $0.id == id } }
    }

    private func schedule(_ id: String, after s: Double) {
        timers[id]?.cancel()
        timers[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(s))
            guard !Task.isCancelled else { return }
            self?.dismiss(id)
        }
    }

    // MARK: real app icons + names (the same files the tablet uses, served by Home Assistant)

    private func loadIcon(_ id: String) {
        guard !id.isEmpty, icons[id] == nil, !iconTried.contains(id),
              id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{2,150}$"#, options: .regularExpression) != nil else { return }
        iconTried.insert(id)
        Task {
            for attempt in 0..<2 {
                if attempt > 0 { try? await Task.sleep(for: .seconds(2.5)) }       // a new app's icon arrives within seconds
                if let (d, code) = try? await rest.request("/local/app-icons/\(id).png", method: "GET", timeout: 8), code == 200,
                   let img = UIImage(data: d) {
                    withAnimation(Theme.soft) { icons[id] = img }
                    return
                }
            }
        }
    }

    private func loadStoreNames() async {
        guard let (d, code) = try? await rest.request("/local/app-icons/index.json", method: "GET", timeout: 10), code == 200,
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        for (id, v) in o {
            guard let n = (v as? [String: Any])?["name"] as? String else { continue }
            let short = n.components(separatedBy: CharacterSet(charactersIn: "-–—:|")).first?.trimmingCharacters(in: .whitespaces) ?? n
            if !short.isEmpty && short.count <= 24 { storeNames[id] = short }
        }
    }
}

/// Haven's motion: arrivals settle with a touch of give (they come from somewhere), departures are quick and clean.
enum Haven {
    static let arrive = Animation.spring(response: 0.55, dampingFraction: 0.86)
    static let leave = Animation.spring(response: 0.38, dampingFraction: 1.0)
    static let green = Color(red: 0.42, green: 0.90, blue: 0.62)
}

struct AppInfo {
    let name: String, symbol: String, tint: Color

    private static func hex(_ h: UInt32) -> Color {
        Color(red: Double(h >> 16 & 0xff) / 255, green: Double(h >> 8 & 0xff) / 255, blue: Double(h & 0xff) / 255)
    }
    private static let apps: [String: (String, String, UInt32)] = [
        "com.apple.MobileSMS": ("Messages", "message.fill", 0x34c759), "com.apple.mobilephone": ("Phone", "phone.fill", 0x34c759),
        "com.apple.facetime": ("FaceTime", "video.fill", 0x34c759), "com.apple.mobilemail": ("Mail", "envelope.fill", 0x0a84ff),
        "com.apple.mobilecal": ("Calendar", "calendar", 0xff453a), "com.apple.reminders": ("Reminders", "checklist", 0xff9f0a),
        "com.apple.Passbook": ("Wallet", "wallet.pass.fill", 0x8e8e93), "com.apple.Health": ("Health", "heart.fill", 0xff2d55),
        "net.whatsapp.WhatsApp": ("WhatsApp", "bubble.left.fill", 0x25d366), "ph.telegra.Telegraph": ("Telegram", "paperplane.fill", 0x2aabee),
        "com.facebook.Messenger": ("Messenger", "bubble.left.fill", 0x0a7cff), "com.burbn.instagram": ("Instagram", "camera.fill", 0xd62976),
        "com.toyopagroup.picaboo": ("Snapchat", "bubble.left.fill", 0xe6c800), "com.atebits.Tweetie2": ("X", "text.bubble.fill", 0x9a9aa0),
        "com.hammerandchisel.discord": ("Discord", "gamecontroller.fill", 0x5865f2), "com.tinyspeck.chatlyio": ("Slack", "number", 0xb07cc6),
        "com.google.Gmail": ("Gmail", "envelope.fill", 0xea4335), "com.microsoft.Office.Outlook": ("Outlook", "envelope.fill", 0x0078d4),
        "com.microsoft.skype.teams": ("Teams", "person.2.fill", 0x7b7fe0), "com.google.ios.youtube": ("YouTube", "play.rectangle.fill", 0xff3030),
        "com.spotify.client": ("Spotify", "music.note", 0x1db954), "io.robbie.HomeAssistant": ("Home Assistant", "house.fill", 0x18bcf2),
        "com.amazon.Amazon": ("Amazon", "shippingbox.fill", 0xff9900), "com.plexapp.plex": ("Plex", "play.circle.fill", 0xe5a00d),
    ]
    private static let categories: [String: (String, UInt32)] = [
        "incoming_call": ("phone.arrow.down.left.fill", 0x34c759), "missed_call": ("phone.down.fill", 0xff453a),
        "voicemail": ("recordingtape", 0xff453a), "social": ("person.2.fill", 0x8f7cff), "schedule": ("calendar", 0xff453a),
        "email": ("envelope.fill", 0x0a84ff), "news": ("newspaper.fill", 0xff9f0a), "health_fitness": ("heart.fill", 0xff2d55),
        "business_finance": ("dollarsign.circle.fill", 0x30d158), "location": ("location.fill", 0x0a84ff),
        "entertainment": ("play.circle.fill", 0xbf5af2),
    ]

    static func of(_ id: String, category: String, storeNames: [String: String]) -> AppInfo {
        let cat = categories[category]
        if let a = apps[id] {
            // a missed call / voicemail keeps its own red symbol even from Phone
            if category == "missed_call" || category == "voicemail", let c = cat { return AppInfo(name: a.0, symbol: c.0, tint: hex(c.1)) }
            return AppInfo(name: a.0, symbol: a.1, tint: hex(a.2))
        }
        let tail = id.split(separator: ".").last.map(String.init) ?? ""
        let name = storeNames[id] ?? (tail.isEmpty ? "Notification" : tail.prefix(1).uppercased() + tail.dropFirst())
        return AppInfo(name: name, symbol: cat?.0 ?? "bell.fill", tint: cat.map { hex($0.1) } ?? Theme.accent)
    }
}

// MARK: - the overlay (above every screen, never focusable)

struct AlertsOverlay: View {
    @ObservedObject var alerts: Alerts
    /// the ambient / home screen is up (not the dashboard)
    let immersive: Bool

    var body: some View {
        ZStack {
            // notes: a top-right column of glass cards (newest on top)
            VStack(alignment: .trailing, spacing: 18) {
                ForEach(Array(compactNotes.enumerated()), id: \.element.id) { i, n in
                    NoteCard(note: n, icon: alerts.icons[n.appID], depth: i)
                        .transition(.asymmetric(insertion: .modifier(active: Drift(x: 90, blur: 14, scale: 0.96, opacity: 0), identity: Drift.rest),
                                                removal: .modifier(active: Drift(x: 30, blur: 10, scale: 0.94, opacity: 0), identity: Drift.rest)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.top, 60).padding(.trailing, 80)


            if let c = alerts.call {
                switch c.phase {
                case .ringing:
                    CallCapsule(call: c).transition(.modifier(active: Drift(y: -40, blur: 12, scale: 0.95, opacity: 0), identity: Drift.rest))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.top, 54)
                case .onCall:      // top center: clear of the clock (top-left) and the notes (top-right)
                    CallCapsule(call: c).transition(.modifier(active: Drift(y: -40, blur: 12, scale: 0.95, opacity: 0), identity: Drift.rest))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.top, 54)
                }
            }
        }
        .allowsHitTesting(false)
        .focusable(false)
        .animation(Haven.arrive, value: alerts.notes)
        .animation(Haven.arrive, value: alerts.call)
    }

    private var compactNotes: [Alerts.Note] { alerts.notes }
}

/// offset + blur + scale + opacity in one: Haven's enter/leave (things come into focus, like the camera finding them)
struct Drift: ViewModifier {
    var x: CGFloat, y: CGFloat, blur: CGFloat, scale: CGFloat, opacity: Double
    init(x: CGFloat = 0, y: CGFloat = 0, blur: CGFloat, scale: CGFloat, opacity: Double) {
        self.x = x; self.y = y; self.blur = blur; self.scale = scale; self.opacity = opacity
    }
    static let rest = Drift(blur: 0, scale: 1, opacity: 1)
    func body(content: Content) -> some View {
        content.offset(x: x, y: y).blur(radius: blur).scaleEffect(scale).opacity(opacity)
    }
}

/// Haven's glass: a dark frosted material, a faint inner rim lit from the top-left, a soft ink shadow
struct Glass: ViewModifier {
    var radius: CGFloat
    var tint: Color = .clear
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(Color(red: 0.05, green: 0.05, blue: 0.08).opacity(0.42))
                    shape.fill(RadialGradient(colors: [tint.opacity(0.22), .clear], center: .leading, startRadius: 0, endRadius: 420))
                }
            }
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.04), .white.opacity(0.08)],
                                                       startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.2))
            .clipShape(shape)
            .shadow(color: .black.opacity(0.45), radius: 40, y: 18)
    }
}

extension View { func havenGlass(_ r: CGFloat, tint: Color = .clear) -> some View { modifier(Glass(radius: r, tint: tint)) } }

struct AppMark: View {
    let symbol: String, tint: Color, icon: UIImage?, size: CGFloat
    var body: some View {
        ZStack {
            if let icon {
                Image(uiImage: icon).resizable().interpolation(.high).scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.62)], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: symbol).font(.system(size: size * 0.46, weight: .semibold)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1))
    }
}

/// a compact note: top-right, glass, with a light spine in the app's color and a hairline that drains over its life
struct NoteCard: View {
    let note: Alerts.Note
    let icon: UIImage?
    let depth: Int
    @State private var drain = false

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            AppMark(symbol: note.symbol, tint: note.tint, icon: icon, size: 66)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(note.app.uppercased()).font(.system(size: 19, weight: .semibold)).tracking(1.4).foregroundStyle(note.tint.opacity(0.95))
                    Spacer(minLength: 12)
                    Text("now").font(.system(size: 19, weight: .medium)).foregroundStyle(Theme.faint)
                }
                if !note.title.isEmpty {
                    Text(note.title).font(.system(size: 29, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                }
                let line = [note.subtitle, note.message].filter { !$0.isEmpty }.joined(separator: " · ")
                if !line.isEmpty {
                    Text(line).font(.system(size: 25)).foregroundStyle(Theme.muted).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.leading, 34).padding(.trailing, 30).padding(.vertical, 24)
        .frame(width: 640, alignment: .leading)
        .overlay(alignment: .leading) {
            Capsule().fill(note.tint).frame(width: 5).padding(.vertical, 22).padding(.leading, 12)
                .shadow(color: note.tint.opacity(0.9), radius: 10)
        }
        .overlay(alignment: .bottom) {
            GeometryReader { g in
                Capsule().fill(note.tint.opacity(0.55)).frame(width: drain ? 0 : g.size.width, height: 2)
            }
            .frame(height: 2).padding(.horizontal, 30).padding(.bottom, 9)
        }
        .havenGlass(32, tint: note.tint)
        .scaleEffect(1 - CGFloat(depth) * 0.035, anchor: .topTrailing)
        .opacity(1 - Double(depth) * 0.16)
        .onAppear { withAnimation(.linear(duration: note.life)) { drain = true } }
    }
}

/// a ringing call, or any call in progress: a small capsule; on a call it runs a timer
struct CallCapsule: View {
    let call: Alerts.Call
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 18) {
            ZStack {
                Circle().fill(Haven.green).frame(width: 14, height: 14)
                if call.phase == .ringing && !reduceMotion {
                    Circle().stroke(Haven.green.opacity(pulse ? 0 : 0.8), lineWidth: 2).frame(width: pulse ? 40 : 14, height: pulse ? 40 : 14)
                }
            }
            .frame(width: 30)
            if call.phase == .onCall {
                TimelineView(.periodic(from: call.since, by: 1)) { ctx in
                    Text("On call · \(Self.clock(ctx.date.timeIntervalSince(call.since)))")
                        .font(.system(size: 26, weight: .semibold).monospacedDigit()).foregroundStyle(Haven.green)
                }
            } else {
                Text("Incoming call").font(.system(size: 26, weight: .semibold)).foregroundStyle(Haven.green)
            }
            if !call.caller.isEmpty {
                Text(call.caller).font(.system(size: 26, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
            }
        }
        .padding(.horizontal, 30).padding(.vertical, 18)
        .havenGlass(36, tint: Haven.green)
        .onAppear { withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true } }
    }

    static func clock(_ s: TimeInterval) -> String {
        let t = max(0, Int(s))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// the caller's initials on a deep green glass disc (no contact photos come over the bridge)
struct Monogram: View {
    let name: String, size: CGFloat
    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Color(red: 0.20, green: 0.55, blue: 0.40), Color(red: 0.08, green: 0.28, blue: 0.24)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle().strokeBorder(.white.opacity(0.22), lineWidth: 1.5)
            if initials.isEmpty {
                Image(systemName: "person.fill").font(.system(size: size * 0.42)).foregroundStyle(.white.opacity(0.9))
            } else {
                Text(initials).font(.system(size: size * 0.38, weight: .semibold, design: .rounded)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: Haven.green.opacity(0.35), radius: 30)
    }
    private var initials: String {
        let words = name.split(whereSeparator: { $0 == " " }).filter { $0.first?.isLetter == true }
        return String(words.prefix(2).compactMap { $0.first }).uppercased()
    }
}
