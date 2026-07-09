//
//  FailedScheduleParser.swift
//  BetterCalendar
//
//  终端兜底（0.26，删 StubScheduleParser 后）：端侧 + 云端全失败时**不再产垃圾草稿**（旧 Stub 按标点切句设固定块，
//  任何场景都错、还给用户额外收拾负担=违无感）。改为干净抛错 → HomeViewModel.arrange 显示可操作的失败态
//  （保留输入原文 + "检查网络/填 key 再试"），符合「出错给重试、不给错误码/垃圾」。
//

import Foundation

struct FailedScheduleParser: ScheduleParsing {
    func parse(_ text: String, referenceDate: Date) async throws -> ParsedPlan {
        throw AnthropicError(message: "解析未成功（网络不通 / 未配 API key）")
    }
}
