//
//  ChatComposerTools.swift
//  BetterCalendar
//
//  W36：输入框旁的语音 / 图片 / 文件（首页「跟智能体说一句」与对话页共用）。界面先能用（Jason 还在想 UI，之后再定样子）。
//

import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// 输入框右侧的按钮：附件（iPhone 另有相册）+ 麦克风。听写的字接在你已经打的字后面；附件挂在 attachments 上，随下一条消息发出。
struct ChatComposerTools: View {
    @Binding var text: String
    @Binding var attachments: [ChatAttachment]
    /// 出错 / 处理中的一行说明（父视图显示在输入框上方）。
    @Binding var status: String?
    @State private var dictation = SpeechDictation()
    @State private var base = ""
    @State private var importing = false
    #if os(iOS)
    @State private var photos: [PhotosPickerItem] = []
    #endif

    var body: some View {
        HStack(spacing: 4) {
            #if os(iOS)
            PhotosPicker(selection: $photos, maxSelectionCount: ChatAttachmentStore.maxPerMessage, matching: .images) {
                Image(systemName: "photo").font(.title3)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("发图片")
            .onChange(of: photos) { _, items in
                guard !items.isEmpty else { return }
                Task { await addPhotos(items); photos = [] }
            }
            #endif
            Button { importing = true } label: { Image(systemName: "paperclip").font(.title3) }
                .buttonStyle(.borderless)
                .accessibilityLabel("发文件或图片")
                .accessibilityIdentifier("bc.chat.attach")
            Button {
                if !dictation.isListening { base = text; dictation.clearError() }
                dictation.toggle()
            } label: {
                Image(systemName: dictation.isListening ? "mic.fill" : "mic").font(.title3)
                    .foregroundStyle(dictation.isListening ? Color.accentColor : Color.secondary)
                    .symbolEffect(.pulse, isActive: dictation.isListening)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(dictation.isListening ? "停止听写" : "语音输入")
            .accessibilityIdentifier("bc.chat.mic")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case let .success(urls): Task { await addFiles(urls) }
            case let .failure(error): status = "没选到文件：\(error.localizedDescription)"
            }
        }
        .onAppear {
            dictation.onTranscript = { heard in text = base.isEmpty ? heard : base + " " + heard }
        }
        .onChange(of: dictation.state) { _, s in
            switch s {
            case let .failed(why): status = why
            case .listening: status = "正在听…再点一下麦克风结束"
            case .starting: status = nil
            case .idle: if status == "正在听…再点一下麦克风结束" { status = nil }
            }
        }
        .onDisappear { if dictation.isListening { dictation.stop() } }
    }

    private var room: Int { ChatAttachmentStore.maxPerMessage - attachments.count }

    private func addFiles(_ urls: [URL]) async {
        guard room > 0 else { status = "一条消息最多 \(ChatAttachmentStore.maxPerMessage) 个附件"; return }
        status = "正在处理附件…"
        var problems: [String] = []
        for url in urls.prefix(room) {
            do { attachments.append(try await ChatAttachmentStore.prepare(fileAt: url)) }
            catch { problems.append(error.localizedDescription) }
        }
        status = problems.isEmpty ? nil : problems.joined(separator: "；")
    }

    #if os(iOS)
    private func addPhotos(_ items: [PhotosPickerItem]) async {
        guard room > 0 else { status = "一条消息最多 \(ChatAttachmentStore.maxPerMessage) 个附件"; return }
        status = "正在处理图片…"
        var problems: [String] = []
        for item in items.prefix(room) {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { problems.append("有一张图片读不出来"); continue }
                attachments.append(try await ChatAttachmentStore.prepare(imageData: data))
            } catch { problems.append(error.localizedDescription) }
        }
        status = problems.isEmpty ? nil : problems.joined(separator: "；")
    }
    #endif
}

/// 还没发出去的附件（输入框上方一排，可去掉）。
struct ChatAttachmentStrip: View {
    @Binding var attachments: [ChatAttachment]
    var body: some View {
        if !attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(attachments) { a in
                        HStack(spacing: 6) {
                            ChatAttachmentThumb(attachment: a, side: 32)
                            Text(a.name).font(.caption).lineLimit(1).frame(maxWidth: 140, alignment: .leading)
                            Button { attachments.removeAll { $0.id == a.id } } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless).foregroundStyle(.secondary)
                                .accessibilityLabel("去掉「\(a.name)」")
                        }
                        .padding(4)
                        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }
}

/// 消息里的附件：图片显示缩略图，文件显示名字和大小。
struct ChatAttachmentView: View {
    let attachment: ChatAttachment
    var body: some View {
        if attachment.kind == .image, let image = ChatAttachmentThumb.load(attachment) {
            image.resizable().scaledToFit().frame(maxWidth: 220, maxHeight: 220)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel(attachment.name)
        } else {
            HStack(spacing: 8) {
                ChatAttachmentThumb(attachment: attachment, side: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(attachment.name).font(.callout).lineLimit(1)
                    Text(ChatAttachmentStore.exists(attachment) ? attachment.sizeLabel : attachment.sizeLabel + " · 还没同步到这台设备")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

struct ChatAttachmentThumb: View {
    let attachment: ChatAttachment
    let side: CGFloat
    var body: some View {
        if attachment.kind == .image, let image = Self.load(attachment) {
            image.resizable().scaledToFill().frame(width: side, height: side).clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Image(systemName: attachment.ext == "pdf" ? "doc.richtext" : "doc").font(.system(size: side * 0.55))
                .frame(width: side, height: side).foregroundStyle(.secondary)
        }
    }

    static func load(_ a: ChatAttachment) -> Image? {
        let url = ChatAttachmentStore.url(for: a)
        #if os(macOS)
        return NSImage(contentsOf: url).map(Image.init(nsImage:))
        #else
        return UIImage(contentsOfFile: url.path).map(Image.init(uiImage:))
        #endif
    }
}
