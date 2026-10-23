//
//  SharedKV.swift
//  BetterCalendar
//
//  W30：跨设备共享的小块数据（多键版）。生产 = iCloud KV（NSUbiquitousKeyValueStore，与设置同步 / 写权租约同一个存储，
//  Dev 版与日用版按 bundle id 天然分开）；测试 = 内存假存储（多台设备共用一个「云」，可模拟投递延迟）。
//  用在：触达出口的每台设备一块「回执 / 已处理」板（每台只写自己的键，不会互相覆盖）、早晚通知属于哪一天、输入框草稿接力。
//  不新建 CloudKit 记录类型（零 schema 改动）。
//

import Foundation

nonisolated protocol SharedKVStoring: AnyObject {
    func data(forKey key: String) -> Data?
    /// nil = 删掉。返回 false = 已存本机但这次没能交给 iCloud（synchronize 失败）。
    @discardableResult func set(_ data: Data?, forKey key: String) -> Bool
    func keys(withPrefix prefix: String) -> [String]
    /// 另一台设备改了某些键（nil = 不知道哪些，全量重读）→ 回调（主线程）。
    func addChangeObserver(_ block: @escaping @MainActor ([String]?) -> Void)
}

nonisolated final class ICloudSharedKV: SharedKVStoring, @unchecked Sendable {
    static let shared = ICloudSharedKV()
    private let kv = NSUbiquitousKeyValueStore.default

    func data(forKey key: String) -> Data? { kv.data(forKey: key) }

    @discardableResult func set(_ data: Data?, forKey key: String) -> Bool {
        if let data { kv.set(data, forKey: key) } else { kv.removeObject(forKey: key) }
        return kv.synchronize()
    }

    func keys(withPrefix prefix: String) -> [String] {
        kv.dictionaryRepresentation.keys.filter { $0.hasPrefix(prefix) }.sorted()
    }

    func addChangeObserver(_ block: @escaping @MainActor ([String]?) -> Void) {
        NotificationCenter.default.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                                               object: kv, queue: .main) { note in
            let changed = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
            MainActor.assumeIsolated { block(changed) }
        }
    }
}
