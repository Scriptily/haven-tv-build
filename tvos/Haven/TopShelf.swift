import SwiftUI
import TVServices
import UIKit

/// Keeps the Top Shelf snapshot fresh (every 30 s while Haven runs): Now playing (with its cover), Quick controls (the
/// Apple TV dashboard's tiles that do something - scripts, scenes, lights, switches, buttons), and Haven itself
/// (Ambient, Dashboard). Images are drawn here in Haven's dark-glass look; tvOS is told when anything changed.
@MainActor
final class TopShelfWriter {
    private let model: AppModel
    private var last: SharedStore.Shelf?
    private var timer: Timer?
    private var artFor = ""
    private var warned = false
    private var pausedSince: Date?
    private var lastWritten = Date.distantPast

    init(model: AppModel) {
        self.model = model
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in Task { @MainActor in await self?.write() } }
        Task { try? await Task.sleep(for: .seconds(8)); await write() }
    }

    private var extSeen = ""

    /// what the Top Shelf extension wrote in its log since the last look (it has no other way to report)
    private func relayExtensionLog(_ dir: URL) {
        guard let s = try? String(contentsOf: dir.appendingPathComponent("ext.log"), encoding: .utf8) else { return }
        let lines = s.split(separator: "\n").map(String.init)
        let new = extSeen.isEmpty ? Array(lines.suffix(3)) : Array(lines.drop(while: { $0 <= extSeen }))
        if let last = lines.last { extSeen = last }
        for l in new { Log.shared.add("top shelf extension: \(l)") }
    }

    func write() async {
        if let dir = SharedStore.container { relayExtensionLog(dir) }
        guard let dir = SharedStore.container else {
            if !warned { Log.shared.add("top shelf: no shared container (App Group \(SharedStore.groupID ?? "not granted")) - Top Shelf stays static", level: .warning); warned = true }
            return
        }
        var sections: [SharedStore.Shelf.Section] = []

        // paused for 10 min: not "now playing" any more - the shelf drops it (the cover used to stay for good)
        let pick = NowPlaying.pick(model.ha)
        if let np = pick, np.paused { pausedSince = pausedSince ?? Date() } else { pausedSince = nil }
        if let np = pick, !(np.paused && Date().timeIntervalSince(pausedSince ?? Date()) > 10 * 60) {
            let file = "np-\(Self.stableHash(np.picture)).jpg"
            if np.picture != artFor || !FileManager.default.fileExists(atPath: dir.appendingPathComponent(file).path) {
                await saveArt(np, to: dir.appendingPathComponent(file))
                artFor = np.picture
            }
            let title = np.subtitle.isEmpty ? np.title : "\(np.title) — \(np.subtitle)"
            sections.append(.init(title: np.paused ? "Paused" : "Now Playing", square: true,
                                  items: [.init(id: "np", title: title, image: file, url: "haven://ambient")]))
        }

        var controls: [SharedStore.Shelf.Item] = []
        let doable: Set<String> = ["script", "scene", "light", "switch", "input_boolean", "button", "fan"]
        for s in model.dashboard.sections {
            for c in s.cards {
                guard case .tile(let t) = c.card else { continue }
                let domain = String(t.entity.split(separator: ".").first ?? "")
                guard doable.contains(domain), controls.count < 12 else { continue }
                let e = model.ha.state(t.entity)
                let name = t.name ?? e?.name ?? t.entity
                let on = Look.isOn(domain: domain, state: e?.state ?? "")
                let symbol = Icons.sf(t.icon ?? (e?.attr("icon") ?? ""), domain: domain, deviceClass: e?.attr("device_class"), state: e?.state ?? "")
                let file = "c3-\(t.entity)-\(on ? 1 : 0)-\(Self.stableHash(name)).png"
                let path = dir.appendingPathComponent(file)
                if !FileManager.default.fileExists(atPath: path.path) {
                    Self.tile(symbol: symbol, tint: Look.color(t.color, domain: domain), on: on, label: name, badge: on ? "On" : nil)
                        .flatMap { $0.pngData() }.map { try? $0.write(to: path) }
                }
                let q = t.entity.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "._"))) ?? t.entity
                let n = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
                controls.append(.init(id: t.entity, title: name, image: file, url: "haven://run?entity=\(q)&name=\(n)"))
            }
        }
        if !controls.isEmpty { sections.append(.init(title: "Quick Controls", square: false, items: controls)) }

        for (file, sym, label) in [("h3-ambient.png", "sparkles.tv", "Ambient"), ("h3-dashboard.png", "square.grid.2x2.fill", "Dashboard")] {
            let path = dir.appendingPathComponent(file)
            if !FileManager.default.fileExists(atPath: path.path) {
                Self.tile(symbol: sym, tint: Theme.accent, on: true, label: label).flatMap { $0.pngData() }.map { try? $0.write(to: path) }
            }
        }
        sections.append(.init(title: "Haven", square: false, items: [
            .init(id: "ambient", title: "Ambient", image: "h3-ambient.png", url: "haven://ambient"),
            .init(id: "dashboard", title: "Dashboard", image: "h3-dashboard.png", url: "haven://dashboard"),
        ]))

        // rewritten when something changed, and at least every 5 min (the timestamp tells the extension Haven is alive)
        let shelf = SharedStore.Shelf(sections: sections, written: Date().timeIntervalSince1970)
        let changed = shelf.sections != last?.sections
        guard changed || Date().timeIntervalSince(lastWritten) > 5 * 60 else { return }
        guard let f = SharedStore.topShelfFile, let data = try? JSONEncoder().encode(shelf) else { return }
        lastWritten = Date()
        do {
            try data.write(to: f, options: .atomic)
            if last == nil { Log.shared.add("top shelf: \(sections.map { "\($0.title) \($0.items.count)" }.joined(separator: ", "))") }
            last = shelf
            // keep what's in this snapshot AND everything tvOS may still be showing from an earlier one
            let keep = Set(sections.flatMap { $0.items.map(\.image) }).union(SharedStore.servedImages)
            for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where !keep.contains(f) && f != "topshelf.json" && f != "ext.log" && f != "served.json" && !f.hasPrefix(".") {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
            }
            if changed { TVTopShelfContentProvider.topShelfContentDidChange() }
        } catch {
            Log.shared.add("top shelf: couldn't save (\(error.localizedDescription))", level: .warning)
        }
    }

    private func saveArt(_ np: NowPlaying, to url: URL) async {
        var img: UIImage?
        if !np.picture.isEmpty {
            var path = np.picture, query: [String: String] = [:]
            if let c = URLComponents(string: np.picture) { path = c.path; for q in c.queryItems ?? [] { query[q.name] = q.value ?? "" } }
            if let (d, code) = try? await model.rest.request(path, method: "GET", query: query, timeout: 15), code == 200 { img = UIImage(data: d) }
        }
        var out = img ?? Self.tile(symbol: "music.note", tint: Theme.accent, on: true, size: CGSize(width: 600, height: 600))
        if let src = out {
            let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1; fmt.preferredRange = .standard; fmt.opaque = true
            out = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 600), format: fmt).image { _ in
                src.draw(in: CGRect(x: 0, y: 0, width: 600, height: 600))
            }
        }
        try? out?.jpegData(compressionQuality: 0.9)?.write(to: url)
    }

    /// a hash that's the same on every launch (file names must not change between runs)
    static func stableHash(_ s: String) -> String {
        var h: UInt32 = 2166136261
        for b in s.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return String(h, radix: 16)
    }

    /// a Top Shelf tile in Haven's look: deep glass, a soft glow in the tile's color, the symbol in the middle
    static func tile(symbol: String, tint: Color, on: Bool, label: String? = nil, badge: String? = nil,
                     size: CGSize = CGSize(width: 808, height: 456)) -> UIImage? {
        let ui = UIColor(tint)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.preferredRange = .standard
        fmt.opaque = true
        let r = UIGraphicsImageRenderer(size: size, format: fmt)
        return r.image { ctx in
            let c = ctx.cgContext
            let cs = CGColorSpaceCreateDeviceRGB()
            let bg = CGGradient(colorsSpace: cs, colors: [UIColor(red: 0.10, green: 0.09, blue: 0.15, alpha: 1).cgColor,
                                                          UIColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
            c.drawLinearGradient(bg, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            let glow = CGGradient(colorsSpace: cs, colors: [ui.withAlphaComponent(on ? 0.45 : 0.18).cgColor, ui.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
            let mid = CGPoint(x: size.width / 2, y: size.height / 2)
            c.drawRadialGradient(glow, startCenter: mid, startRadius: 0, endCenter: mid, endRadius: size.height * 0.75, options: [])
            // with a name, the symbol sits a little higher and the name goes underneath (bottom-left, like a tile)
            let symMid = label == nil ? mid : CGPoint(x: mid.x, y: size.height * 0.40)
            let cfg = UIImage.SymbolConfiguration(pointSize: size.height * (label == nil ? 0.30 : 0.24), weight: .semibold)
            if let sym = UIImage(systemName: symbol, withConfiguration: cfg)?.withTintColor(on ? ui : UIColor(white: 0.9, alpha: 1), renderingMode: .alwaysOriginal) {
                sym.draw(at: CGPoint(x: symMid.x - sym.size.width / 2, y: symMid.y - sym.size.height / 2))
            }
            if let label {
                let shade = CGGradient(colorsSpace: cs, colors: [UIColor(white: 0, alpha: 0).cgColor, UIColor(white: 0, alpha: 0.55).cgColor] as CFArray, locations: [0, 1])!
                c.drawLinearGradient(shade, start: CGPoint(x: 0, y: size.height * 0.55), end: CGPoint(x: 0, y: size.height), options: [])
                let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
                let font = UIFont.systemFont(ofSize: size.height * 0.105, weight: .semibold)
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor(white: 1, alpha: 0.95), .paragraphStyle: para]
                let pad = size.width * 0.06
                (label as NSString).draw(in: CGRect(x: pad, y: size.height - pad - font.lineHeight, width: size.width - 2 * pad - (badge == nil ? 0 : size.width * 0.16), height: font.lineHeight), withAttributes: attrs)
                if let badge {
                    let bf = UIFont.systemFont(ofSize: size.height * 0.07, weight: .bold)
                    let bs = (badge as NSString).size(withAttributes: [.font: bf])
                    let br = CGRect(x: size.width - pad - bs.width - 28, y: size.height - pad - font.lineHeight / 2 - bs.height / 2 - 6, width: bs.width + 28, height: bs.height + 12)
                    ui.withAlphaComponent(0.9).setFill(); UIBezierPath(roundedRect: br, cornerRadius: br.height / 2).fill()
                    (badge as NSString).draw(at: CGPoint(x: br.minX + 14, y: br.minY + 6), withAttributes: [.font: bf, .foregroundColor: UIColor.black.withAlphaComponent(0.8)])
                }
            }
        }
    }
}
