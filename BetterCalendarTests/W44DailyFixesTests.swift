//
//  W44DailyFixesTests.swift
//  BetterCalendarTests
//
//  0.75（Jason 2026-10-25）：日用日志里查出的问题——共享记忆被整份改短（10-24 21:30 2690→707 字）、
//  主动提醒不在对话页、断网时同一条失败每 10 秒刷一条、智能体步数上限。
//

import Foundation
import Testing
@testable import BetterCalendar

extension W20BuiltinAgentTests {
    func longMemory(_ n: Int = 1000) -> String { "- 2026-10-24 跟进：" + String(repeating: "长", count: n) }

    @Test func memoryRewriteThatDropsMostOfItIsRefusedUnlessConfirmed() async throws {
        let e = env()
        let ledger = BuiltinAgentRunLedger()
        try e.memory.replace(longMemory(), by: "内置智能体（iPhone）")
        let cut = object(await e.tools.call("update_shared_memory", arguments: #"{"text":"- 只剩一行"}"#, eventId: nil, ledger: ledger))
        #expect(cut["ok"] as? Bool == false && (cut["error"] as? String)?.contains("confirmShrink") == true)
        #expect(e.memory.memory?.text.count ?? 0 > 1000)   // 原记忆不动
        let grow = object(await e.tools.call("update_shared_memory", arguments: #"{"text":"\#(longMemory())\n- 新的一条"}"#, eventId: nil, ledger: ledger))
        #expect(grow["ok"] as? Bool == true)
        let ok = object(await e.tools.call("update_shared_memory", arguments: #"{"text":"- 精简后","confirmShrink":true}"#, eventId: nil, ledger: ledger))
        #expect(ok["ok"] as? Bool == true && e.memory.memory?.text == "- 精简后")
        #expect(e.memory.history().count == 2 && e.memory.history().last?.text.contains("新的一条") == true)   // 旧版本本机留着
    }

    @Test func memoryChangedOnAnotherDeviceSinceTheRunReadItIsRefusedWithTheLatest() async throws {
        let e = env()
        let ledger = BuiltinAgentRunLedger()
        try e.memory.replace("- 老的", by: "内置智能体（Mac）")
        ledger.memoryBase = e.memory.memory?.updatedAt
        e.clock.now = e.clock.now.addingTimeInterval(60)
        let iPhone = AgentSharedMemoryStore(defaults: e.defaults, now: { e.clock.now })
        try iPhone.replace("- 老的\n- iPhone 新加的", by: "内置智能体（iPhone）")
        e.clock.now = e.clock.now.addingTimeInterval(60)
        let stale = object(await e.tools.call("update_shared_memory", arguments: #"{"text":"- 老的\n- Mac 想加的"}"#, eventId: nil, ledger: ledger))
        #expect(stale["ok"] as? Bool == false && (stale["error"] as? String)?.contains("iPhone 新加的") == true)
        #expect(e.memory.memory?.text.contains("iPhone 新加的") == true)
        // 拿到最新全文后再写：放行
        let retry = object(await e.tools.call("update_shared_memory", arguments: #"{"text":"- 老的\n- iPhone 新加的\n- Mac 想加的"}"#, eventId: nil, ledger: ledger))
        #expect(retry["ok"] as? Bool == true)
    }

    @Test func copiedSnapshotHeaderIsStripped() {
        let raw = "# BetterCalendar 智能体共享记忆\n\n> 最后更新：2026-10-25 01:30（内置智能体（Mac））· 上限 6000 字\n\n## 作息\n- 2 点睡"
        #expect(AgentSharedMemoryStore.strippingSnapshotHeader(raw) == "## 作息\n- 2 点睡")
        #expect(AgentSharedMemoryStore.strippingSnapshotHeader("- 普通内容") == "- 普通内容")
    }

    @Test func turnLimitIsFifty() {
        #expect(env().runtime.maxTurns == 50)
    }

    @Test func replyAfterANoticeCarriesTheNotice() async throws {
        let e = env()
        e.selection.select(.builtin)
        _ = await e.messages.receive(AgentMessageDraft(title: "写论文", body: "要不要现在开个头？", reason: "哨兵：开始时间已过"))
        e.clock.now = e.clock.now.addingTimeInterval(120)
        _ = try #require(await e.chat.send("好，马上开始"))
        await e.hub.pumpMessages()
        e.model.script = [FakeModel.done()]
        await e.runtime.processPending()
        let event = try #require(e.model.requests.first?[1].content)
        #expect(event.contains("afterNotice") && event.contains("要不要现在开个头"))
    }
}

@MainActor @Suite struct W44TimelineAndLogTests {
    @Test func noticesAreMergedIntoTheChatTimelineByTime() {
        let t = Date(timeIntervalSince1970: 1_792_000_000)
        let said = AgentChatMessage(id: UUID(), createdAt: t, author: .user, deviceId: "mac", deviceLabel: "Mac", text: "hi")
        let notice = AgentMessage(id: UUID(), createdAt: t.addingTimeInterval(60), originLabel: "BetterCalendar 智能体", parentRef: nil,
                                  title: "写论文", body: "开个头？", reason: "", delivery: .suppressed, suppressReason: "安静时段")
        let reply = AgentChatMessage(id: UUID(), createdAt: t.addingTimeInterval(120), author: .agent, deviceId: "mac", deviceLabel: "Mac", text: "好")
        let items = ChatTimelineItem.merge(chat: [reply, said], notices: [notice])
        #expect(items.map(\.id) == [said.id, notice.id, reply.id])   // 拦下的也在（写明没弹通知）
    }

    @Test func identicalTransientRepeatsCollapseAndRecoveryCountsThem() {
        let log = DevLog()
        var now = Date(timeIntervalSince1970: 1_792_000_000)
        log.now = { now }
        let offline = "读取对话失败：The operation couldn’t be completed. (CKErrorDomain error 3.)"
        for _ in 0..<6 { log.error("智能体对话", offline); now = now.addingTimeInterval(10) }
        #expect(log.entries.filter { $0.source == "智能体对话" }.count == 1)
        log.error("智能体对话", "读取对话失败：The operation couldn’t be completed. (CKErrorDomain error 4.)")   // 不同的失败照记
        #expect(log.entries.filter { $0.source == "智能体对话" }.count == 2)
        log.resolve(source: "智能体对话")
        #expect(log.entries.last?.message.contains("共失败 7 次") == true)
        // 恢复后再断：新的一段照常记第一条
        log.error("智能体对话", offline)
        #expect(log.entries.last?.message == offline)
        // 要处理的（非短暂）不合并
        for _ in 0..<2 { log.error("执行", "写入实际日历失败：x") }
        #expect(log.entries.filter { $0.source == "执行" }.count == 2)
    }
}
