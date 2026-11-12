import BiblioCore
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Servers answering 429 or 5xx, as libbiblio saw them (since launch), kept across launches so
/// a report can show how often it happens in the field. Nothing is sent anywhere: someone has to
/// copy the report (About's Copy Diagnostic Log button; on Mac, Help ▸ Copy Diagnostic Log).
/// Entries carry the masked path and timing, never an account.
nonisolated enum ThrottleLog {
    private static let entriesKey = "throttleLog.entries.v1"
    private static let totalKey = "throttleLog.total.v1"
    private static let maxEntries = 50
    private static let lock = NSLock()
    /// The core's running total when this launch last merged, so only new incidents count.
    nonisolated(unsafe) private static var seenTotal = 0

    /// The core's incidents this launch.
    private static func current() -> (total: Int, recent: [[String: Any]]) {
        guard let text = Core.take(biblio_incidents()),
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return (0, []) }
        return (object["total"] as? Int ?? 0, object["recent"] as? [[String: Any]] ?? [])
    }

    /// Adds this launch's new incidents to the saved log; call when the app goes to the background.
    static func sync() {
        lock.lock()
        defer { lock.unlock() }
        let (total, recent) = current()
        guard total > seenTotal else { return }
        let defaults = UserDefaults.standard
        defaults.set(defaults.integer(forKey: totalKey) + total - seenTotal, forKey: totalKey)
        seenTotal = total
        var entries = defaults.array(forKey: entriesKey) as? [[String: Any]] ?? []
        func key(_ e: [String: Any]) -> String { "\(e["at"] ?? 0)|\(e["status"] ?? 0)|\(e["path"] ?? "")" }
        var known = Set(entries.map(key))
        for e in recent where known.insert(key(e)).inserted { entries.append(e) }
        defaults.set(Array(entries.suffix(maxEntries)), forKey: entriesKey)
    }

    /// A JSON report: the app version, how many times in all, and the latest entries.
    static func report() -> String {
        sync()
        let defaults = UserDefaults.standard
        let report: [String: Any] = [
            "app": "Biblio \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")",
            "total": defaults.integer(forKey: totalKey),
            "recent": defaults.array(forKey: entriesKey) as? [[String: Any]] ?? [],
        ]
        let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    static func copyReport() {
        let text = report()
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}
