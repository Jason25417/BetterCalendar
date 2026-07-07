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

    /// 连通性测试（设置页「测试」按钮）：验证 key + 模型可用，**顺带探测结构化输出支持**
    /// （0.20，Jason 提：格式保证=约束解码，模型支不支持 schema 直接决定抽风率——测试时就该知道）。
    /// 成功返回展示文案（模型名 + 结构化输出支持情况）。
    static func test(key: String, model: String, provider: LLMProvider) async -> Result<String, AnthropicError> {
        let probe = AnthropicClient(provider: { provider }, apiKey: { key }, model: { model }, useCloud: { true })
        do {
            // 给足 token：有些"思考"模型光推理就吃掉几十上百 token，64 太小会假性「截断」失败
            _ = try await probe.complete(system: "只回复 ok", user: "ping", maxTokens: 512)
        } catch let e as AnthropicError {
            return .failure(e)
        } catch {
            return .failure(AnthropicError(message: error.localizedDescription))
        }
        // 第二发：带最小 schema 探测约束解码（json_schema/output_config）。失败≠key 无效，只是格式保证降档。
        let pingSchema: [String: Any] = ["type": "object",
                                         "properties": ["ok": ["type": "boolean"]],
                                         "required": ["ok"],
                                         "additionalProperties": false]
        do {
            if provider == .siliconflow {
                // 直调内部方法关掉自动降级——否则降级成功会误报"支持"
                _ = try await probe.completeOpenAI(key: key, system: "返回 {\"ok\":true}", user: "ping",
                                                   maxTokens: 512, jsonMode: true,
                                                   jsonSchema: pingSchema, allowSchemaDowngrade: false)
            } else {
                _ = try await probe.complete(system: "返回 {\"ok\":true}", user: "ping",
                                             maxTokens: 512, jsonMode: true, jsonSchema: pingSchema)
            }
            return .success("\(model) 可用 · 支持结构化输出")
        } catch {
            return .success("\(model) 可用 · ⚠️ 不支持结构化输出（将降级弱 JSON 模式，格式抽风率更高）")
        }
    }

    /// 一次问答。返回模型的纯文本。按 provider 走不同端点/格式，上层无感。
    /// jsonMode=true：**强制模型直接输出 JSON**，杜绝英文思考前言/前后缀——否则复杂任务上模型会先"想一大段"把 token 塞满/破坏 JSON。
    /// - Anthropic：靠**结构化输出** `output_config.format`（传 `jsonSchema` 即启用）。**不再用 assistant prefill**
    ///   ——prefill 在现代模型（Sonnet 4.6 / Opus 4.6+ / Sonnet 5 / Fable 5）上会 HTTP 400，且已被官方废弃。
    /// - 硅基流动：优先 `response_format: json_schema`（API 参考已支持，schema 级约束解码，2026-07-08 核实）；
    ///   模型不支持时自动降级 `json_object`（弱保证，只保证合法 JSON）。
    /// - 不传 `jsonSchema` 则退化为普通请求（靠 prompt + 上层 extractObject 兜底）。
    func complete(system: String, user: String, maxTokens: Int = 2048,
                  jsonMode: Bool = false, jsonSchema: [String: Any]? = nil) async throws -> String {
        guard useCloud() else { throw AnthropicError(message: "云端已关闭") }
        guard let key = apiKey(), !key.isEmpty else { throw AnthropicError(message: "未配置 API key") }
        return provider() == .siliconflow
            ? try await completeOpenAI(key: key, system: system, user: user, maxTokens: maxTokens, jsonMode: jsonMode, jsonSchema: jsonSchema)
            : try await completeAnthropic(key: key, system: system, user: user, maxTokens: maxTokens, jsonMode: jsonMode, jsonSchema: jsonSchema)
    }

    // MARK: Anthropic 原生

    private func completeAnthropic(key: String, system: String, user: String, maxTokens: Int, jsonMode: Bool, jsonSchema: [String: Any]?) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = maxTokens >= 4000 ? 150 : 60   // 长输出非流式会久，给足；日后上流式再收紧
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        var body: [String: Any] = [
            "model": model(), "max_tokens": maxTokens, "system": system,
            "messages": [["role": "user", "content": user]],
            // 关掉 extended thinking：排程/抽取是结构化任务，不需要"想一大段"。
            // 新模型（Sonnet 5 等）**不传 thinking = 默认开自适应思考** → ①每次都先思考=慢(连测 key 都慢)
            // ②思考 token 算进 max_tokens，把额度吃掉导致 JSON 截断("回复超长")。显式 disabled 恢复速度 + 腾 token 给 JSON。
            // Opus 4.8 / Sonnet 5 / Haiku 4.5 都接受 disabled；Fable 5 会 400 但不在可选列表。
            "thinking": ["type": "disabled"],
        ]
        // 结构化输出：把回复约束成符合 schema 的 JSON（首个 text block 即合法 JSON），物理上写不出前言。
        // 现代 Anthropic 模型都支持；不支持的模型会失败 → 上层 catch 回退本地。
        if jsonMode, let schema = jsonSchema {
            body["output_config"] = ["format": ["type": "json_schema", "schema": schema]]
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let obj = try await send(req, provider: "Anthropic")
        let stop = obj["stop_reason"] as? String
        let text = (obj["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined() ?? ""
        if CloudSettings.logRawResponses {
            DevLog.shared.info("云端原文", "Anthropic \(model()) stop=\(stop ?? "?") · 返回(前2000)：\(text.prefix(2000))")
        }
        if stop == "max_tokens" {
            // 截断样本记 WARNING（跨端同步，INFO 不跨端）——看头尾各 500 字就能判断是"真长"还是模型循环复读
            DevLog.shared.warn("云端原文", "截断@\(maxTokens)·头500：\(text.prefix(500)) ⋯⋯尾500：\(text.suffix(500))")
            throw AnthropicError(message: "回复超长被截断（max_tokens=\(maxTokens)）")
        }
        guard !text.isEmpty else { throw AnthropicError(message: "空回复") }
        return text
    }

    // MARK: Anthropic 流式（SSE，0.20.1）

    /// 流式版一次问答（仅 Anthropic；硅基流动自动退回非流式）：每收到一段文本 delta 就把
    /// **累计全文**回调给 onPartial（供边生成边冒块），最终返回完整文本。
    /// 附带收益：SSE 持续有包，60s 空闲超时即可（非流式长输出要给 150s 干等）。
    func completeStreaming(system: String, user: String, maxTokens: Int = 2048,
                           jsonSchema: [String: Any]? = nil,
                           onPartial: (String) -> Void) async throws -> String {
        guard useCloud() else { throw AnthropicError(message: "云端已关闭") }
        guard let key = apiKey(), !key.isEmpty else { throw AnthropicError(message: "未配置 API key") }
        guard provider() == .anthropic else {
            return try await completeOpenAI(key: key, system: system, user: user,
                                            maxTokens: maxTokens, jsonMode: true, jsonSchema: jsonSchema)
        }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 60   // 空闲超时：流式包不断，60s 收不到任何字节才算挂
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        var body: [String: Any] = [
            "model": model(), "max_tokens": maxTokens, "system": system, "stream": true,
            "messages": [["role": "user", "content": user]],
            "thinking": ["type": "disabled"],   // 同非流式：结构化任务不要思考（慢+吃额度）
        ]
        if let schema = jsonSchema {
            body["output_config"] = ["format": ["type": "json_schema", "schema": schema]]
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        guard let http = resp as? HTTPURLResponse else { throw AnthropicError(message: "无 HTTP 响应") }
        guard http.statusCode == 200 else {
            var detail = ""
            for try await line in bytes.lines { detail += line; if detail.count > 300 { break } }
            throw AnthropicError(message: "Anthropic HTTP \(http.statusCode)：\(detail.prefix(300))")
        }
        var text = ""
        var stop: String?
        for try await line in bytes.lines {
            guard line.hasPrefix("data: "),
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            switch type {
            case "content_block_delta":
                if let t = (obj["delta"] as? [String: Any])?["text"] as? String {
                    text += t
                    onPartial(text)
                }
            case "message_delta":
                stop = (obj["delta"] as? [String: Any])?["stop_reason"] as? String
            default:
                break
            }
        }
        if CloudSettings.logRawResponses {
            DevLog.shared.info("云端原文", "Anthropic(流式) \(model()) stop=\(stop ?? "?") · 返回(前2000)：\(text.prefix(2000))")
        }
        if stop == "max_tokens" {
            DevLog.shared.warn("云端原文", "截断@\(maxTokens)·头500：\(text.prefix(500)) ⋯⋯尾500：\(text.suffix(500))")
            throw AnthropicError(message: "回复超长被截断（max_tokens=\(maxTokens)）")
        }
        guard !text.isEmpty else { throw AnthropicError(message: "空回复") }
        return text
    }

    // MARK: 硅基流动（OpenAI 兼容 chat/completions）

    private func completeOpenAI(key: String, system: String, user: String, maxTokens: Int,
                                jsonMode: Bool, jsonSchema: [String: Any]? = nil,
                                allowSchemaDowngrade: Bool = true) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.siliconflow.cn/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.timeoutInterval = maxTokens >= 4000 ? 150 : 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        var body: [String: Any] = [
            "model": model(), "max_tokens": maxTokens,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ]
        // 强制 JSON：有 schema 走 json_schema（约束解码，格式=解码器性质，与 Anthropic 同级保证）；
        // 无 schema 或已降级 → json_object（弱保证）。
        if let schema = jsonSchema {
            body["response_format"] = ["type": "json_schema",
                                       "json_schema": ["name": "output", "schema": schema]]
        } else if jsonMode {
            body["response_format"] = ["type": "json_object"]
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let obj: [String: Any]
        do {
            obj = try await send(req, provider: "硅基流动")
        } catch let e as AnthropicError
            where jsonSchema != nil && allowSchemaDowngrade && e.message.contains("HTTP 4") {
            // 只在 4xx（所选模型不吃 json_schema）时降级 json_object 重试一次（可见不静默）；超时/5xx 照常抛
            DevLog.shared.warn("云端", "硅基 \(model()) 不支持 json_schema，降级 json_object 重试：\(e.message.prefix(120))")
            return try await completeOpenAI(key: key, system: system, user: user, maxTokens: maxTokens,
                                            jsonMode: true, jsonSchema: nil, allowSchemaDowngrade: false)
        }
        guard let choices = obj["choices"] as? [[String: Any]], let first = choices.first else {
            throw AnthropicError(message: "响应格式异常")
        }
        let fr = first["finish_reason"] as? String
        // 推理模型可能把思考放 reasoning_content、答案放 content；只取 content（JSON 在其中，上层 extractObject 再挖）
        let text = ((first["message"] as? [String: Any])?["content"] as? String) ?? ""
        if CloudSettings.logRawResponses {
            DevLog.shared.info("云端原文", "硅基 \(model()) finish=\(fr ?? "?") · 返回(前2000)：\(text.prefix(2000))")
        }
        if fr == "length" {
            throw AnthropicError(message: "回复超长被截断（max_tokens=\(maxTokens)）")
        }
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
