import AVFoundation
import SwiftUI
import UIKit

// MARK: - the videos

/// The ambient screen's videos: the NAS folder HomeAssistant\AppleTV (Apple's aerials + your own), listed and served by
/// Home Assistant. Each is downloaded once into the Apple TV's own storage and played from there - full 4K HDR, never
/// streamed, so the network can't make it stutter. Up to `budget` is kept (least recently shown goes first); a video
/// removed from the NAS is removed here too. The list is checked again every 10 minutes - a new video simply appears.
@MainActor
final class AerialLibrary: ObservableObject {
    struct Item: Equatable, Hashable {
        let path: String, size: Int64, mtime: Int, title: String
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var ready: [Item] = []
    @Published private(set) var downloading: Item?
    @Published private(set) var current: Item?
    @Published private(set) var listed = false

    private let rest: HAREST
    private let dir: URL
    private var running = false
    private var recent: [String] = []
    /// how much of the Apple TV's storage the videos may use (~35 of Apple's 71 at once), and what must stay free
    private let budget: Int64 = 30 * 1_000_000_000
    private let keepFree: Int64 = 12 * 1_000_000_000

    init(rest: HAREST) {
        self.rest = rest
        dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("aerials", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func start() {
        guard !running else { return }
        running = true
        Task { await loop() }
    }

    private func loop() async {
        while running {
            await refresh()
            await fill()
            try? await Task.sleep(for: .seconds(listed ? 600 : 60))
        }
    }

    func file(_ i: Item) -> URL {
        let safe = i.path.replacingOccurrences(of: "/", with: "__")
        return dir.appendingPathComponent("\(i.mtime)-\(safe)")
    }

    private func cached(_ i: Item) -> Bool {
        let a = try? FileManager.default.attributesOfItem(atPath: file(i).path)
        return (a?[.size] as? NSNumber)?.int64Value == i.size
    }

    private func refresh() async {
        do {
            let o = try await rest.json("api/haven/aerials", method: "GET", timeout: 60)
            let arr = o["items"] as? [[String: Any]] ?? []
            items = arr.compactMap { d in
                guard let p = d["path"] as? String, let s = (d["size"] as? NSNumber)?.int64Value else { return nil }
                return Item(path: p, size: s, mtime: (d["mtime"] as? NSNumber)?.intValue ?? 0, title: d["title"] as? String ?? "")
            }
            if !listed || ready.count != items.filter(cached).count {
                Log.shared.add("aerials: \(items.count) on the NAS, \(items.filter(cached).count) on this Apple TV\(o["mounted"] as? Bool == false ? " (the NAS folder isn't mounted in Home Assistant)" : "")")
            }
            listed = true
            prune()
            ready = items.filter(cached)
        } catch {
            Log.shared.add("aerials: couldn't list them (\(error.localizedDescription)) - again in a minute", level: .warning)
        }
    }

    /// files here that are no longer on the NAS (or were replaced by a newer copy) go
    private func prune() {
        let keep = Set(items.map { file($0).lastPathComponent })
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where !keep.contains(f) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
        }
    }

    private var usedBytes: Int64 { ready.reduce(0) { $0 + $1.size } }

    private var freeBytes: Int64 {
        let v = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return Int64(v?.volumeAvailableCapacity ?? 0)
    }

    /// download what's missing, one at a time: the smallest first (something to show quickly), then at random
    private func fill() async {
        while running {
            let missing = items.filter { !cached($0) }
            guard let next = ready.isEmpty ? missing.min(by: { $0.size < $1.size }) : missing.randomElement() else { return }
            while usedBytes + next.size > budget || freeBytes - next.size < keepFree {
                guard evictOne() else {
                    if ready.count >= 3 { return }                       // full - what's here is plenty
                    Log.shared.add("aerials: not enough free storage on the Apple TV for more", level: .warning); return
                }
            }
            downloading = next
            let t0 = Date()
            do {
                try await rest.download("api/haven/aerial", query: ["p": next.path], to: file(next))
                let s = Date().timeIntervalSince(t0)
                Log.shared.add(String(format: "aerials: got %@ (%.0f MB in %.0f s)", next.path, Double(next.size) / 1e6, s))
            } catch {
                Log.shared.add("aerials: \(next.path) didn't download (\(error.localizedDescription))", level: .warning)
                try? FileManager.default.removeItem(at: file(next))
                downloading = nil
                try? await Task.sleep(for: .seconds(60))
                return
            }
            downloading = nil
            ready = items.filter(cached)
        }
    }

    /// the least recently shown video goes (never the one on screen or the next ones)
    private func evictOne() -> Bool {
        let protected = Set([current?.path].compactMap { $0} + recent.suffix(2))
        let candidates = ready.filter { !protected.contains($0.path) }
        let date = { (i: Item) -> Date in
            ((try? FileManager.default.attributesOfItem(atPath: self.file(i).path))?[.modificationDate] as? Date) ?? .distantPast
        }
        guard let old = candidates.min(by: { date($0) < date($1) }) else { return false }
        try? FileManager.default.removeItem(at: file(old))
        ready.removeAll { $0 == old }
        return true
    }

    /// the next one to show: one not shown recently, at random
    func next() -> Item? {
        guard !ready.isEmpty else { return nil }
        let avoid = Set(recent.suffix(max(0, min(ready.count - 1, 12))))
        let pick = ready.filter { !avoid.contains($0.path) }.randomElement() ?? ready.randomElement()
        if let pick {
            recent.append(pick.path)
            if recent.count > 40 { recent.removeFirst(recent.count - 40) }
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file(pick).path)  // recency
            current = pick
        }
        return pick
    }
}

// MARK: - the player: two layers, a slow crossfade between videos

struct AerialPlayer: UIViewRepresentable {
    @ObservedObject var library: AerialLibrary
    let showing: Bool
    func makeUIView(context: Context) -> AerialPlayerView { AerialPlayerView(library: library) }
    func updateUIView(_ v: AerialPlayerView, context: Context) { v.showing = showing; v.kick() }
    static func dismantleUIView(_ v: AerialPlayerView, coordinator: ()) { v.stop() }
}

final class AerialPlayerView: UIView {
    private let library: AerialLibrary
    private let layers = [AVPlayerLayer(), AVPlayerLayer()]
    private var front = 0
    private var observer: Any?
    private var observerPlayer: AVPlayer?
    private var started = false
    /// on screen? Hidden under the dashboard the video stays loaded but paused, so it's there at once for the crossfade
    @MainActor var showing = true {
        didSet {
            guard showing != oldValue else { return }
            if showing { layers[front].player?.play() } else { layers.forEach { $0.player?.pause() } }
        }
    }
    static let fade: Double = 3.0

    init(library: AerialLibrary) {
        self.library = library
        super.init(frame: .zero)
        backgroundColor = .black
        for l in layers {
            l.videoGravity = .resizeAspectFill
            l.opacity = 0
            layer.addSublayer(l)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layers.forEach { $0.frame = bounds }
        CATransaction.commit()
    }

    /// start once there's something on the Apple TV to play
    @MainActor func kick() {
        guard !started, window != nil, !library.ready.isEmpty else { return }
        started = true
        advance()
    }

    @MainActor func stop() {
        if let o = observer { observerPlayer?.removeTimeObserver(o) }
        observer = nil
        layers.forEach { $0.player?.pause(); $0.player = nil }
    }

    @MainActor private func advance() {
        guard let item = library.next() else { started = false; return }
        let back = 1 - front
        let player = AVPlayer(url: library.file(item))
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false        // Haven decides about sleep (keepAwake)
        player.actionAtItemEnd = .pause
        layers[back].player = player
        if showing { player.play() }
        Log.shared.add("ambient: \(item.title) (\(item.path))")
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self, weak player] in
            guard let self, self.showing, let player, let it = player.currentItem else { return }
            let ok = it.status == .readyToPlay && player.timeControlStatus == .playing
            Log.shared.add(String(format: "ambient: %@ at %.1f s (%@)%@", ok ? "playing" : "NOT playing", it.currentTime().seconds,
                                  "\(it.presentationSize.width)x\(it.presentationSize.height)",
                                  it.error.map { " - \($0.localizedDescription)" } ?? ""), level: ok ? .info : .warning)
        }
        NotificationCenter.default.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: player.currentItem, queue: .main) { n in
            let e = n.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Log.shared.add("ambient: \(item.path) stopped - \(e?.localizedDescription ?? "?")", level: .warning)
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let asset = AVURLAsset(url: self.library.file(item))
            let duration = (try? await asset.load(.duration))?.seconds ?? 0
            // (no preferredDisplayCriteria: setting it raised an exception and killed the app on 2026-11-03; the Apple
            // TV's own Match Content settings decide the TV's picture mode)
            // crossfade in
            CATransaction.begin(); CATransaction.setAnimationDuration(Self.fade)
            self.layers[back].opacity = 1
            self.layers[self.front].opacity = 0
            CATransaction.commit()
            let old = self.layers[self.front].player
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.fade + 0.2) { old?.pause(); if self.layers[1 - back].player === old { self.layers[1 - back].player = nil } }
            self.front = back
            // the next one starts fading in a little before this one ends
            if let o = self.observer { self.observerPlayer?.removeTimeObserver(o) }
            let at = max(5, duration - Self.fade - 0.5)
            self.observerPlayer = player
            self.observer = player.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(seconds: at, preferredTimescale: 600))], queue: .main) { [weak self] in
                Task { @MainActor in self?.advance() }
            }
        }
    }
}

// MARK: - the ambient screen

struct AmbientView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var ha: HAConnection
    @ObservedObject var library: AerialLibrary
    let showing: Bool
    @State private var drift = CGSize.zero
    private let driftTimer = Timer.publish(every: 90, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Theme.backdrop
            AerialPlayer(library: library, showing: showing).ignoresSafeArea()
            // just enough shade at the edges for the text to read over any sky
            VStack {
                LinearGradient(colors: [.black.opacity(0.38), .clear], startPoint: .top, endPoint: .bottom).frame(height: 260)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .top, endPoint: .bottom).frame(height: 360)
            }
            .ignoresSafeArea()
            AmbientChrome(library: library, upNext: model.upNext, alerts: model.alerts).offset(drift)
        }
        .onReceive(driftTimer) { _ in
            // OLED care: everything drawn over the video wanders a few pixels, slowly
            withAnimation(.easeInOut(duration: 12)) { drift = CGSize(width: .random(in: -22...22), height: .random(in: -14...14)) }
        }
    }
}

/// what's drawn over the video - small, quiet, in the corners: the time (not the star), the place, what's playing
/// (and what's next), the weather and the room, and anything that needs attention. Everything that comes and goes
/// does it the same way: a slight scale from its own corner with a fade (`.pop`).
struct AmbientChrome: View {
    @EnvironmentObject var ha: HAConnection
    @EnvironmentObject var model: AppModel
    @ObservedObject var library: AerialLibrary
    @ObservedObject var upNext: UpNextModel
    @ObservedObject var alerts: Alerts

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let np = NowPlaying.pick(ha)
            let up = upNext.shown(np, at: ctx.date)
            ZStack {
                // bottom-left: time · date · place
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(Self.hm.string(from: ctx.date))
                            .font(.system(size: 84, weight: .thin)).monospacedDigit().tracking(-2)
                            .foregroundStyle(.white.opacity(0.94))
                        Text(Self.ampm.string(from: ctx.date))
                            .font(.system(size: 26, weight: .regular)).tracking(0.5)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    Text(ctx.date, format: .dateTime.weekday(.wide).month(.wide).day())
                        .font(.system(size: 27, weight: .regular)).tracking(0.1)
                        .foregroundStyle(.white.opacity(0.80))
                        .padding(.top, -2)
                    if let place = library.current?.title, !place.isEmpty {
                        HStack(spacing: 9) {
                            Image(systemName: "location.fill").font(.system(size: 15, weight: .semibold))
                            Text(place.uppercased()).font(.system(size: 18, weight: .semibold)).tracking(2.6)
                        }
                        .foregroundStyle(.white.opacity(0.62))
                        .padding(.top, 14)
                        .id(place)
                        .transition(.asymmetric(insertion: .opacity.animation(.easeIn(duration: 0.7).delay(0.6)),
                                                removal: .opacity.animation(.easeOut(duration: 0.5))))
                    }
                    if library.ready.isEmpty {
                        Text(library.listed ? (library.items.isEmpty ? "No videos in HomeAssistant ▸ AppleTV yet" : "Bringing the first aerial over from your NAS…")
                                            : "Looking for your aerials…")
                            .font(.system(size: 20)).foregroundStyle(.white.opacity(0.55)).padding(.top, 10)
                            .transition(.pop(.bottomLeading))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

                // bottom-right: what's next (the last seconds of a Spotify track), what's playing
                VStack(alignment: .trailing, spacing: 18) {
                    if let up {
                        UpNextCard(track: up, art: upNext.art[up.id], seconds: upNext.remaining(np, at: ctx.date))
                            .id("next-" + up.id)
                            .transition(.pop(.bottomTrailing))
                    }
                    if let np {
                        NowPlayingChip(np: np, now: ctx.date)
                            .id("np-" + np.entity)
                            .transition(.pop(.bottomTrailing))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)

                // top-right: weather + room, then what needs attention - out of the way while a notification shows
                InfoChips()
                    .opacity(alerts.notes.isEmpty ? 1 : 0)
                    .scaleEffect(alerts.notes.isEmpty ? 1 : 0.96, anchor: .topTrailing)
                    .animation(.easeInOut(duration: 0.5), value: alerts.notes.isEmpty)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

                // top-left: only when Home Assistant is away (it all keeps playing meanwhile)
                if ha.status != .connected {
                    HStack(spacing: 10) {
                        Circle().fill(Theme.warn).frame(width: 10, height: 10)
                        Text("Reconnecting to Home Assistant").font(.system(size: 20, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .transition(.pop(.topLeading))
                }
            }
            .shadow(color: .black.opacity(0.42), radius: 1.5, y: 1)
            .shadow(color: .black.opacity(0.38), radius: 22, y: 4)
            .animation(.spring(response: 0.6, dampingFraction: 0.86), value: np?.entity)
            .animation(.spring(response: 0.6, dampingFraction: 0.86), value: up?.id)
            .animation(.spring(response: 0.6, dampingFraction: 0.86), value: ha.status == .connected)
            .padding(.horizontal, 100).padding(.vertical, 66)
        }
    }

    static let hm: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("hmm"); f.amSymbol = ""; f.pmSymbol = ""; return f }()
    static let ampm: DateFormatter = { let f = DateFormatter(); f.dateFormat = "a"; return f }()
}

extension AnyTransition {
    /// Haven's way in and out for anything on the ambient screen: a slight scale from its own corner, with a fade
    static func pop(_ anchor: UnitPoint) -> AnyTransition {
        .asymmetric(insertion: .scale(scale: 0.88, anchor: anchor).combined(with: .opacity),
                    removal: .scale(scale: 0.94, anchor: anchor).combined(with: .opacity))
    }
}

struct NowPlaying: Equatable {
    let entity: String, title: String, subtitle: String, paused: Bool, picture: String
    let duration: Double?, position: Double?, updatedAt: Date?, contentID: String, repeatMode: String

    var spotify: Bool { entity == "media_player.spotify" || contentID.hasPrefix("spotify:") }
    var hasTime: Bool { (duration ?? 0) > 0 && position != nil }

    /// where it is now: Home Assistant reports the position with the moment it was read; while playing it runs on
    func elapsed(at now: Date) -> Double {
        guard var t = position else { return 0 }
        if !paused, let u = updatedAt { t += now.timeIntervalSince(u) }
        return min(max(0, t), duration ?? t)
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    /// the same choice as the tablet's clock: playing beats paused, then Spotify, Apple TV, LG C5, soundbar, then others
    @MainActor static func pick(_ ha: HAConnection) -> NowPlaying? {
        let order = ["media_player.spotify", "media_player.bedroom_tv", "media_player.lg_c5", "media_player.192_168_50_90"]
        let rank = ["playing": 5, "paused": 4, "buffering": 4]
        let others = ha.states.keys.filter { $0.hasPrefix("media_player.") && !order.contains($0) }.sorted()
        var best: (String, Int)?
        for id in order + others {
            guard let e = ha.state(id), let r = rank[e.state] else { continue }
            let title: String = e.attr("media_title") ?? ""
            let app: String = e.attr("app_name") ?? ""
            if title.isEmpty && app.isEmpty { continue }
            if best == nil || r > best!.1 { best = (id, r) }
        }
        guard let (id, _) = best, let e = ha.state(id) else { return nil }
        let title: String = e.attr("media_title") ?? (e.attr("app_name") ?? "")
        let artist: String = e.attr("media_artist") ?? (e.attr("media_series_title") ?? "")
        let app: String = e.attr("app_name") ?? ""
        let num = { (k: String) -> Double? in (e.attributes[k] as? NSNumber)?.doubleValue }
        let upd: String = e.attr("media_position_updated_at") ?? ""
        return NowPlaying(entity: id, title: title, subtitle: artist.isEmpty ? app : artist, paused: e.state != "playing",
                          picture: e.attr("entity_picture") ?? "", duration: num("media_duration"), position: num("media_position"),
                          updatedAt: iso.date(from: upd) ?? isoPlain.date(from: upd), contentID: e.attr("media_content_id") ?? "",
                          repeatMode: e.attr("repeat") ?? "off")
    }

    static func clock(_ s: Double) -> String {
        let t = max(0, Int(s.rounded(.down)))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// Where the media is, smoothly: anchored to Home Assistant's report, then running on the TV's own clock. A new report
/// only moves it when it's really different (a seek, a skip, a pause, a drift over 1.5 s) - the reports are whole
/// seconds, so taking each as-is made the counter jump.
@MainActor
final class PlaybackClock {
    static let shared = PlaybackClock()
    private var key = ""
    private var anchorPos = 0.0
    private var anchorAt = Date()
    private var running = false

    /// the position now, in seconds
    func position(_ np: NowPlaying, at now: Date = Date()) -> Double {
        let k = np.entity + "|" + np.contentID + "|" + np.title
        let reported = np.elapsed(at: now)
        let estimate = running ? anchorPos + now.timeIntervalSince(anchorAt) : anchorPos
        if k != key || running == np.paused || abs(reported - estimate) > 1.5 {
            key = k; running = !np.paused; anchorPos = reported; anchorAt = now
            return reported
        }
        return min(estimate, np.duration ?? estimate)
    }

    /// the moment the counter's next second begins (so the display ticks on the song's seconds, not the wall clock's)
    func tickAnchor() -> Date { anchorAt.addingTimeInterval(-anchorPos.truncatingRemainder(dividingBy: 1)) }
}

struct NowPlayingChip: View {
    let np: NowPlaying
    let now: Date
    @EnvironmentObject var model: AppModel
    @State private var art: UIImage?
    @State private var artFor = ""

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .trailing, spacing: 5) {
                HStack(spacing: 9) {
                    if np.paused {
                        Image(systemName: "pause.fill").font(.system(size: 17)).foregroundStyle(.white.opacity(0.62))
                            .transition(.scale(scale: 0.5).combined(with: .opacity))
                    }
                    Text(np.title).font(.system(size: 27, weight: .regular)).foregroundStyle(.white.opacity(0.92)).lineLimit(1)
                }
                if !np.subtitle.isEmpty {
                    Text(np.subtitle).font(.system(size: 23, weight: .light)).foregroundStyle(.white.opacity(0.70)).lineLimit(1)
                }
                if np.hasTime, let d = np.duration {
                    let clock = PlaybackClock.shared
                    let _ = clock.position(np)                                       // re-anchor on a new report
                    TimelineView(.periodic(from: clock.tickAnchor(), by: 1)) { _ in
                        let el = clock.position(np)
                        HStack(spacing: 12) {
                            Text("\(NowPlaying.clock(el)) / \(NowPlaying.clock(d))")
                                .font(.system(size: 19, weight: .regular)).monospacedDigit().foregroundStyle(.white.opacity(0.66))
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(.white.opacity(0.22))
                                    Capsule().fill(.white.opacity(0.85)).frame(width: max(4, g.size.width * CGFloat(min(1, el / max(d, 1)))))
                                }
                            }
                            .frame(width: 170, height: 4)
                            .animation(np.paused ? nil : .linear(duration: 1), value: Int(el))
                        }
                    }
                    .padding(.top, 7)
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: 540, alignment: .trailing)
            .animation(.spring(response: 0.45, dampingFraction: 0.8), value: np.paused)
            // the cover's place is kept from the start (nothing slides when it arrives); paused, it sinks back a little
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white.opacity(0.10))
                Image(systemName: "music.note").font(.system(size: 38, weight: .medium)).foregroundStyle(.white.opacity(0.35))
                if let art { Image(uiImage: art).resizable().scaledToFill().transition(.opacity) }
            }
            .frame(width: 120, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1))
            .scaleEffect(np.paused ? 0.84 : 1)
            .opacity(np.paused ? 0.72 : 1)
            .animation(.spring(response: 0.5, dampingFraction: 0.7), value: np.paused)
        }
        .task(id: np.picture) { await loadArt() }
    }

    private func loadArt() async {
        guard !np.picture.isEmpty else { withAnimation(.easeInOut(duration: 0.4)) { art = nil }; artFor = ""; return }
        guard np.picture != artFor else { return }
        artFor = np.picture
        // entity_picture is a path on Home Assistant (with its own access token) - fetched with the app's TLS check
        var path = np.picture
        var query: [String: String] = [:]
        if let c = URLComponents(string: np.picture) {
            path = c.path
            for q in c.queryItems ?? [] { query[q.name] = q.value ?? "" }
        }
        if let (d, code) = try? await model.rest.request(path, method: "GET", query: query, timeout: 15), code == 200, let img = UIImage(data: d) {
            withAnimation(.easeInOut(duration: 0.6)) { art = img }
        }
    }
}

// MARK: - up next (Spotify)

/// What Spotify plays next, shown in a track's last 10 seconds. Asked fresh from Spotify's own queue near the end of
/// each track (25 s before, and again inside the last 11 s), so a skip, a seek, songs added or removed, a reshuffle or a
/// new playlist all show what will really play. Nothing when the queue's empty, on repeat-one, or paused.
@MainActor
final class UpNextModel: ObservableObject {
    struct Track: Equatable { let id: String, title: String, artist: String, image: String }
    @Published private(set) var next: Track?
    @Published private(set) var art: [String: UIImage] = [:]
    private var forTrack = ""          // the playing track the answer belongs to
    private var lastAsk = Date.distantPast
    private var asking = false
    private let ha: HAConnection
    private var timer: Timer?

    init(ha: HAConnection) {
        self.ha = ha
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
    }

    private static func trackID(_ np: NowPlaying) -> String {
        np.contentID.components(separatedBy: ":").last ?? np.contentID
    }

    func remaining(_ np: NowPlaying?, at now: Date) -> Int {
        guard let np, let d = np.duration else { return 0 }
        return max(0, Int((d - PlaybackClock.shared.position(np, at: now)).rounded(.up)))
    }

    private func tick() {
        guard ha.status == .connected, let np = NowPlaying.pick(ha), np.spotify, np.hasTime, !np.paused, let d = np.duration else { return }
        let left = d - np.elapsed(at: Date())
        let id = Self.trackID(np)
        let since = Date().timeIntervalSince(lastAsk)
        let first = left <= 25 && forTrack != id && since > 4                     // the first ask for this track
        let fresh = left <= 11 && left > 2 && since > 12                          // again at the end: a queue edited meanwhile
        if (first || fresh) && !asking { ask(for: id) }
    }

    private func ask(for id: String) {
        asking = true
        lastAsk = Date()
        Task {
            defer { asking = false }
            guard let r = try? await ha.command(["type": "haven/spotify_queue"]) as? [String: Any] else { return }
            let cur = (r["current"] as? [String: Any])?["id"] as? String
            guard cur == id else { forTrack = ""; return }                       // Spotify hasn't caught up yet: ask again
            forTrack = id
            if let n = r["next"] as? [String: Any], let nid = n["id"] as? String {
                let t = Track(id: nid, title: n["title"] as? String ?? "", artist: n["artist"] as? String ?? "", image: n["image"] as? String ?? "")
                if t != next { Log.shared.add("up next: \(t.title) - \(t.artist)") }
                next = t
                loadArt(t)
            } else {
                next = nil
            }
        }
    }

    private func loadArt(_ t: Track) {
        guard art[t.id] == nil, let u = URL(string: t.image), u.scheme == "https" else { return }
        Task {
            if let (d, r) = try? await URLSession.shared.data(from: u), (r as? HTTPURLResponse)?.statusCode == 200, let img = UIImage(data: d) {
                art[t.id] = img
                if art.count > 20 { art = art.filter { $0.key == t.id } }
            }
        }
    }

    /// the card to show now, if any: Spotify, playing, the last 10 s, and the answer is about this very track
    func shown(_ np: NowPlaying?, at now: Date) -> Track? {
        guard let np, np.spotify, !np.paused, np.hasTime, np.repeatMode != "one", let next, forTrack == Self.trackID(np),
              let d = np.duration else { return nil }
        let left = d - PlaybackClock.shared.position(np, at: now)
        return left <= 10 && left > 0.3 ? next : nil
    }
}

struct UpNextCard: View {
    let track: UpNextModel.Track
    let art: UIImage?
    let seconds: Int

    var body: some View {
        // mirrors the media chip under it: text right-aligned, the cover on the right edge
        HStack(spacing: 16) {
            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 8) {
                    Text("in \(seconds) s").font(.system(size: 14, weight: .medium)).monospacedDigit().opacity(0.7)
                    Text("UP NEXT").font(.system(size: 14, weight: .semibold)).tracking(2.6)
                }
                .foregroundStyle(.white.opacity(0.6))
                Text(track.title).font(.system(size: 23, weight: .regular)).foregroundStyle(.white.opacity(0.92)).lineLimit(1)
                if !track.artist.isEmpty {
                    Text(track.artist).font(.system(size: 19, weight: .light)).foregroundStyle(.white.opacity(0.68)).lineLimit(1)
                }
            }
            .frame(maxWidth: 380, alignment: .trailing)
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.white.opacity(0.1))
                Image(systemName: "music.note").font(.system(size: 20)).foregroundStyle(.white.opacity(0.35))
                if let art { Image(uiImage: art).resizable().scaledToFill().transition(.opacity) }
            }
            .frame(width: 62, height: 62)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .padding(14).padding(.leading, 14)
        .fixedSize(horizontal: true, vertical: false)
        .background {
            let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
            ZStack { shape.fill(.ultraThinMaterial); shape.fill(.black.opacity(0.28)) }
                .overlay(shape.strokeBorder(.white.opacity(0.13), lineWidth: 1))
        }
        .animation(.easeInOut(duration: 0.4), value: art != nil)
    }
}

/// top-right, one quiet line or two: outside · inside, then what needs attention (missed calls, the air, filters)
struct InfoChips: View {
    @EnvironmentObject var ha: HAConnection

    var body: some View {
        VStack(alignment: .trailing, spacing: 14) {
            HStack(spacing: 30) {
                if let w = ha.state("weather.openweathermap"), let t: Double = num(w.attributes["temperature"]) {
                    Reading(symbol: Self.weatherSymbol(w.state), multicolor: true, temp: t, humidity: num(w.attributes["humidity"]), label: "Outside")
                }
                if let t = Double(ha.state("sensor.h5075_e228_temperature")?.state ?? "") {
                    Reading(symbol: "house.fill", multicolor: false, temp: t,
                            humidity: Double(ha.state("sensor.h5075_e228_humidity")?.state ?? ""), label: "Inside")
                }
            }
            ForEach(attention, id: \.self) { a in
                Text(a.text).font(.system(size: 19, weight: .semibold)).foregroundStyle(a.red ? Color(red: 1, green: 0.55, blue: 0.52) : Theme.warn)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Capsule().fill(.black.opacity(0.28)))
                    .transition(.pop(.topTrailing))
            }
        }
        .animation(.spring(response: 0.6, dampingFraction: 0.86), value: attention)
    }

    struct Note: Hashable { let text: String; let red: Bool }

    /// one reading: icon, temperature (the figure), humidity beside it, a small caption under
    struct Reading: View {
        let symbol: String, multicolor: Bool, temp: Double, humidity: Double?, label: String
        var body: some View {
            VStack(alignment: .center, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: symbol)
                        .symbolRenderingMode(multicolor ? .multicolor : .hierarchical)
                        .font(.system(size: 26, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                    Text("\(Int(temp.rounded()))°").font(.system(size: 34, weight: .light)).monospacedDigit().foregroundStyle(.white.opacity(0.94))
                    if let h = humidity {
                        HStack(spacing: 3) {
                            Image(systemName: "drop.fill").font(.system(size: 14, weight: .semibold))
                            Text("\(Int(h.rounded()))%").font(.system(size: 21, weight: .medium)).monospacedDigit()
                        }
                        .foregroundStyle(.white.opacity(0.68))
                    }
                }
                Text(label.uppercased()).font(.system(size: 14, weight: .semibold)).tracking(2.2).foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    /// only things that need attention, like the clock's chips
    private var attention: [Note] {
        var out: [Note] = []
        let bad: Set<String> = ["unknown", "unavailable", "none", ""]
        if ha.state("input_boolean.iphone_alerts")?.state == "on", let n = Int(ha.state("todo.missed_calls")?.state ?? ""), n > 0 {
            out.append(Note(text: n == 1 ? "1 missed call" : "\(n) missed calls", red: true))
        }
        let f = ha.state("sensor.xiaomi_lite_c0ac_device_fault")?.state ?? ""
        if !bad.contains(f.lowercased()) && !["no faults", "no fault"].contains(f.lowercased()) { out.append(Note(text: "Dehumidifier: \(f)", red: true)) }
        let q = ha.state("sensor.vital_100s_series_air_quality")?.state ?? ""
        if !bad.contains(q.lowercased()) && !["excellent", "good"].contains(q.lowercased()) { out.append(Note(text: "Air \(q.lowercased())", red: false)) }
        if let l = Int(ha.state("sensor.vital_100s_series_filter_lifetime")?.state ?? ""), l <= 10 { out.append(Note(text: "Purifier filter \(l)%", red: false)) }
        if let l = Int(ha.state("sensor.air_conditioner_filter_remaining_life")?.state ?? ""), l <= 10 { out.append(Note(text: "AC filter \(l)%", red: false)) }
        return out
    }

    private func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap(Double.init) }

    static func weatherSymbol(_ s: String) -> String {
        switch s {
        case "clear-night": return "moon.stars.fill"
        case "sunny": return "sun.max.fill"
        case "partlycloudy": return "cloud.sun.fill"
        case "cloudy": return "cloud.fill"
        case "fog": return "cloud.fog.fill"
        case "rainy": return "cloud.rain.fill"
        case "pouring": return "cloud.heavyrain.fill"
        case "lightning", "lightning-rainy": return "cloud.bolt.rain.fill"
        case "snowy", "snowy-rainy": return "cloud.snow.fill"
        case "windy", "windy-variant": return "wind"
        case "hail": return "cloud.hail.fill"
        default: return "cloud.fill"
        }
    }
}
