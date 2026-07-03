//
//  JournalPhoto.swift
//  BetterCalendar
//
//  日记照片本体（2026-07-04，代修「照片跨端同步」）：图片 Data 存 SwiftData，
//  @Attribute(.externalStorage) → 落盘为外部文件、CloudKit 同步走 CKAsset——两端都能看到照片。
//  JournalEntry.photoRefs 仍存文件名引用（ref），本模型按 ref 对上。
//  CloudKit 约束：默认值 ✓、无 unique ✓（同 ref 理论上可能两端重复插入，读取端取第一条即可——
//  ref 是 UUID 文件名，实际不会撞）。
//

import Foundation
import SwiftData

@Model
final class JournalPhoto {
    var ref: String = ""
    @Attribute(.externalStorage) var data: Data = Data()
    var createdAt: Date = Date.now

    init(ref: String, data: Data, createdAt: Date = .now) {
        self.ref = ref
        self.data = data
        self.createdAt = createdAt
    }
}
