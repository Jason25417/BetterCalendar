//
//  DeepSeekClient.swift
//  BetterCalendar
//
//  W20 内置智能体的模型调用：DeepSeek，OpenAI 兼容的 Chat Completions + 工具调用（function calling）。
//  2026-10-19 核实官方文档（api-docs.deepseek.com）：
//    · 端点 POST https://api.deepseek.com/chat/completions，Bearer key。
//    · 模型：`deepseek-flash` = DeepSeek-V4.1-Flash（Jason 说的「V4.1 flash」）；`deepseek-v4-pro` = V4-Pro。
//      旧名 deepseek-v4-flash 仍被接受、同样由 V4.1-Flash 服务。
//    · 思考模式默认开；本客户端显式关（`thinking: {type: disabled}`）：快、省，且多轮工具调用不用回传 reasoning_content。
//    · 工具 = `tools: [{type:"function", function:{name, description, parameters}}]`，`tool_choice: "auto"`；
//      结果以 `{role:"tool", tool_call_id, content}` 回给模型。`strict: true` 是 Beta（要走 /beta 端点且所有属性必填），
//      这里不用：参数 schema 照样写严格（additionalProperties:false），真正的校验在 App 端（与桥接同一套解析）。
//    · 不用 prefill（assistant prefix 是 Beta，且原则上不靠预填强制格式）。
//    · usage：prompt_cache_hit_tokens / prompt_cache_miss_tokens / completion_tokens。
//  HTTP 层可注入：单测只用假实现，绝不真调 API。
//

import Foundation

/// 对话里的一条消息（OpenAI 兼容格式）。
nonisolated struct DeepSeekMessage: Codable, Equatable, Sendable {
    var role: String
    var content: String?
    var toolCalls: [DeepSeekToolCall]? = nil
    var toolCallId: String? = nil

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case toolCallId = "tool_call_id"
    }

    static func system(_ text: String) -> DeepSeekMessage { .init(role: "system", content: text) }
    static func user(_ text: String) -> DeepSeekMessage { .init(role: "user", content: text) }
    static func tool(_ id: String, _ text: String) -> DeepSeekMessage { .init(role: "tool", content: text, toolCallId: id) }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(role, forKey: .role)
        // assistant 带工具调用时 content 可为 null；其余角色必须是字符串。
        if let content { try c.encode(content, forKey: .content) } else { try c.encodeNil(forKey: .content) }
        try c.encodeIfPresent(toolCalls, forKey: .toolCalls)
        try c.encodeIfPresent(toolCallId, forKey: .toolCallId)
    }
}

nonisolated struct DeepSeekToolCall: Codable, Equatable, Sendable {
    nonisolated struct Function: Codable, Equatable, Sendable {
        var name: String
        var arguments: String
    }
    var id: String
    var type: String = "function"
    var function: Function
}

nonisolated struct DeepSeekUsage: Equatable, Sendable {
    var cacheHitTokens = 0
    var cacheMissTokens = 0
    var completionTokens = 0
    var promptTokens: Int { cacheHitTokens + cacheMissTokens }
}

nonisolated struct DeepSeekCompletion: Equatable, Sendable {
    var message: DeepSeekMessage
    var finishReason: String?
    var usage: DeepSeekUsage
    var model: String
}

/// 失败一律带「哪里坏了 + 你能做什么」（产品原则 10：做不到就直说）。
nonisolated struct DeepSeekError: Error, LocalizedError, Equatable {
    enum Kind: String, Sendable { case noKey, unauthorized, insufficientBalance, rateLimited, server, badRequest, network, decode, timeout }
    var kind: Kind
    var message: String
    var hint: String
    var errorDescription: String? { message }
}

nonisolated struct DeepSeekClient: Sendable {
    static let endpoint = URL(string: "https://api.deepseek.com/chat/completions")!
    /// 钥匙串账户（随 iCloud 钥匙串同步，端到端加密；服务名经 AppChannel 区分日用 / Dev）。
    static let keychainAccount = "deepseek-api-key"

    var apiKey: @Sendable () -> String?
    var transport: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }
    /// 单次 HTTP 的超时（整轮另有总超时，见 BuiltinAgentRuntime）。
    var requestTimeout: TimeInterval = 60

    /// 请求体（纯函数，单测核对形状）：不带 prefix / reasoning_content，思考模式关，tool_choice=auto。
    /// tools = 工具定义数组的 JSON（`[{type:"function", function:{…}}]`），空数组 = 不带工具。
    static func requestBody(model: String, messages: [DeepSeekMessage], tools: Data, maxTokens: Int) throws -> Data {
        let encodedMessages = try JSONSerialization.jsonObject(with: JSONEncoder().encode(messages))
        let tools = (try JSONSerialization.jsonObject(with: tools) as? [Any]) ?? []
        var body: [String: Any] = ["model": model, "messages": encodedMessages, "max_tokens": maxTokens, "stream": false,
                                   "thinking": ["type": "disabled"]]
        if !tools.isEmpty { body["tools"] = tools; body["tool_choice"] = "auto" }
        return try SafeJSON.data(withJSONObject: body, options: [.sortedKeys])
    }

    func complete(model: String, messages: [DeepSeekMessage], tools: Data, maxTokens: Int = 2048) async throws -> DeepSeekCompletion {
        try Self.parse(try await post(Self.endpoint, body: try Self.requestBody(model: model, messages: messages, tools: tools, maxTokens: maxTokens)))
    }

    /// 带 key 的 POST（对话 / 搜索 / 读网页共用）：没 key、超时、连不上、非 2xx 都抛 DeepSeekError（带给人看的原因和办法）。
    private func post(_ url: URL, body: Data) async throws -> Data {
        guard let key = apiKey()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw DeepSeekError(kind: .noKey, message: "还没有填 DeepSeek API key", hint: "到 设置 → 智能体 粘贴 DeepSeek API key，或把当前智能体切回 Claude Code")
        }
        var req = URLRequest(url: url, timeoutInterval: requestTimeout)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let data: Data, response: URLResponse
        do { (data, response) = try await transport(req) } catch is CancellationError {
            throw CancellationError()
        } catch let e as URLError where e.code == .timedOut {
            throw DeepSeekError(kind: .timeout, message: "DeepSeek 超过 \(Int(requestTimeout)) 秒没有回应", hint: "网络慢或服务忙；稍后再说一次")
        } catch {
            throw DeepSeekError(kind: .network, message: "连不上 DeepSeek：\(error.localizedDescription)", hint: "检查网络后再说一次")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Self.httpError(status: status, data: data) }
        return data
    }

    // MARK: W40 搜索 / 读网页（DeepSeek 官方 Search / Fetch，2026-10-17 上线；每 1000 次成功调用约 $0.75）

    static let searchEndpoint = URL(string: "https://api.deepseek.com/v1/tools/search")!
    static let fetchEndpoint = URL(string: "https://api.deepseek.com/v1/tools/fetch")!

    /// 搜索请求体（纯函数）：不要正文（need_content=false，摘要够用、省 token）；不传 localization（IP 定位）——
    /// 要按地点搜就把地点写进 query（他在提问里说了 / 同意了才写）。
    static func searchBody(query: String, count: Int) throws -> Data {
        try SafeJSON.data(withJSONObject: ["query": query, "count": count, "need_content": false], options: [.sortedKeys])
    }

    static func parseSearch(_ data: Data) throws -> [WebSearchResult] {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let rows = o["results"] as? [[String: Any]] else {
            throw DeepSeekError(kind: .decode, message: "DeepSeek 搜索返回的格式看不懂", hint: "这是 App 的问题；请告诉开发会话")
        }
        return rows.compactMap { r in
            guard let url = r["url"] as? String else { return nil }
            func text(_ k: String) -> String { (r[k] as? String) ?? "" }
            return WebSearchResult(title: text("title"), url: url, snippet: text("snippet"), summary: text("summary"),
                                   site: r["site_name"] as? String, date: r["date"] as? String,
                                   score: (r["rerank_score"] as? NSNumber)?.doubleValue)
        }
    }

    static func parseFetch(_ data: Data) throws -> WebPage {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let content = o["content"] as? String else {
            throw DeepSeekError(kind: .decode, message: "DeepSeek 读网页返回的格式看不懂", hint: "这是 App 的问题；请告诉开发会话")
        }
        return WebPage(title: (o["title"] as? String) ?? "", content: content)
    }

    static func httpError(status: Int, data: Data) -> DeepSeekError {
        let detail = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any])?["message"] as? String
            ?? String(decoding: data.prefix(300), as: UTF8.self)
        switch status {
        case 401: return .init(kind: .unauthorized, message: "DeepSeek 拒绝了 API key（401）：\(detail)", hint: "到 设置 → 智能体 重新粘贴正确的 key")
        case 402: return .init(kind: .insufficientBalance, message: "DeepSeek 账户余额不足（402）", hint: "到 DeepSeek 开放平台充值，或先切回 Claude Code")
        case 429: return .init(kind: .rateLimited, message: "DeepSeek 限流（429）：\(detail)", hint: "过一会儿再说一次")
        case 400, 422: return .init(kind: .badRequest, message: "DeepSeek 不接受这次请求（\(status)）：\(detail)", hint: "这是 App 的问题，不是你的；请告诉开发会话（🐞 日志里有原文）")
        default: return .init(kind: .server, message: "DeepSeek 服务出错（\(status)）：\(detail)", hint: "稍后再说一次")
        }
    }

    static func parse(_ data: Data) throws -> DeepSeekCompletion {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (o["choices"] as? [[String: Any]])?.first,
              let msg = choice["message"] as? [String: Any] else {
            throw DeepSeekError(kind: .decode, message: "DeepSeek 的回应看不懂（不是预期的格式）", hint: "这是 App 的问题；请告诉开发会话（🐞 日志里有原文）")
        }
        let calls: [DeepSeekToolCall]? = (msg["tool_calls"] as? [[String: Any]]).map { list in
            list.compactMap { c in
                guard let id = c["id"] as? String, let f = c["function"] as? [String: Any], let name = f["name"] as? String else { return nil }
                return DeepSeekToolCall(id: id, function: .init(name: name, arguments: (f["arguments"] as? String) ?? "{}"))
            }
        }
        let u = o["usage"] as? [String: Any] ?? [:]
        func int(_ k: String) -> Int { (u[k] as? NSNumber)?.intValue ?? 0 }
        var usage = DeepSeekUsage(cacheHitTokens: int("prompt_cache_hit_tokens"), cacheMissTokens: int("prompt_cache_miss_tokens"),
                                  completionTokens: int("completion_tokens"))
        // 只给了 prompt_tokens（没拆命中 / 未命中）时，全按未命中算（宁可多算，预算偏保守）。
        if usage.promptTokens == 0, int("prompt_tokens") > 0 { usage.cacheMissTokens = int("prompt_tokens") }
        let message = DeepSeekMessage(role: "assistant", content: msg["content"] as? String,
                                      toolCalls: (calls?.isEmpty ?? true) ? nil : calls)
        return DeepSeekCompletion(message: message, finishReason: choice["finish_reason"] as? String, usage: usage,
                                  model: (o["model"] as? String) ?? "")
    }
}

nonisolated struct WebSearchResult: Equatable, Sendable {
    var title: String
    var url: String
    var snippet: String
    var summary: String
    var site: String?
    var date: String?
    var score: Double?
}

nonisolated struct WebPage: Equatable, Sendable {
    var title: String
    var content: String
}

/// W40：内置智能体查网页的能力缝（实现 = DeepSeekClient；测试用假的）。
nonisolated protocol BuiltinAgentWeb: Sendable {
    func search(query: String, count: Int) async throws -> [WebSearchResult]
    func fetch(url: String) async throws -> WebPage
}

extension DeepSeekClient: BuiltinAgentWeb {
    func search(query: String, count: Int) async throws -> [WebSearchResult] {
        try Self.parseSearch(try await post(Self.searchEndpoint, body: try Self.searchBody(query: query, count: count)))
    }

    func fetch(url: String) async throws -> WebPage {
        try Self.parseFetch(try await post(Self.fetchEndpoint, body: try SafeJSON.data(withJSONObject: ["url": url])))
    }
}

// MARK: - 价格（记账与每日预算用）

/// 2026-10-19 官方价目（美元 / 百万 token）。高峰（UTC 周一至周五 01:00–04:00、06:00–10:00）是低谷的两倍；
/// 中国法定节假日不算高峰——这里不识别节假日，一律按工作日算（只会多算，预算偏保守）。
nonisolated enum DeepSeekPricing {
    struct Rates: Equatable, Sendable { var cacheHit: Double; var cacheMiss: Double; var output: Double }

    static let models: [String] = ["deepseek-flash", "deepseek-v4-pro"]
    static let defaultModel = "deepseek-flash"

    /// 低谷价；不认识的模型 = nil（记不了账 → 内置智能体拒绝运行并直说，不瞎估）。
    static func offPeak(_ model: String) -> Rates? {
        switch model {
        case "deepseek-flash", "deepseek-v4-flash": Rates(cacheHit: 0.003, cacheMiss: 0.15, output: 0.6)
        case "deepseek-v4-pro": Rates(cacheHit: 0.022, cacheMiss: 0.66, output: 1.98)
        default: nil
        }
    }

    static func isPeak(_ date: Date) -> Bool {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let wd = cal.component(.weekday, from: date)   // 1 = 周日
        guard (2...6).contains(wd) else { return false }
        let h = cal.component(.hour, from: date)
        return (1..<4).contains(h) || (6..<10).contains(h)
    }

    static func cost(_ usage: DeepSeekUsage, model: String, at date: Date) -> Double? {
        guard let r = offPeak(model) else { return nil }
        let k = isPeak(date) ? 2.0 : 1.0
        return k * (Double(usage.cacheHitTokens) * r.cacheHit + Double(usage.cacheMissTokens) * r.cacheMiss
                    + Double(usage.completionTokens) * r.output) / 1_000_000
    }
}
