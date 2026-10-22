//
//  ChatAttachments.swift
//  BetterCalendar
//
//  W36（Jason 2026-10-22）：对话里发图片 / 文件。
//  · 文件本体：本机 App Support/BetterCalendar/ChatAttachments/<id>.<ext>；同步走 BCChatMessage 记录的 `files` 资源字段（CKAsset 列表，
//    只在新建消息时上传一次），别的设备拉到消息时把资源拷进自己的目录。元数据（名字 / 种类 / 大小 / 抽出的文字）在消息 JSON 载荷里。
//  · 给智能体：端侧抽文字（图片 = Vision 文字识别；PDF = PDFKit；纯文本直接读）随 user_message 一起送去——内置智能体（DeepSeek）
//    看不了图，靠这段文字；Claude Code 通道另把原文件放进桥接目录，它能直接看图。抽不出字就如实写「没识别出文字」。
//  · 上限：图片缩到长边 2048、JPEG；其他文件 ≤ 20 MB；一条消息最多 4 个附件；抽出的文字每个 ≤ 8000 字。
//

import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

nonisolated struct ChatAttachment: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case image, file }
    var id: UUID
    var kind: Kind
    /// 给人看的文件名（图片 = 「图片.jpg」或原名）
    var name: String
    /// 本机文件扩展名（决定存储路径与类型）
    var ext: String
    var byteCount: Int
    /// 端侧抽出的文字（nil = 没抽 / 抽不出）
    var extractedText: String? = nil

    var sizeLabel: String { ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file) }
}

nonisolated enum ChatAttachmentError: LocalizedError {
    case tooLarge(String, Int)
    case unreadable(String)
    var errorDescription: String? {
        switch self {
        case let .tooLarge(name, mb): "「\(name)」超过 \(mb) MB，发不了"
        case let .unreadable(name): "读不了「\(name)」"
        }
    }
}

nonisolated enum ChatAttachmentStore {
    static let maxFileBytes = 20 * 1024 * 1024
    static let maxPerMessage = 4
    static let textLimit = 8000
    static let imageMaxSide: CGFloat = 2048

    /// 存放目录（测试宿主里是临时目录，不碰真实数据）。
    static let root: URL = {
        if TestHost.isActive { return FileManager.default.temporaryDirectory.appendingPathComponent("bc-test-chat-attachments", isDirectory: true) }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("BetterCalendar/ChatAttachments", isDirectory: true)
    }()

    static func url(for a: ChatAttachment) -> URL { root.appendingPathComponent("\(a.id.uuidString).\(a.ext)") }
    static func exists(_ a: ChatAttachment) -> Bool { FileManager.default.fileExists(atPath: url(for: a).path) }

    /// 别的设备同步来的资源（CKAsset 的临时文件）→ 本机目录（已有就不动）。
    static func ingest(_ a: ChatAttachment, from temp: URL) {
        guard !exists(a) else { return }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: temp, to: url(for: a))
        } catch { DevLog.shared.warn("智能体对话", "附件「\(a.name)」没存到本机：\(error.localizedDescription)") }
    }

    /// 用户挑的文件 / 图片 → 本机一份 + 抽文字。图片统一转成缩过的 JPEG。
    static func prepare(fileAt source: URL) async throws -> ChatAttachment {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let name = source.lastPathComponent
        let type = UTType(filenameExtension: source.pathExtension)
        if type?.conforms(to: .image) == true {
            guard let data = try? Data(contentsOf: source) else { throw ChatAttachmentError.unreadable(name) }
            return try await prepare(imageData: data, name: name)
        }
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxFileBytes else { throw ChatAttachmentError.tooLarge(name, maxFileBytes / 1024 / 1024) }
        var a = ChatAttachment(id: UUID(), kind: .file, name: name, ext: source.pathExtension.isEmpty ? "bin" : source.pathExtension.lowercased(),
                               byteCount: size)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do { try FileManager.default.copyItem(at: source, to: url(for: a)) } catch { throw ChatAttachmentError.unreadable(name) }
        a.extractedText = extractText(fileAt: url(for: a), type: type)
        return a
    }

    /// 相册 / 粘贴来的图片数据 → 缩到长边 2048 的 JPEG + 文字识别。
    static func prepare(imageData: Data, name: String = "图片.jpg") async throws -> ChatAttachment {
        guard let src = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                     kCGImageSourceThumbnailMaxPixelSize: imageMaxSide,
                                                                     kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
        else { throw ChatAttachmentError.unreadable(name) }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { throw ChatAttachmentError.unreadable(name) }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ChatAttachmentError.unreadable(name) }
        let stem = (name as NSString).deletingPathExtension
        var a = ChatAttachment(id: UUID(), kind: .image, name: (stem.isEmpty ? "图片" : stem) + ".jpg", ext: "jpg", byteCount: out.length)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try (out as Data).write(to: url(for: a), options: .atomic)
        a.extractedText = await recognizeText(image)
        return a
    }

    // MARK: 抽文字（端侧）

    static func extractText(fileAt url: URL, type: UTType?) -> String? {
        if type?.conforms(to: .pdf) == true, let doc = PDFDocument(url: url) { return clip(doc.string) }
        if type?.conforms(to: .text) == true || type?.conforms(to: .sourceCode) == true || ["md", "csv", "json", "txt"].contains(url.pathExtension.lowercased()) {
            return clip(try? String(contentsOf: url, encoding: .utf8))
        }
        return nil
    }

    static func recognizeText(_ image: CGImage) async -> String? {
        await withCheckedContinuation { c in
            let request = VNRecognizeTextRequest { req, _ in
                let lines = (req.results as? [VNRecognizedTextObservation] ?? []).compactMap { $0.topCandidates(1).first?.string }
                c.resume(returning: clip(lines.joined(separator: "\n")))
            }
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.usesLanguageCorrection = true
            do { try VNImageRequestHandler(cgImage: image).perform([request]) } catch { c.resume(returning: nil) }
        }
    }

    static func clip(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t.count > textLimit ? String(t.prefix(textLimit)) + "…（后面省略）" : t
    }

    // MARK: 给智能体

    /// user_message 事件里的附件说明（两种智能体共用）。path = 桥接目录里的相对路径（只 Claude Code 通道有）。
    static func agentPayload(_ list: [ChatAttachment], paths: [UUID: String] = [:]) -> [[String: Any]] {
        list.map { a in
            var o: [String: Any] = ["name": a.name, "kind": a.kind.rawValue, "size": a.sizeLabel,
                                    "text": a.extractedText ?? (a.kind == .image ? "（图片里没识别出文字）" : "（这个文件抽不出文字）")]
            if let p = paths[a.id] { o["path"] = p }
            return o
        }
    }
}
