//
//  JournalEditor.swift
//  BetterCalendar
//
//  日记编辑器（R2，todayCard 与 详情页 共用）：心情 / 正文(Markdown 编辑+预览) / 标签 / 照片。
//  编辑直接改 @Model 属性 + 自动 save。
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct JournalEditor: View {
    @Bindable var entry: JournalEntry
    let model: JournalViewModel
    let photoStore: PhotoStore
    @Environment(\.appTheme) private var theme   // 令牌表 v1（换装批次 B）

    @State private var previewing = false
    @State private var newTag = ""
    @State private var picked: [PhotosPickerItem] = []
    /// W31 自测：iPhone 上正文键盘原来收不起来（回车=换行、页面也不随滚动收）——键盘盖住底部 tab，人被困在日记页。
    @FocusState private var bodyFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MoodPicker(mood: $entry.mood)
                .onChange(of: entry.mood) { _, _ in touch() }

            HStack {
                Text("正文（Markdown）").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle("预览", isOn: $previewing).toggleStyle(.button).controlSize(.small)
            }
            if previewing {
                Text(JournalBody.rendered(entry.body, format: entry.bodyFormat))
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                    .padding(8)
                    .background(theme.surface)   // 换装 C：正文区=surface 纸面
                    .clipShape(RoundedRectangle(cornerRadius: 12))   // 修正批 D：大容器档=12（条文 5）
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary.opacity(0.4)))
            } else {
                TextEditor(text: $entry.body)
                    .frame(minHeight: 160)
                    .padding(6)                          // 0.33.1：首行贴边被裁（Jason 截图）→ 给呼吸边距
                    .scrollContentBackground(.hidden)
                    .background(theme.surface)   // 换装 C：正文区=surface 纸面
                    .clipShape(RoundedRectangle(cornerRadius: 12))   // 修正批 D：大容器档=12（条文 5）
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary.opacity(0.4)))
                    .onChange(of: entry.body) { _, _ in touch() }
                    .focused($bodyFocused)
                    #if os(iOS)
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("收起键盘") { bodyFocused = false }
                        }
                    }
                    #endif
            }

            tagRow
            photoRow

            // 体检 #19：保存状态=边缘信息 → 底部弱行（caption2/secondary）；positiveTint 留给「做成」语义
            // W31 自测（P4 不虚报）：什么都没写时不显示「已保存 · 时刻」——那时并没有存下一篇（W28b 空条目不算）
            Group {
                if entry.hasAnyInput {
                    Label("改动自动保存 · \(entry.modifiedAt.formatted(date: .omitted, time: .standard))",
                          systemImage: "checkmark.circle")
                } else {
                    Label("写下正文、选个心情或加张照片，就会自动保存", systemImage: "pencil")
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .tint(.primary)   // 修正批 D：编辑器工具行（预览/照片/标签）收中性（条文 2）——正文卡内无主按钮
    }

    // MARK: 标签

    private var tagRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !entry.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(entry.tags, id: \.self) { t in
                            HStack(spacing: 3) {
                                Text("#\(t)").font(.caption)
                                Button { entry.tags.removeAll { $0 == t }; touch() } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }.buttonStyle(.plain).font(.caption2)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(theme.actualTint.opacity(0.12)).clipShape(Capsule())
                        }
                    }
                }
            }
            // #38（0.39.0）：token field 模式——回车即成 chip，退役独立「加」按钮
        }
    }

    // MARK: 照片

    private var photoRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !entry.photoRefs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(entry.photoRefs, id: \.self) { ref in
                            ZStack(alignment: .topTrailing) {
                                if let img = loadImage(ref) {
                                    img.resizable().scaledToFill()
                                        .frame(width: 72, height: 72)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                Button { deletePhoto(ref) } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain).padding(2)
                                    .accessibilityLabel("删除这张照片")
                            }
                        }
                    }
                }
            }
            // 批次6（2026-07-14 Jason 反馈）：工具排减负——照片三入口收一主一辅；「给明天」入口退役
            //（#23 管道休眠：正文手写「给明天：…」仍被晨间提取，但不再有按钮/提示引导）
            HStack {
                PhotosPicker(selection: $picked, maxSelectionCount: 5, matching: .images) {
                    Label("照片", systemImage: "photo.badge.plus")
                }
                .onChange(of: picked) { _, items in Task { await importPhotos(items) } }
                #if os(macOS)
                Menu {
                    Button { importFromFiles() } label: { Label("从文件…", systemImage: "folder") }
                    Button { pasteImage() } label: { Label("粘贴图片", systemImage: "doc.on.clipboard") }
                } label: {
                    Label("更多来源", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
                }
                .accessibilityLabel("更多照片来源")
                .help("从文件挑选，或把剪贴板里的图片直接加进来")
                #endif
                TextField("加标签（回车即加）", text: $newTag)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 170)
                    .onSubmit { addTag() }
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
    }

    // MARK: 动作

    private func addTag() {
        let t = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        newTag = ""
        guard !t.isEmpty, !entry.tags.contains(t) else { return }
        entry.tags.append(t); touch()
    }
    private func deletePhoto(_ ref: String) {
        if photoStore.delete(ref) { entry.photoRefs.removeAll { $0 == ref }; touch() }
    }
    private func importPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self),
               let ref = photoStore.save(data) {
                entry.photoRefs.append(ref)
            }
        }
        picked = []; touch()
    }

    #if os(macOS)
    /// Mac：从本地文件选图片加进来。
    private func importFromFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        var added = false
        for url in panel.urls {
            if let data = try? Data(contentsOf: url), let ref = photoStore.save(data) {
                entry.photoRefs.append(ref); added = true
            }
        }
        if added { touch() }
    }

    /// Mac：剪贴板里是图片时直接作为照片加入（截图/网图复制后一键贴入）。
    private func pasteImage() {
        guard let imgs = NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
              !imgs.isEmpty else { return }
        var added = false
        for img in imgs {
            if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]), let ref = photoStore.save(png) {
                entry.photoRefs.append(ref); added = true
            }
        }
        if added { touch() }
    }
    #endif
    private func loadImage(_ ref: String) -> Image? {
        // 走 PhotoStore.data：本地缓存优先，云端同步来的照片从 DB 取（跨端可见）
        guard let data = photoStore.data(for: ref) else { return nil }
        #if canImport(AppKit)
        if let ns = NSImage(data: data) { return Image(nsImage: ns) }
        #elseif canImport(UIKit)
        if let ui = UIImage(data: data) { return Image(uiImage: ui) }
        #endif
        return nil
    }
    private func touch() {
        entry.modifiedAt = .now; model.save()
        FeatureUsage.usedThrottled(.journalWrite)   // W21：写 / 改日记（打字逐字触发 → 2 分钟内只记一次；不记内容）
    }
}
