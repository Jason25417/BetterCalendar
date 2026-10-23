//
//  W39AgentReportTests.swift
//  BetterCalendarTests
//
//  W39（Jason 2026-10-22，日用切到内置智能体前）：内置智能体没有 Claude Code 那样翻日志排查的能力，问题要能报到开发侧——
//  ① 它自己用 report_problem 上报（只进开发日志「智能体上报」，不通知 Jason、不进对话）；
//  ② 一轮失败或被拒收 ≥ 3 次（打转迹象）时 App 自动上报经过（调过哪些工具、结果开头）。
//

import Foundation
import Testing
@testable import BetterCalendar

extension W20BuiltinAgentTests {
    private func reports(after mark: Date) -> [DevLog.Entry] {
        DevLog.shared.entries.filter { $0.source == "智能体上报" && $0.time >= mark }
    }

    @Test func agentCanReportAProblemToTheDevLogOnly() async throws {
        let e = env()
        let ledger = BuiltinAgentRunLedger()
        let mark = Date()
        let marker = UUID().uuidString.prefix(8)
        let ok = object(await e.tools.call("report_problem", arguments: #"{"kind":"missing_capability","summary":"不能查公交时间 \#(marker)","details":"他问几点出门，我没有路线工具"}"#,
                                           eventId: nil, ledger: ledger))
        #expect(ok["ok"] as? Bool == true)
        let entry = try #require(reports(after: mark).first { $0.message.contains(marker) })
        #expect(entry.level == .info && entry.message.hasPrefix("【缺能力】") && entry.message.contains("没有路线工具"))
        #expect(e.chat.messages.isEmpty)   // 不进对话
        let bad = object(await e.tools.call("report_problem", arguments: #"{"kind":"angry","summary":"x"}"#, eventId: nil, ledger: ledger))
        #expect(bad["ok"] as? Bool == false)
        for _ in 0..<2 { _ = await e.tools.call("report_problem", arguments: #"{"kind":"other","summary":"y"}"#, eventId: nil, ledger: ledger) }
        let fourth = object(await e.tools.call("report_problem", arguments: #"{"kind":"other","summary":"z"}"#, eventId: nil, ledger: ledger))
        #expect((fourth["error"] as? String)?.contains("最多 3 条") == true || (fourth["error"] as? String)?.contains("已经上报 3 条") == true)
    }

    @Test func rejectionsAndTheCallTrailAreCounted() async throws {
        let e = env()
        let ledger = BuiltinAgentRunLedger()
        _ = await e.tools.call("read_context", arguments: "{}", eventId: nil, ledger: ledger)
        for _ in 0..<3 {
            _ = await e.tools.call("propose_change", arguments: #"{"title":"加待办","reason":"r","action":{"kind":"itemCreate","title":"交表"}}"#,
                                   eventId: nil, ledger: ledger)
        }
        #expect(ledger.rejections == 3 && ledger.trail.count == 4 && ledger.trail[0].hasPrefix("read_context → "))
        let text = try #require(BuiltinAgentRuntime.runReport(problem: nil, kinds: ["user_message"], turns: 5, ledger: ledger))
        #expect(text.hasPrefix("【打转迹象】被拒收 3 次") && text.contains("2. propose_change → "))
    }

    @Test func runReportOnlyWhenSomethingWentWrong() {
        let quiet = BuiltinAgentRunLedger()
        quiet.rejections = 2
        #expect(BuiltinAgentRuntime.runReport(problem: nil, kinds: ["user_message"], turns: 3, ledger: quiet) == nil)
        let failed = BuiltinAgentRuntime.runReport(problem: BuiltinAgentProblem.turnLimit(12).message, kinds: ["block_finished"], turns: 12, ledger: quiet)
        #expect(failed?.hasPrefix("【这一轮失败】这一轮绕了 12 步还没结束") == true)
    }

    @Test func toolListMatchesTheImplementation() throws {
        let url = try #require(Bundle(for: BuiltinAgentRunLedger.self).url(forResource: "BuiltinAgentTools", withExtension: "json"))
        let list = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        let names = Set(list.compactMap { ($0["function"] as? [String: Any])?["name"] as? String })
        #expect(names == BuiltinAgentToolbox.toolNames && names.contains("report_problem"))
    }
}
