//
//  AnthropicClient.swift
//  BetterCalendar
//
//  极简 Anthropic Messages API 客户端（Swift 无官方 SDK，用 URLSession 直连）。
//  缝是 async throws；上层（ClaudeScheduleParser / LLMPlanningEngine）失败即回退本地。
//

import Foundation

struct AnthropicError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct AnthropicClient {
    var apiKey: () -> String? = { KeychainStore.loadAPIKey() }
    var model: () -> String = { CloudSettings.model }
    var useCloud: () -> Bool = { CloudSettings.useCloud }

    /// 连通性测试（设置页「测试」按钮）：最小请求验证 key + 模型可用。成功返回模型名。
    static func test(key: String, model: String) async -> Result<String, AnthropicError> {
        let probe = AnthropicClient(apiKey: { key }, model: { model }, useCloud: { true })
        do {
            _ = try await probe.complete(system: "只回复 ok", user: "ping", maxTokens: 64)
            return .success(model)
        } catch let e as AnthropicError {
            return .failure(e)
        } catch {
            return .failure(AnthropicError(message: error.localizedDescription))
        }
    }

    /// 一次问答。返回模型的纯文本。
    func complete(system: String, user: String, maxTokens: Int = 2048) async throws -> String {
        guard useCloud() else { throw AnthropicError(message: "云端已关闭") }
        guard let key = apiKey(), !key.isEmpty else { throw AnthropicError(message: "未配置 API key") }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        // 超时按输出量放宽：长输入（解析 16+ 块、maxTokens 6000）非流式响应会超过 30s → 之前动辄超时回退。
        // 长请求(≥4000)给 120s、短请求 60s。（日后上流式可再收紧。）
        req.timeoutInterval = maxTokens >= 4000 ? 120 : 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": model(),
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw AnthropicError(message: "无 HTTP 响应") }
        guard http.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw AnthropicError(message: "HTTP \(http.statusCode)：\(detail.prefix(300))")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = obj["content"] as? [[String: Any]] else {
            throw AnthropicError(message: "响应格式异常")
        }
        // 截断检测：长日程输出超过 max_tokens 会拦腰截断 → JSON 必坏，明确报因（别让上层看天书）
        if let stop = obj["stop_reason"] as? String, stop == "max_tokens" {
            throw AnthropicError(message: "回复超长被截断（max_tokens=\(maxTokens)）")
        }
        let text = content.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw AnthropicError(message: "空回复") }
        return text
    }
}
