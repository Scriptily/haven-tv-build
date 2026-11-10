import SwiftUI
import UIKit

/// The look: near-black with a faint warm-violet depth (made for a 4K OLED - true blacks, nothing harsh), large
/// tracking-tightened type, frosted materials for anything that floats.
enum Theme {
    static let ink = Color(red: 0.04, green: 0.04, blue: 0.055)
    static let text = Color.white.opacity(0.92)
    static let muted = Color.white.opacity(0.55)
    static let faint = Color.white.opacity(0.28)
    static let accent = Color(red: 0.62, green: 0.56, blue: 1.0)
    static let good = Color(red: 0.45, green: 0.86, blue: 0.62)
    static let warn = Color(red: 1.0, green: 0.72, blue: 0.36)
    /// critically damped by default (response 0.35): nothing bounces unless it was flung
    static let spring = Animation.spring(response: 0.35, dampingFraction: 1.0)
    static let soft = Animation.spring(response: 0.6, dampingFraction: 1.0)

    static var backdrop: some View {
        ZStack {
            ink
            RadialGradient(colors: [Color(red: 0.17, green: 0.12, blue: 0.26).opacity(0.9), .clear], center: UnitPoint(x: 0.12, y: -0.05),
                           startRadius: 0, endRadius: 1300)
            RadialGradient(colors: [Color(red: 0.23, green: 0.12, blue: 0.19).opacity(0.7), .clear], center: UnitPoint(x: 1.0, y: 0.0),
                           startRadius: 0, endRadius: 1200)
        }
        .ignoresSafeArea()
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ZStack {
            Theme.backdrop
            if model.screen == .pairing {
                PairingView(pairing: model.pairing).transition(.opacity)
            } else {
                // both stay loaded, so going between them is a true crossfade: the aerial (paused while hidden) is
                // already there under the dashboard
                AmbientHost(library: model.aerials, showing: model.screen == .ambient)
                    .opacity(model.screen == .ambient ? 1 : 0)
                    .disabled(model.screen != .ambient)
                DashboardScreen(dash: model.dashboard)
                    .opacity(model.screen == .dashboard ? 1 : 0)
                    .scaleEffect(model.screen == .dashboard ? 1 : 1.025)
                    .disabled(model.screen != .dashboard)
                if model.screen == .home {
                    HomeStatusView().focusable().onExitCommand { model.screen = .dashboard }.transition(.opacity)
                }
            }
            if model.screen != .pairing { AlertsOverlay(alerts: model.alerts, immersive: model.screen != .dashboard) }
            ToastView(text: model.toast)
        }
        .animation(.easeInOut(duration: 0.5), value: model.screen)
        .background(RemoteWatcher(model: model))
        .onMoveCommand { _ in model.wake() }                                  // anywhere: arrows wake the aerials
        .onPlayPauseCommand { model.touch(); model.playPause() }              // anywhere: play / pause what's playing
        .onOpenURL { model.open($0) }
        .preferredColorScheme(.dark)
    }
}

// MARK: pairing

struct PairingView: View {
    @ObservedObject var pairing: Pairing
    var body: some View {
        VStack(spacing: 48) {
            Text("Haven").font(.system(size: 76, weight: .semibold, design: .rounded)).tracking(-1.5).foregroundStyle(Theme.text)
            switch pairing.phase {
            case .searching:
                VStack(spacing: 20) {
                    ProgressView().scaleEffect(1.4)
                    Text("Looking for Home Assistant on your network…").font(.title3).foregroundStyle(Theme.muted)
                }
            case .waiting(let code, let ha):
                VStack(spacing: 28) {
                    Text("Pairing with \(ha)").font(.title3).foregroundStyle(Theme.muted)
                    HStack(spacing: 18) {
                        ForEach(Array(code.enumerated()), id: \.offset) { _, ch in
                            Text(String(ch))
                                .font(.system(size: 96, weight: .medium, design: .rounded).monospacedDigit())
                                .foregroundStyle(Theme.text)
                                .frame(width: 110, height: 150)
                                .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.ultraThinMaterial))
                        }
                    }
                    Text("Approve this code in Home Assistant").font(.headline).foregroundStyle(Theme.faint)
                }
            case .failed(let why):
                Text(why).font(.title3).foregroundStyle(Theme.warn).multilineTextAlignment(.center)
            case .done:
                Image(systemName: "checkmark.circle.fill").font(.system(size: 90)).foregroundStyle(Theme.good)
            }
        }
        .animation(Theme.soft, value: pairing.phase)
    }
}

// MARK: connected (phase 1: proves the link; the ambient screen replaces it)

struct HomeStatusView: View {
    @EnvironmentObject var ha: HAConnection
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(alignment: .leading, spacing: 0) {
                Text(ctx.date, format: .dateTime.hour().minute())
                    .font(.system(size: 64, weight: .light, design: .rounded)).tracking(-1).foregroundStyle(Theme.text)
                Text(ctx.date, format: .dateTime.weekday(.wide).month(.wide).day())
                    .font(.title3).foregroundStyle(Theme.muted)
                Spacer()
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 14) {
                        Circle().fill(dot).frame(width: 14, height: 14)
                        Text(statusText).font(.title2.weight(.medium)).foregroundStyle(Theme.text)
                    }
                    Text("\(ha.states.count) entities\(ha.latency.map { " · \($0) ms" } ?? "") · Haven \(Remote.version)")
                        .font(.headline).foregroundStyle(Theme.muted)
                    if let np = nowPlaying {
                        Label(np, systemImage: "music.note").font(.title3).foregroundStyle(Theme.text).lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 90).padding(.vertical, 70)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var dot: Color {
        switch ha.status { case .connected: return Theme.good; case .connecting: return Theme.accent; default: return Theme.warn }
    }
    private var statusText: String {
        switch ha.status {
        case .connected: return "Connected to Home Assistant \(ha.haVersion)"
        case .connecting: return "Connecting…"
        case .authFailed: return "Home Assistant refused the key - pair again"
        case .offline(let why): return "Reconnecting (\(why))"
        case .idle: return "Not connected"
        }
    }
    private var nowPlaying: String? {
        guard let e = ha.states.values.first(where: { $0.state == "playing" && $0.attributes["media_title"] != nil }) else { return nil }
        let t: String = e.attr("media_title") ?? ""
        let a: String = e.attr("media_artist") ?? ""
        return a.isEmpty ? t : "\(t) — \(a)"
    }
}

/// The aerials with the remote's way back: a full-screen button nothing can be seen of. It takes the focus whenever the
/// aerials show, so Select, Menu and swipes reach it (RemoteWatcher catches the same at the window level, as a second net).
struct AmbientHost: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var library: AerialLibrary
    let showing: Bool
    @FocusState private var focused: Bool

    var body: some View {
        Button { model.wake() } label: { AmbientView(library: library, showing: showing) }
            .buttonStyle(Bare())                    // invisible (.plain drew it as an inset card with the dashboard's edges around)
            .focused($focused)
            .onPlayPauseCommand { model.touch(); model.playPause() }
            .onMoveCommand { _ in model.wake() }
            .onExitCommand { model.wake() }
            .onChange(of: showing) { _, s in
                focused = false
                guard s else { return }
                // only once the button is enabled again (it's disabled while the dashboard shows - focus set in the same
                // instant was ignored, so the aerials never reacted to the remote); once more if it didn't take
                for t in [0.25, 0.8] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + t) { if showing && !focused { focused = true; model.refocus() } }
                }
            }
            .onChange(of: focused) { _, f in Log.shared.add("aerials button focused: \(f)") }
            .onAppear { if showing { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { focused = true } } }
    }
}

/// Keeps the idle timer honest without touching the remote's input: it only listens for the focus moving (any arrow or
/// swipe on the dashboard moves it; a press is recorded by the control itself; the aerials wake through their own
/// button and commands). Until 1.1 (27) this was a tap + pan recognizer on the whole window - it claimed every arrow and
/// Select press (delaysTouchesEnded left on) and the dashboard got none of them (2026-11-07: Right / Down on the real TV
/// moved nothing).
struct RemoteWatcher: UIViewRepresentable {
    let model: AppModel
    func makeUIView(context: Context) -> WatcherView { WatcherView(model: model) }
    func updateUIView(_ v: WatcherView, context: Context) {}

    final class WatcherView: UIView {
        private let model: AppModel
        private var token: NSObjectProtocol?
        private var lastLog = Date.distantPast
        init(model: AppModel) {
            self.model = model
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            token = NotificationCenter.default.addObserver(forName: UIFocusSystem.didUpdateNotification, object: nil, queue: .main) { [weak self] n in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.model.touch()
                    if Date().timeIntervalSince(self.lastLog) > 1 {
                        self.lastLog = Date()
                        let to = (n.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext)?.nextFocusedItem
                        var where_ = ""
                        if let v = to as? UIView, let w = v.window {      // where on screen (the "Home" anchor is 60x50 at the top left)
                            let f = v.convert(v.bounds, to: w)
                            where_ = " \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))"
                        }
                        Log.shared.add("focus: \(to.map { String(describing: type(of: $0)) } ?? "nothing")\(where_)")
                    }
                }
            }
        }
        required init?(coder: NSCoder) { fatalError() }
        deinit { if let token { NotificationCenter.default.removeObserver(token) } }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            MainActor.assumeIsolated {
                model.refocusHook = { [weak self] in
                    guard let w = self?.window, let vc = w.rootViewController else { Log.shared.add("refocus: no window"); return }
                    let before = FocusProbe.describe(w)
                    vc.setNeedsFocusUpdate()
                    vc.updateFocusIfNeeded()
                    Log.shared.add("refocus: \(before) -> \(FocusProbe.describe(w)) | key window \(w.isKeyWindow)")
                }
                model.whereHook = { [weak self] in
                    guard let w = self?.window else { return "no window" }
                    return FocusProbe.describe(w) + " | key window \(w.isKeyWindow)"
                }
            }
        }
    }
}

/// what has the focus, in words (diagnosis)
@MainActor enum FocusProbe {
    static func describe(_ w: UIWindow) -> String {
        guard let sys = w.windowScene?.focusSystem ?? UIFocusSystem.focusSystem(for: w) else { return "no focus system" }
        guard let item = sys.focusedItem else { return "nothing" }
        var s = String(describing: type(of: item))
        if let v = item as? UIView { s += " \(Int(v.frame.minX)),\(Int(v.frame.minY)) \(Int(v.frame.width))x\(Int(v.frame.height))" }
        return s
    }
}

/// a button that looks like nothing - no focus lift, no highlight (the ambient screen)
struct Bare: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

struct ToastView: View {
    let text: String
    var body: some View {
        VStack {
            if !text.isEmpty {
                Text(text).font(.title3.weight(.medium)).foregroundStyle(Theme.text)
                    .padding(.horizontal, 36).padding(.vertical, 22)
                    .background(Capsule().fill(.regularMaterial))
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer()
        }
        .padding(.top, 50)
        .animation(Theme.spring, value: text)
    }
}
