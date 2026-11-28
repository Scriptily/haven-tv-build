import Foundation

/// What Haven and its Top Shelf extension share: a small JSON snapshot (+ images) in the App Group container. The
/// signer on the PC (Plume, via atvloadly) gives the group its own name (the team id appended), so the real name is
/// read from the provisioning profile inside this bundle - the app's and the extension's carry the same group.
enum SharedStore {
    static let baseGroup = "group.local.haven.tv"

    /// the entitlements in this bundle's provisioning profile (what the signer was granted)
    static let profileEntitlements: [String: Any] = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let d = try? Data(contentsOf: url), let s = String(data: d, encoding: .isoLatin1),
              let a = s.range(of: "<?xml"), let b = s.range(of: "</plist>", range: a.lowerBound..<s.endIndex),
              let pd = String(s[a.lowerBound..<b.upperBound]).data(using: .isoLatin1),
              let plist = try? PropertyListSerialization.propertyList(from: pd, format: nil) as? [String: Any] else { return [:] }
        return plist["Entitlements"] as? [String: Any] ?? [:]
    }()

    static let groupID: String? = {
        guard let groups = profileEntitlements["com.apple.security.application-groups"] as? [String] else { return nil }
        return groups.first(where: { $0.hasPrefix(baseGroup) }) ?? groups.first
    }()

    /// one line for the log: the groups granted, the keychain groups, and whether the container can be written
    static var diagnosis: String {
        let ent = profileEntitlements
        let groups = (ent["com.apple.security.application-groups"] as? [String])?.joined(separator: ", ") ?? "none"
        let kc = (ent["keychain-access-groups"] as? [String])?.joined(separator: ", ") ?? "none"
        let writable = container.map { "using \($0.lastPathComponent)" } ?? "none writable"
        return "app groups: \(groups) | keychain: \(kc) | container: \(writable) | keys: \(ent.keys.sorted().joined(separator: ","))"
    }

    /// every group the signer granted (it adds the team id - once or twice - to the name)
    static var grantedGroups: [String] { profileEntitlements["com.apple.security.application-groups"] as? [String] ?? [] }

    /// the shared folder that really works: the app takes the first one it can write to; the extension (read only) the
    /// one that holds the snapshot. Which granted name the signature itself carries isn't visible - so it's tested.
    static let container: URL? = {
        // tvOS: only Library/Caches inside a group container can be written (its top folder can't) - on 2026-11-03 the
        // container's top refused every write although the group was granted to both the app and the extension
        let dirs = grantedGroups.compactMap { g -> URL? in
            guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: g) else { return nil }
            let caches = root.appendingPathComponent("Library/Caches/Haven", isDirectory: true)
            try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
            return caches
        }
        if let withShelf = dirs.first(where: { FileManager.default.isReadableFile(atPath: $0.appendingPathComponent("topshelf.json").path) }),
           Bundle.main.bundlePath.hasSuffix(".appex") {
            return withShelf
        }
        for d in dirs {
            let probe = d.appendingPathComponent(".probe")
            if (try? Data("x".utf8).write(to: probe)) != nil { try? FileManager.default.removeItem(at: probe); return d }
        }
        return dirs.first(where: { FileManager.default.isReadableFile(atPath: $0.appendingPathComponent("topshelf.json").path) })
    }()

    static var topShelfFile: URL? { container?.appendingPathComponent("topshelf.json") }

    /// The images the extension handed to tvOS in its last few loads. tvOS keeps showing the shelf it was given (it asks
    /// again only when it decides to), so deleting one of these leaves a hole - deleting all of them, an empty shelf
    /// (seen 2026-11-03 and 2026-11-06: Haven had moved on to newer tile images and pruned the ones tvOS still showed).
    static var servedFile: URL? { container?.appendingPathComponent("served.json") }
    static func recordServed(_ images: [String]) {
        guard let f = servedFile else { return }
        var loads = ((try? Data(contentsOf: f)).flatMap { try? JSONDecoder().decode([[String]].self, from: $0) }) ?? []
        loads.append(images)
        if let d = try? JSONEncoder().encode(Array(loads.suffix(8))) { try? d.write(to: f, options: .atomic) }
    }
    static var servedImages: Set<String> {
        guard let f = servedFile, let d = try? Data(contentsOf: f), let loads = try? JSONDecoder().decode([[String]].self, from: d) else { return [] }
        return Set(loads.joined())
    }

    /// the extension's own log (last ~40 lines), in every candidate folder it can write to
    static func extLog(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let dirs = grantedGroups.compactMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)?
            .appendingPathComponent("Library/Caches/Haven", isDirectory: true) }
        for d in dirs {
            let f = d.appendingPathComponent("ext.log")
            var lines = ((try? String(contentsOf: f, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            lines.append("\(stamp) \(line)")
            try? lines.suffix(40).joined(separator: "\n").write(to: f, atomically: true, encoding: .utf8)
        }
    }

    /// the Top Shelf's content: sections of items, each with an image file in the container and a haven:// link
    struct Shelf: Codable, Equatable {
        struct Item: Codable, Equatable { let id: String; let title: String; let image: String; let url: String }
        struct Section: Codable, Equatable { let title: String; let square: Bool; let items: [Item] }
        var sections: [Section]
        /// when Haven wrote it (seconds since 1970) - an old snapshot means Haven isn't running and can't know what plays
        var written: Double? = nil
    }
}
