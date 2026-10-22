//
//  ChatAttachmentTests.swift
//  BetterCalendarTests
//
//  W36：对话里发图片 / 文件——旧消息照常解码、只发附件也能发、端侧抽文字交给智能体、图片缩成 JPEG。内存中转 + 临时目录。
//

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import BetterCalendar

@MainActor @Suite struct ChatAttachmentTests {
    @Test func oldMessagesWithoutAttachmentsStillDecode() throws {
        let m = AgentChatMessage(id: UUID(), createdAt: Date(timeIntervalSince1970: 1_800_000_000), author: .user, deviceId: "mac",
                                 deviceLabel: "Mac", text: "hi")
        let data = try JSONEncoder().encode(m)
        #expect(!(String(data: data, encoding: .utf8) ?? "").contains("attachments"))
        #expect(try JSONDecoder().decode(AgentChatMessage.self, from: data).attachments == nil)
    }

    @Test func textFileIsCopiedAndItsTextGoesToTheAgent() async throws {
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("syllabus-\(UUID().uuidString).txt")
        try "Midterm: Oct 30\nFinal: Dec 12".write(to: src, atomically: true, encoding: .utf8)
        let a = try await ChatAttachmentStore.prepare(fileAt: src)
        #expect(a.kind == .file && a.ext == "txt" && ChatAttachmentStore.exists(a))
        #expect(a.extractedText?.contains("Midterm: Oct 30") == true)
        let payload = ChatAttachmentStore.agentPayload([a], paths: [a.id: "chat/attachments/x.txt"])
        #expect(payload.first?["text"] as? String == a.extractedText && payload.first?["path"] as? String == "chat/attachments/x.txt")
    }

    @Test func imagesAreShrunkToJPEG() async throws {
        let ctx = try #require(CGContext(data: nil, width: 4000, height: 3000, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 4000, height: 3000))
        let image = try #require(ctx.makeImage())
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil); #expect(CGImageDestinationFinalize(dest))
        let a = try await ChatAttachmentStore.prepare(imageData: out as Data, name: "课表.png")
        #expect(a.kind == .image && a.name == "课表.jpg" && a.ext == "jpg")
        let src = try #require(CGImageSourceCreateWithURL(ChatAttachmentStore.url(for: a) as CFURL, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        #expect((props[kCGImagePropertyPixelWidth] as? Int) == 2048)
        #expect(ChatAttachmentStore.agentPayload([a]).first?["text"] as? String == "（图片里没识别出文字）")
    }

    /// 真机自测 10-22：Mac 上用回形针选一张带字的 PNG 加不上（文本文件可以、iPhone 相册可以）。走的是 prepare(fileAt:) 的图片分支 + 真有字的识别。
    @Test func pickedImageFileWithTextBecomesAnAttachment() async throws {
        let ctx = try #require(CGContext(data: nil, width: 900, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 900, height: 300))
        let line = CFAttributedStringCreate(nil, "MATH 5529 Friday 10:00" as CFString,
                                            [kCTFontAttributeName: CTFontCreateWithName("Helvetica" as CFString, 64, nil)] as CFDictionary)!
        ctx.textPosition = CGPoint(x: 30, y: 120); CTLineDraw(CTLineCreateWithAttributedString(line), ctx)
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("课表-\(UUID().uuidString).png")
        let dest = try #require(CGImageDestinationCreateWithURL(src as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try #require(ctx.makeImage()), nil); #expect(CGImageDestinationFinalize(dest))

        let a = try await ChatAttachmentStore.prepare(fileAt: src)
        #expect(a.kind == .image && a.ext == "jpg" && ChatAttachmentStore.exists(a))
        #expect(a.extractedText?.contains("5529") == true)
    }

    @Test func attachmentOnlyMessagesSendAndReachTheAgentEvent() async throws {
        let base = W20BuiltinAgentTests()
        let e = base.env()
        e.selection.select(.builtin)
        let a = ChatAttachment(id: UUID(), kind: .file, name: "考试安排.pdf", ext: "pdf", byteCount: 1234, extractedText: "期中 10 月 30 日")
        let m = try #require(await e.chat.send("  ", attachments: [a]))
        #expect(m.attachments == [a] && m.text.isEmpty)
        await e.chat.refresh()
        #expect(e.chat.messages.first { $0.id == m.id }?.attachments == [a])   // 经中转存取后还在
        await e.hub.pumpMessages()
        e.model.script = [W20BuiltinAgentTests.FakeModel.done()]
        await e.runtime.processPending()
        let event = try #require(e.model.requests.first?[1].content)
        #expect(event.contains("考试安排.pdf") && event.contains("期中 10 月 30 日") && event.contains("附 1 个图片"))
        #expect(await e.chat.send("", attachments: []) == nil)   // 什么都没有不发
    }
}
