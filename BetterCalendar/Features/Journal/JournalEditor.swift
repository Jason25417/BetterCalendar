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

    @State private var previewing = false
    @State private var newTag = ""
    @State private var picked: [PhotosPickerItem] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("改动自动保存 · \(entry.modifiedAt.formatted(date: .omitted, time: .standard))",
                  systemImage: "checkmark.circle.fill")
                .font(.caption2).foregroundStyle(.green)

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
                    .background(Color.secondary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                TextEditor(text: $entry.body)
                    .frame(minHeight: 160)
                    .onChange(of: entry.body) { _, _ in touch() }
            }

            tagRow
            photoRow
        }
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
                            .background(Color.blue.opacity(0.12)).clipShape(Capsule())
                        }
                    }
                }
            }
            HStack {
                TextField("加标签", text: $newTag).textFieldStyle(.roundedBorder).frame(maxWidth: 160)
                    .onSubmit { addTag() }
                Button("加") { addTag() }
                    .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
            }
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
                            }
                        }
                    }
                }
            }
            // 加照片：iOS/Mac 都能从照片库选；Mac 额外能"从文件选"+"粘贴图片"（加照片更广更轻）
            HStack {
                PhotosPicker(selection: $picked, maxSelectionCount: 5, matching: .images) {
                    Label("从照片库", systemImage: "photo.badge.plus")
                }
                .onChange(of: picked) { _, items in Task { await importPhotos(items) } }
                #if os(macOS)
                Button { importFromFiles() } label: { Label("从文件…", systemImage: "folder") }
                Button { pasteImage() } label: { Label("粘贴图片", systemImage: "doc.on.clipboard") }
                    .help("剪贴板里是图片时，直接作为照片加进来（截图/网图复制后点这里）")
                #endif
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
        photoStore.delete(ref); entry.photoRefs.removeAll { $0 == ref }; touch()
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
    private func touch() { entry.modifiedAt = .now; model.save() }
}
