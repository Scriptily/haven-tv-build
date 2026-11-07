import ImageIO
import TVServices

/// Haven's Top Shelf (the banner above the dock while Haven sits in the top row): what's playing, your quick controls,
/// the ambient screen and the dashboard. tvOS runs this briefly to draw it; the content is the snapshot Haven keeps
/// in the shared container (SharedStore) - this never talks to Home Assistant itself.
final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent(completionHandler: @escaping (TVTopShelfContent?) -> Void) {
        let groups = SharedStore.grantedGroups.joined(separator: ",")
        guard let dir = SharedStore.container else {
            SharedStore.extLog("load: no container (groups \(groups))"); completionHandler(nil); return
        }
        guard let f = SharedStore.topShelfFile, let d = try? Data(contentsOf: f) else {
            SharedStore.extLog("load: no snapshot in \(dir.path.suffix(60))"); completionHandler(nil); return
        }
        guard var shelf = try? JSONDecoder().decode(SharedStore.Shelf.self, from: d) else {
            SharedStore.extLog("load: snapshot unreadable (\(d.count) bytes)"); completionHandler(nil); return
        }
        // Haven hasn't refreshed it for 15 min (not running): what was playing then may long have stopped - leave it out
        if let w = shelf.written, Date().timeIntervalSince1970 - w > 15 * 60 {
            shelf.sections.removeAll { s in s.items.contains { $0.id == "np" } }
        }
        let missing = shelf.sections.flatMap { $0.items }.filter { !FileManager.default.fileExists(atPath: dir.appendingPathComponent($0.image).path) }
        var fmt = ""
        if let first = shelf.sections.flatMap({ $0.items }).last,
           let src = CGImageSourceCreateWithURL(dir.appendingPathComponent(first.image) as CFURL, nil),
           let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] {
            fmt = " | \(first.image): \(p["PixelWidth"] ?? "?")x\(p["PixelHeight"] ?? "?") \(p["Depth"] ?? "?")-bit \(p["ColorModel"] ?? "") \(p["ProfileName"] ?? "")"
        }
        SharedStore.extLog("load: \(shelf.sections.map { "\($0.title) \($0.items.count)" }.joined(separator: ", "))\(missing.isEmpty ? "" : " - \(missing.count) images missing")\(fmt)")
        let sections: [TVTopShelfItemCollection<TVTopShelfSectionedItem>] = shelf.sections.compactMap { s in
            let items: [TVTopShelfSectionedItem] = s.items.map { i in
                let it = TVTopShelfSectionedItem(identifier: i.id)
                it.title = i.title
                it.imageShape = s.square ? .square : .hdtv
                it.setImageURL(dir.appendingPathComponent(i.image), for: [.screenScale1x, .screenScale2x])
                if let u = URL(string: i.url) {
                    it.displayAction = TVTopShelfAction(url: u)
                    it.playAction = TVTopShelfAction(url: u)
                }
                return it
            }
            guard !items.isEmpty else { return nil }
            let c = TVTopShelfItemCollection(items: items)
            c.title = s.title
            return c
        }
        SharedStore.recordServed(shelf.sections.flatMap { $0.items.map(\.image) })   // Haven must keep these files
        completionHandler(sections.isEmpty ? nil : TVTopShelfSectionedContent(sections: sections))
    }
}
