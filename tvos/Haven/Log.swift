import Foundation
import UIKit

/// The app's log: every line is kept in memory (the last 600) and sent to Home Assistant in batches, so a problem can
/// be read there without anyone at the TV. Errors also go to HA's own log. A crash (uncaught exception or signal)
/// writes the last lines to a file first; they're sent on the next launch.
final class Log {
    static let shared = Log()
    enum Level: String { case info, warning, error }

    private let queue = DispatchQueue(label: "log")
    private var lines: [String] = []
    private var unsent: [[String: Any]] = []
    private let started = Date()
    /// set once paired: sends a batch (returns false when it couldn't)
    var sender: (([[String: Any]]) async -> Bool)?
    private var flushing = false

    func add(_ text: String, level: Level = .info) {
        let t = Date()
        let line = String(format: "[+%.1fs] ", t.timeIntervalSince(started)) + (level == .info ? "" : "\(level.rawValue.uppercased()): ") + text
        queue.async {
            self.lines.append(line)
            if self.lines.count > 600 { self.lines.removeFirst(self.lines.count - 600) }
            self.unsent.append(["t": t.timeIntervalSince1970, "level": level.rawValue, "msg": text])
            if self.unsent.count > 400 { self.unsent.removeFirst(self.unsent.count - 400) }
            Self.crashTail = Array(self.lines.suffix(40))
        }
        #if DEBUG
        print(line)
        #endif
        if level != .info { flushSoon(0.5) } else { flushSoon(5) }
    }

    var text: String { queue.sync { lines.joined(separator: "\n") } }

    private var pending = false
    private func flushSoon(_ after: Double) {
        queue.async {
            guard !self.pending else { return }
            self.pending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + after) { Task { await self.flush() } }
        }
    }

    func flush() async {
        let batch: [[String: Any]] = queue.sync { pending = false; return unsent }
        guard !batch.isEmpty, let send = sender, !flushing else { return }
        flushing = true
        defer { flushing = false }
        if await send(batch) { queue.sync { unsent.removeFirst(min(batch.count, unsent.count)) } }
        else { flushSoon(30) }                    // Home Assistant away: keep the lines (last 400) and try again
    }

    // MARK: crashes

    /// the last lines, kept where a signal handler can still reach them
    nonisolated(unsafe) static var crashTail: [String] = []
    static var crashFile: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("last-crash.txt")
    }

    static func installCrashHandlers() {
        NSSetUncaughtExceptionHandler { e in
            Log.writeCrash("uncaught exception \(e.name.rawValue): \(e.reason ?? "")\n" + e.callStackSymbols.prefix(25).joined(separator: "\n"))
        }
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE] {
            signal(sig) { s in
                Log.writeCrash("signal \(s)\n" + Thread.callStackSymbols.prefix(25).joined(separator: "\n"))
                signal(s, SIG_DFL); raise(s)
            }
        }
    }

    private static func writeCrash(_ what: String) {
        let body = "\(Date())\n\(what)\n--- last lines ---\n" + crashTail.joined(separator: "\n")
        try? body.data(using: .utf8)?.write(to: crashFile)
    }

    /// the previous run's crash, if there was one (read once, then removed)
    static func takeCrash() -> String? {
        guard let d = try? Data(contentsOf: crashFile) else { return nil }
        try? FileManager.default.removeItem(at: crashFile)
        return String(data: d, encoding: .utf8)
    }
}
