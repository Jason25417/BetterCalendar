//
//  PhotoStore.swift
//  BetterCalendar
//
//  日记照片存储（R2 → 2026-07-04 升级跨端）：
//  - 真相源 = SwiftData `JournalPhoto`（externalStorage，CloudKit 走 CKAsset 跨端同步）；
//  - 本地文件（Application Support/journal-photos/）只作读取缓存（快 + 兼容旧版）；
//  - 首次启动把旧版本只存了本地文件的照片迁入 DB（一次性，之后两端都能看）。
//  JournalEntry 仍只存 photoRefs（文件名引用），不把二进制塞进条目。
//

import Foundation
import SwiftData

@MainActor
final class PhotoStore {
    private let dir: URL
    private let context: ModelContext?   // nil = 纯文件模式（旧行为，测试也可用）

    init(context: ModelContext? = nil, directory: URL? = nil) {
        let base = directory
            ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory()))
                .appendingPathComponent("BetterCalendar/journal-photos", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        dir = base
        self.context = context
        // Legacy migration must be explicit: reimporting every unmatched cached file on each launch
        // resurrects photos deleted on another device. Existing file-only data remains on disk.
    }

    func url(for ref: String) -> URL { dir.appendingPathComponent(ref) }

    /// 存一张图：写 DB（跨端）+ 本地缓存；返回文件名引用，失败 nil。
    func save(_ data: Data) -> String? {
        let name = UUID().uuidString + ".jpg"
        do { try data.write(to: url(for: name)) } catch { return nil }
        if let context {
            context.insert(JournalPhoto(ref: name, data: data))
            try? context.save()
        }
        return name
    }

    /// 读一张图：本地缓存优先；没有（云端同步来的新照片）→ 从 DB 取并回写缓存。
    func data(for ref: String) -> Data? {
        if context == nil { return try? Data(contentsOf: url(for: ref)) }
        guard let context,
              let p = ((try? context.fetch(FetchDescriptor<JournalPhoto>())) ?? [])
                  .first(where: { $0.ref == ref }),
              !p.data.isEmpty else { return nil }
        try? p.data.write(to: url(for: ref))   // 回写缓存，下次直读文件
        return p.data
    }

    func delete(_ ref: String) {
        try? FileManager.default.removeItem(at: url(for: ref))
        guard let context else { return }
        for p in ((try? context.fetch(FetchDescriptor<JournalPhoto>())) ?? []) where p.ref == ref {
            context.delete(p)
        }
        try? context.save()
    }

    /// 旧版本只存了本地文件的照片 → 迁入 DB（跨端可见）。幂等：DB 里已有的 ref 跳过。
    func importLegacyFiles() {
        guard let context else { return }
        let existing = Set(((try? context.fetch(FetchDescriptor<JournalPhoto>())) ?? []).map(\.ref))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var imported = 0
        for name in files where !existing.contains(name) && !name.hasPrefix(".") {
            if let data = try? Data(contentsOf: url(for: name)), !data.isEmpty {
                context.insert(JournalPhoto(ref: name, data: data))
                imported += 1
            }
        }
        if imported > 0 {
            try? context.save()
            DevLog.shared.info("日记", "旧本地照片迁入云同步库 \(imported) 张")
        }
    }
}
