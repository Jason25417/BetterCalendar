//
//  PhotoStore.swift
//  BetterCalendar
//
//  日记照片存储（R2）：图片存进 App 容器（沙箱内 Application Support/journal-photos/），
//  JournalEntry 只存文件名引用（photoRefs），不把二进制塞进 DB。
//  ⚠️ 跨端：CloudKit 同步的是 photoRefs（文件名），图片文件本身暂不跨端（需 CKAsset/iCloud Drive，留后）。
//

import Foundation

@MainActor
final class PhotoStore {
    private let dir: URL

    init() {
        let base = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                    ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("BetterCalendar/journal-photos", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        dir = base
    }

    func url(for ref: String) -> URL { dir.appendingPathComponent(ref) }

    /// 存一张图，返回文件名引用；失败返回 nil。
    func save(_ data: Data) -> String? {
        let name = UUID().uuidString + ".jpg"
        do { try data.write(to: url(for: name)); return name } catch { return nil }
    }

    func delete(_ ref: String) {
        try? FileManager.default.removeItem(at: url(for: ref))
    }
}
