import Foundation
import SwiftUI

// MARK: - the headlines (top-left of the ambient screen)

/// Today's top headlines - 3 each of U.S., tech, gaming, movies & TV - with a short AI summary of each article.
/// Home Assistant does the work (custom_components/haven/news.py): the 6 AM and 6 PM editions, read and summarized only
/// while Haven is open in front, saved there. Haven just follows websocket haven/news and keeps the last copy on the
/// Apple TV too, so the corner fills at once even before Home Assistant answers.
///
/// All of them go into one shuffled deck: a new one every 2 minutes, none again until the deck is done, then a fresh
/// shuffle (never starting with the one just shown). A summary that arrives while its headline is up fades in where it is.
/// No headlines at all: the corner stays empty.
@MainActor
final class NewsModel: ObservableObject {
    struct Item: Equatable, Identifiable, Codable {
        let id: String, kind: String, kindLabel: String, title: String, source: String, date: Date?
        var status: String, summary: String
        /// why there's no summary (the GPU was busy, the AI PC was off...) - from Home Assistant
        var reason: String?

        var symbol: String {
            switch kind {
            case "us": return "newspaper.fill"
            case "tech": return "cpu.fill"
            case "gaming": return "gamecontroller.fill"
            case "movies": return "film.fill"
            default: return "newspaper.fill"
            }
        }
        /// what shows under the headline (`retry` / `waitReason`: the AI GPU wasn't free, Home Assistant tries again then)
        func line(retry: Date? = nil, waitReason: String? = nil, now: Date = Date()) -> String {
            switch status {
            case "ok": return summary
            case "reading": return "Fetching article…"
            case "summarizing":
                if let retry, retry > now {
                    let at = retry.formatted(date: .omitted, time: .shortened)
                    if let w = waitReason, !w.isEmpty { return "\(Self.sentence(w)) · trying again at \(at)" }
                    return "The AI GPU is busy · trying again at \(at)"
                }
                return "Generating summary…"
            case "no_content": return "Couldn't read this article to summarize it"
            default:
                if let r = reason, !r.isEmpty { return "AI summary unavailable: \(r)" }
                return "AI summary unavailable for this article"
            }
        }
        /// "the AI PC isn't reachable" -> "The AI PC isn't reachable"
        static func sentence(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
        var pending: Bool { status == "reading" || status == "summarizing" }
    }

    @Published private(set) var items: [Item] = []
    /// the AI summaries switch in Home Assistant (input_boolean.haven_ai_summaries): off, no summary line at all
    @Published private(set) var aiOn: Bool = UserDefaults.standard.object(forKey: "newsAI") as? Bool ?? true
    /// Google's free tier was busy: when Home Assistant asks again (shown instead of "Generating summary…")
    @Published private(set) var retryAt: Date?
    @Published private(set) var waitReason: String?
    /// the headline on screen now (always the latest copy of it: its summary may arrive while it's up)
    @Published private(set) var current: Item?
    private var deck: [String] = []          // ids left this round, shuffled
    private var turnTimer: Timer?
    private let ha: HAConnection
    static let turn: TimeInterval = 120
    private static let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("news.json")

    var any: Bool { !items.isEmpty }

    init(ha: HAConnection) {
        self.ha = ha
        if let d = try? Data(contentsOf: Self.cache), let saved = try? JSONDecoder().decode([Item].self, from: d) {
            apply(saved, log: false)
        }
        ha.onConnected.append { [weak self] in self?.subscribe() }
        if ha.status == .connected { subscribe() }
    }

    func start() {}                          // (kept for the app's start-up call; the stream starts on connect)

    private func subscribe() {
        _ = ha.subscribe(["type": "haven/news"]) { [weak self] ev in self?.receive(ev) }
    }

    private func receive(_ p: [String: Any]) {
        let retry = (p["retry_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        if retry != retryAt { withAnimation(.easeInOut(duration: 0.45)) { retryAt = retry } }
        let why = p["wait_reason"] as? String
        if why != waitReason { waitReason = why }
        let on = p["ai"] as? Bool ?? true
        if on != aiOn {
            withAnimation(.easeInOut(duration: 0.45)) { aiOn = on }
            UserDefaults.standard.set(on, forKey: "newsAI")
        }
        let list: [Item] = (p["items"] as? [[String: Any]] ?? []).compactMap { d in
            guard let id = d["id"] as? String, let title = d["title"] as? String, !title.isEmpty else { return nil }
            return Item(id: id, kind: d["kind"] as? String ?? "", kindLabel: d["kind_label"] as? String ?? "",
                        title: title, source: d["source"] as? String ?? "",
                        date: (d["date"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
                        status: d["status"] as? String ?? "unavailable", summary: d["summary"] as? String ?? "",
                        reason: d["reason"] as? String)
        }
        apply(list, log: true)
        if let data = try? JSONEncoder().encode(list) { try? data.write(to: Self.cache, options: .atomic) }
    }

    private func apply(_ list: [Item], log: Bool) {
        let newSet = Set(list.map(\.id)), oldSet = Set(items.map(\.id))
        if list != items { withAnimation(.easeInOut(duration: 0.5)) { items = list } }
        if newSet != oldSet {
            // a new edition: a fresh shuffle, starting now
            deck = []
            advance()
            turnTimer?.invalidate()
            turnTimer = Timer.scheduledTimer(withTimeInterval: Self.turn, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.advance() }
            }
            if log { Log.shared.add("news: \(list.count) headlines, \(list.filter { $0.status == "ok" }.count) summarized") }
        } else if let c = current, let fresh = list.first(where: { $0.id == c.id }), fresh != c {
            withAnimation(.easeInOut(duration: 0.45)) { current = fresh }      // its summary just arrived
        }
        if list.isEmpty { current = nil; turnTimer?.invalidate() }
    }

    /// the next card of this round's deck; with the deck done, a fresh shuffle of everything
    private func advance() {
        if deck.isEmpty {
            var d = items.map(\.id).shuffled()
            if d.count > 1, let c = current, d[0] == c.id { d.swapAt(0, Int.random(in: 1..<d.count)) }
            deck = d
        }
        while let next = deck.first {
            deck.removeFirst()
            if let it = items.first(where: { $0.id == next }) { current = it; return }
        }
        current = nil
    }

    /// "now", "25 min ago", "3 hr ago" - how long ago
    static func age(_ d: Date?, now: Date) -> String? {
        guard let d else { return nil }
        let m = Int(now.timeIntervalSince(d) / 60)
        if m < 0 { return nil }
        if m < 5 { return "now" }
        if m < 60 { return "\(m) min ago" }
        let h = m / 60
        return h < 48 ? "\(h) hr ago" : nil
    }
}

/// One headline, small and quiet: what kind and where from, the headline (two lines at most), then the AI summary in
/// smaller, softer type (three lines at most). A new one comes into focus as the old one leaves; a summary that arrives
/// while its headline is up fades in where the "Generating summary…" line was.
struct NewsCorner: View {
    let item: NewsModel.Item
    let now: Date
    var aiOn = true
    var retryAt: Date?
    var waitReason: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Image(systemName: item.symbol).font(.system(size: 14, weight: .semibold))
                    Text(item.kindLabel.uppercased()).font(.system(size: 15, weight: .semibold)).tracking(2.2)
                    Text("·").font(.system(size: 15, weight: .semibold))
                    Text(item.source).font(.system(size: 15, weight: .medium)).lineLimit(1)
                    if let a = NewsModel.age(item.date, now: now) {
                        Text("·").font(.system(size: 15, weight: .semibold))
                        Text(a).font(.system(size: 15, weight: .medium)).monospacedDigit()
                    }
                }
                .foregroundStyle(.white.opacity(0.6))
                // three lines, and a long one shrinks a little rather than end in "…" (2026-11-23)
                Text(item.title)
                    .font(.system(size: 23, weight: .regular)).foregroundStyle(.white.opacity(0.9))
                    .lineLimit(3).minimumScaleFactor(0.8).lineSpacing(2).multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if aiOn {
                    SummaryLine(item: item, retryAt: retryAt, waitReason: waitReason, now: now).padding(.top, 3)
                        .transition(.modifier(active: Drift(y: -4, blur: 6, scale: 1, opacity: 0), identity: Drift.rest))
                }
            }
            .frame(width: 560, alignment: .leading)
            .id(item.id)
            .transition(.asymmetric(
                insertion: .modifier(active: Drift(y: 10, blur: 8, scale: 1, opacity: 0), identity: Drift.rest)
                    .animation(.easeOut(duration: 0.55).delay(0.3)),
                removal: .modifier(active: Drift(y: -8, blur: 6, scale: 1, opacity: 0), identity: Drift.rest)
                    .animation(.easeIn(duration: 0.35))))
        }
        .animation(.easeInOut(duration: 0.5), value: item.id)
        .animation(.easeInOut(duration: 0.45), value: aiOn)
    }
}

/// the summary (or why there isn't one): a small sparkle marks it as AI-written - it pulses while it's being made
struct SummaryLine: View {
    let item: NewsModel.Item
    var retryAt: Date?
    var waitReason: String?
    var now = Date()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "sparkles").font(.system(size: 13, weight: .semibold))
                .symbolEffect(.pulse, options: .repeating, isActive: item.pending)
                .opacity(item.status == "ok" || item.pending ? 0.75 : 0.4)
            ZStack(alignment: .topLeading) {
                // three lines; a long one shrinks a little rather than end in "…" (2026-11-28)
                Text(item.line(retry: retryAt, waitReason: waitReason, now: now))
                    .font(.system(size: 18, weight: .regular))
                    .italic(item.status != "ok")
                    .foregroundStyle(.white.opacity(item.status == "ok" ? 0.72 : 0.45))
                    .lineLimit(3).minimumScaleFactor(0.78).lineSpacing(2).multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .id(item.status + item.summary + (retryAt.map { "\($0)" } ?? ""))
                    .transition(.modifier(active: Drift(y: 4, blur: 5, scale: 1, opacity: 0), identity: Drift.rest))
            }
        }
        .foregroundStyle(.white)
        .animation(.easeInOut(duration: 0.45), value: item.status + item.summary)
    }
}
