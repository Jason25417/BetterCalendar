//
//  W40WebSearchTests.swift
//  BetterCalendarTests
//
//  W40（Jason 2026-10-22）：内置智能体能查网页（DeepSeek 官方 Search / Fetch）。请求形状、结果解析、每轮上限、
//  回复带来源（默认收起）、旧消息照常解码。全部用假的网络，不连真接口。
//

import Foundation
import Testing
@testable import BetterCalendar

extension W20BuiltinAgentTests {
    struct FakeWeb: BuiltinAgentWeb {
        func search(query: String, count: Int) async throws -> [WebSearchResult] {
            (0..<count).map { WebSearchResult(title: "结果\($0)", url: "https://example.edu/\($0)", snippet: "s", summary: String(repeating: "长", count: 900),
                                              site: "OSU", date: nil, score: 2) }
        }
        func fetch(url: String) async throws -> WebPage { WebPage(title: "大纲", content: String(repeating: "字", count: 9000)) }
    }

    func webTools(_ e: Env) -> BuiltinAgentToolbox {
        BuiltinAgentToolbox(proposals: e.center, chat: e.chat, messages: e.messages, memory: e.memory, deviceLabel: "Mac",
                            web: FakeWeb(), now: { e.clock.now }, context: { [:] })
    }

    @Test func searchAndReadAreCappedAndClipped() async throws {
        let e = env()
        let tools = webTools(e)
        let ledger = BuiltinAgentRunLedger()
        let s = object(await tools.call("web_search", arguments: #"{"query":"CSE 2331 midterm date site:osu.edu","count":3}"#, eventId: nil, ledger: ledger))
        let rows = try #require(s["results"] as? [[String: Any]])
        #expect(s["ok"] as? Bool == true && rows.count == 3 && (rows[0]["summary"] as? String)?.count == 800)
        let page = object(await tools.call("read_webpage", arguments: #"{"url":"https://example.edu/syllabus"}"#, eventId: nil, ledger: ledger))
        #expect((page["content"] as? String)?.hasSuffix("（后面省略）") == true)
        let bad = object(await tools.call("read_webpage", arguments: #"{"url":"file:///etc/passwd"}"#, eventId: nil, ledger: ledger))
        #expect(bad["ok"] as? Bool == false)
        let long = object(await tools.call("web_search", arguments: "{\"query\":\"\(String(repeating: "q", count: 129))\"}", eventId: nil, ledger: ledger))
        #expect(long["ok"] as? Bool == false)
        for _ in 0..<3 { _ = await tools.call("web_search", arguments: #"{"query":"x"}"#, eventId: nil, ledger: ledger) }
        let sixth = object(await tools.call("web_search", arguments: #"{"query":"y"}"#, eventId: nil, ledger: ledger))
        #expect((sixth["error"] as? String)?.contains("5 次") == true)
    }

    @Test func withoutAWebConnectionToolsSaySo() async {
        let e = env()
        let out = object(await e.tools.call("web_search", arguments: #"{"query":"x"}"#, eventId: nil, ledger: BuiltinAgentRunLedger()))
        #expect(out["ok"] as? Bool == false && (out["error"] as? String)?.contains("没接网页搜索") == true)
    }

    @Test func replyCarriesSourcesCollapsedOnTheMessage() async throws {
        let e = env()
        let ledger = BuiltinAgentRunLedger()
        let ok = object(await e.tools.call("reply_jason", arguments: #"{"text":"期中是 10 月 30 日","sources":[{"title":"CSE 2331 大纲","url":"https://cse.osu.edu/2331"}]}"#,
                                           eventId: nil, ledger: ledger))
        #expect(ok["ok"] as? Bool == true)
        let m = try #require(e.chat.messages.last)
        #expect(m.sources == [ChatSource(title: "CSE 2331 大纲", url: "https://cse.osu.edu/2331")] && !m.text.contains("http"))
        let bad = object(await e.tools.call("reply_jason", arguments: #"{"text":"x","sources":[{"url":"javascript:alert(1)"}]}"#, eventId: nil, ledger: ledger))
        #expect(bad["ok"] as? Bool == false)
        // 旧消息（没有 sources 字段）照常解码
        let old = AgentChatMessage(id: UUID(), createdAt: Date(), author: .agent, deviceId: "mac", deviceLabel: "Mac", text: "hi")
        let data = try JSONEncoder().encode(old)
        #expect(!(String(data: data, encoding: .utf8) ?? "").contains("sources"))
        #expect(try JSONDecoder().decode(AgentChatMessage.self, from: data).sources == nil)
    }

    @Test func searchRequestHasNoLocationAndKeyStaysInTheHeader() async throws {
        let body = try #require(try JSONSerialization.jsonObject(with: DeepSeekClient.searchBody(query: "q", count: 5)) as? [String: Any])
        #expect(body["localization"] == nil && body["need_content"] as? Bool == false && body["count"] as? Int == 5)
        final class Box: @unchecked Sendable { var request: URLRequest? }
        let box = Box()
        let reply = #"{"results":[{"title":"t","url":"https://a.b","snippet":"s","summary":"m","site_name":"A","date":null,"rerank_score":1.7}]}"#
        let client = DeepSeekClient(apiKey: { "sk-test" }, transport: { req in
            box.request = req
            return (Data(reply.utf8), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let results = try await client.search(query: "q", count: 5)
        #expect(results == [WebSearchResult(title: "t", url: "https://a.b", snippet: "s", summary: "m", site: "A", date: nil, score: 1.7)])
        #expect(box.request?.url == DeepSeekClient.searchEndpoint && box.request?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        let sent = String(decoding: box.request?.httpBody ?? Data(), as: UTF8.self)
        #expect(sent.contains("\"query\":\"q\"") && !sent.contains("sk-test"), "请求体：\(sent)")
        let noKey = DeepSeekClient(apiKey: { nil })
        await #expect(throws: DeepSeekError.self) { _ = try await noKey.fetch(url: "https://a.b") }
    }
}
