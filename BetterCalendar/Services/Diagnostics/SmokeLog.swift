//
//  SmokeLog.swift
//  BetterCalendar
//
//  冒烟测试跟踪器（仿 BetterTranscribe 冒烟指南 2026-08-16）：让「你操作 → 日志自证 → Claude 读日志、你不用汇报」成立。
//  两件事：
//  ① mark()：往 DevLog 打一条独一无二的「一轮开始」标记，Claude 从最后一根标记之后读这一轮。
//  ② hit(项, 详情)：在被测功能的代码路径上埋点——功能真跑到了就留一行 `冒烟｜<项>｜<详情>`。
//  日志经 LogSyncService 落 ~/Downloads/BetterCalendar-logs/<设备>-<日>.log（iOS 经 CloudKit 汇到 Mac），
//  Claude `grep 冒烟` 即读。全部走 DevLog（source="冒烟"），DevLogView 有独立「冒烟」通道。
//  纪律：埋点只描述客观事实（哪个路径跑到了、关键数值），不写结论；产品上架前此源零成本留存（DevLog 本就开发件）。
//

import Foundation

enum SmokeLog {
    static let source = "冒烟"

    /// 一轮测试开始标记（日志页「打冒烟标记」按钮调）。ID 用时:分:秒，人和 grep 都好认。
    static func mark(_ note: String = "") {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        let id = f.string(from: .now)
        DevLog.shared.info(source, "▶ 开始一轮冒烟 ROUND \(id)" + (note.isEmpty ? "" : " · \(note)"))
    }

    /// 功能命中埋点：`冒烟｜<项>｜<详情>`。项=清单里的短名，详情=关键事实/数值。
    static func hit(_ item: String, _ detail: String = "") {
        DevLog.shared.info(source, "｜\(item)｜" + (detail.isEmpty ? "命中" : detail))
    }
}
