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

/// 多服务商客户端（名字保留 AnthropicClient 避免大改组装点）：按 CloudSettings.provider 分流
/// Anthropic 原生 /v1/messages 或 硅基流动 OpenAI 兼容 /v1/chat/completions。上层调用签名不变。
struct AnthropicClient {
    var provider: () -> LLMProvider = { CloudSettings.provider }
    var apiKey: () -> String? = { KeychainStore.loadAPIKey(account: CloudSettings.provider.keychainAccount) }
    var model: () -> String = { CloudSettings.activeModel }
    var useCloud: () -> Bool = { CloudSettings.useCloud }

    /// 连通性测试（设置页「测试」按钮）：最小请求验证 key + 模型可用。成功返回模型名。
    static func test(key: String, model: String, provider: LLMProvider) async -> Result<String, AnthropicError> {
        let probe = AnthropicClient(provider: { provider }, apiKey: { key }, model: { model }, useCloud: { true })
        do {
            _ = try await probe.complete(system: "只回复 ok", user: "ping", maxTokens: 64)
            return .success(model)
        } catch let e as AnthropicError {
            return .failure(e)
        } catch {
            return .failure(AnthropicError(message: error.localizedDescription))
        }
    }

    /// 一次问答。返回模型的纯文本。按 provider 走不同端点/格式，上层无感。
    func complete(system: String, user: String, maxTokens: Int = 2048) async throws -> String {
        guard useCloud() else { throw AnthropicError(message: "云端已关闭") }
        guard let key = apiKey(), !key.isEmpty else { throw AnthropicError(message: "未配置 API key") }
        return provider() == .siliconflow
            ? try await completeOpenAI(key: key, system: system, user: user, maxTokens: maxTokens)
            : try await completeAnthropic(key: key, system: system, user: user, maxTokens: maxTokens)
    }

    // MARK: Anthropic 原生

    private func completeAnthropic(key: String, system: String, user: String, maxTokens: Int) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = maxTokens >= 4000 ? 120 : 60   // 长输出非流式会久，给足；日后上流式再收紧
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model(), "max_tokens": maxTokens, "system": system,
            "messages": [["role": "user", "content": user]],
        ])
        let obj = try await send(req, provider: "Anthropic")
        if let stop = obj["stop_reason"] as? String, stop == "max_tokens" {
            throw AnthropicError(message: "回复超长被截断（max_tokens=\(maxTokens)）")
        }
        let text = (obj["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined() ?? ""
        guard !text.isEmpty else { throw AnthropicError(message: "空回复") }
        return text
    }

    // MARK: 硅基流动（OpenAI 兼容 chat/completions）

    private func completeOpenAI(key: String, system: String, user: String, maxTokens: Int) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.siliconflow.cn/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.timeoutInterval = maxTokens >= 4000 ? 120 : 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model(), "max_tokens": maxTokens,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ])
        let obj = try await send(req, provider: "硅基流动")
        guard let choices = obj["choices"] as? [[String: Any]], let first = choices.first else {
            throw AnthropicError(message: "响应格式异常")
        }
        if let fr = first["finish_reason"] as? String, fr == "length" {
            throw AnthropicError(message: "回复超长被截断（max_tokens=\(maxTokens)）")
        }
        // 推理模型可能把思考放 reasoning_content、答案放 content；只取 content（JSON 在其中，上层 extractObject 再挖）
        let text = ((first["message"] as? [String: Any])?["content"] as? String) ?? ""
        guard !text.isEmpty else { throw AnthropicError(message: "空回复（推理模型可能把内容放在了 reasoning_content）") }
        return text
    }

    // MARK: 共用发送

    private func send(_ req: URLRequest, provider: String) async throws -> [String: Any] {
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw AnthropicError(message: "无 HTTP 响应") }
        guard http.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw AnthropicError(message: "\(provider) HTTP \(http.statusCode)：\(detail.prefix(300))")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AnthropicError(message: "响应格式异常")
        }
        return obj
    }
}
