#if os(macOS)
import Foundation

/// Metadata only. Bounded traversal is reported as partial rather than absence of activity.
nonisolated enum StateBridgeFileScanner {
    struct Item: Sendable {
        let root: Int
        let relativePath: String
        let modifiedAt: Date
    }
    struct Coverage: Sendable {
        let path: String
        let status: String
        let inspected: Int
    }
    struct Snapshot: Sendable {
        let items: [Item]
        let roots: [Coverage]
        let omittedItems: Bool
    }
    private static let excludedDirectories: Set<String> = [
        "node_modules", "pods", "carthage", "deriveddata", "build", "dist",
        "library", "caches", "cache", "venv", "__pycache__", "vendor"
    ]
    private static let credentialExtensions: Set<String> = [
        "p8", "pem", "key", "p12", "pfx", "keychain", "keychain-db", "mobileprovision"
    ]
    private static func excludedFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return credentialExtensions.contains(url.pathExtension.lowercased()) ||
            name.contains("credential") || name.contains("password") ||
            name == "secrets.json" || name == "secrets.yaml" || name == "token.json" ||
            name == "tokens.json" || name == "id_rsa" || name == "id_ed25519"
    }
    // Each cursor belongs to one monitor actor; enumerators are never shared across tasks.
    final class Cursor {
        let root: URL
        var enumerator: FileManager.DirectoryEnumerator?
        var cycle: [String: Item] = [:]
        var committed: [String: Item] = [:]
        var failed = false
        var cycleCount = 0
        var committedCount = 0
        init(root: URL) { self.root = root }
    }
    static func scan(roots: [URL], entryLimit: Int = 2000, secondsPerRoot: TimeInterval = 0.4, itemLimit: Int = 35) -> Snapshot {
        var cursors: [String: Cursor] = [:]
        return advance(roots: roots, cursors: &cursors, entryLimit: entryLimit, secondsPerRoot: secondsPerRoot, itemLimit: itemLimit)
    }
    static func advance(roots: [URL], cursors: inout [String: Cursor], entryLimit: Int = 2000, secondsPerRoot: TimeInterval = 0.4, itemLimit: Int = 35) -> Snapshot {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        var items: [String: Item] = [:], reports: [Coverage] = [], omitted = false
        let paths = Set(roots.prefix(12).map { $0.standardizedFileURL.path })
        cursors = cursors.filter { paths.contains($0.key) }
        for (index, root) in roots.prefix(12).enumerated() {
            let started = ProcessInfo.processInfo.systemUptime
            var inspected = 0, limited = false
            let rootPath = root.standardizedFileURL.path
            let rootValues = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard rootValues?.isDirectory == true, rootValues?.isSymbolicLink != true else {
                cursors.removeValue(forKey: rootPath)
                reports.append(Coverage(path: rootPath, status: "unavailable", inspected: 0)); continue
            }
            let cursor = cursors[rootPath] ?? Cursor(root: root)
            cursors[rootPath] = cursor
            if cursor.enumerator == nil {
                cursor.cycle = [:]; cursor.failed = false; cursor.cycleCount = 0
                cursor.enumerator = fm.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { [weak cursor] _, _ in cursor?.failed = true; return true })
            }
            guard let enumerator = cursor.enumerator else {
                reports.append(Coverage(path: rootPath, status: "unavailable", inspected: 0)); continue
            }
            // Check the budget BEFORE nextObject, so the next poll resumes without skipping an entry.
            while true {
                if inspected >= entryLimit || ProcessInfo.processInfo.systemUptime - started >= secondsPerRoot { limited = true; break }
                guard let child = enumerator.nextObject() as? URL else {
                    // Only a complete readable cycle can establish that a previously seen file disappeared.
                    if cursor.failed { cursor.committed.merge(cursor.cycle) { _, new in new } }
                    else { cursor.committed = cursor.cycle; cursor.committedCount = cursor.cycleCount }
                    cursor.enumerator = nil; break
                }
                inspected += 1
                guard let values = try? child.resourceValues(forKeys: keys) else { cursor.failed = true; continue }
                if values.isSymbolicLink == true { continue }
                if values.isDirectory == true {
                    if values.isPackage == true || excludedDirectories.contains(child.lastPathComponent.lowercased()) { enumerator.skipDescendants() }
                    continue
                }
                guard values.isRegularFile == true, !excludedFile(child), let modified = values.contentModificationDate else { continue }
                let path = child.standardizedFileURL.path
                guard path.hasPrefix(rootPath + "/") else { continue }
                cursor.cycleCount += 1
                cursor.cycle[path] = Item(root: index, relativePath: String(path.dropFirst(rootPath.count + 1)), modifiedAt: modified)
            }
            omitted = omitted || max(cursor.cycleCount, cursor.committedCount) > itemLimit
            var known = cursor.committed
            known.merge(cursor.cycle) { _, new in new }
            // Store only the latest candidates between polls; no contents or unbounded filename inventory.
            cursor.committed = Dictionary(uniqueKeysWithValues: known.sorted { $0.value.modifiedAt == $1.value.modifiedAt ? $0.key < $1.key : $0.value.modifiedAt > $1.value.modifiedAt }.prefix(itemLimit).map { ($0.key, $0.value) })
            cursor.cycle = Dictionary(uniqueKeysWithValues: cursor.cycle.sorted { $0.value.modifiedAt == $1.value.modifiedAt ? $0.key < $1.key : $0.value.modifiedAt > $1.value.modifiedAt }.prefix(itemLimit).map { ($0.key, $0.value) })
            for (path, item) in known where items[path] == nil {
                items[path] = Item(root: index, relativePath: item.relativePath, modifiedAt: item.modifiedAt)
            }
            reports.append(Coverage(path: rootPath, status: limited ? "partial-budget" : cursor.failed ? "partial-unreadable" : "complete", inspected: inspected))
        }
        let sorted = items.sorted { $0.value.modifiedAt == $1.value.modifiedAt ? $0.key < $1.key : $0.value.modifiedAt > $1.value.modifiedAt }
        return Snapshot(items: sorted.prefix(itemLimit).map(\.value), roots: reports, omittedItems: omitted || items.count > itemLimit)
    }
}

actor StateBridgeFileMonitor {
    static let shared = StateBridgeFileMonitor()
    private var cursors: [String: StateBridgeFileScanner.Cursor] = [:]
    func scan(roots: [URL]) -> StateBridgeFileScanner.Snapshot {
        StateBridgeFileScanner.advance(roots: roots, cursors: &cursors)
    }
}
#endif
