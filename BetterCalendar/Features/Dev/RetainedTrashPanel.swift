import SwiftUI

struct RetainedTrashPanel: View {
    let service: any TrashManaging
    @State private var items: [TrashItem] = []
    @State private var failure: String?
    @State private var restoring = false

    var body: some View {
        DisclosureGroup("回收站（\(items.count)）") {
            Text("删除后至少保留 30 天。本阶段不自动永久清除；恢复会保留原来的内容与关联。")
                .font(.caption).foregroundStyle(.secondary)
            if items.isEmpty { Text("没有待恢复的记录").foregroundStyle(.secondary) }
            ForEach(items) { item in
                HStack {
                    VStack(alignment: .leading) {
                        Text(item.title).lineLimit(2)
                        Text("\(item.category) · 删除于 \(item.deletedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("恢复") {
                        restoring = true
                        Task { @MainActor in
                            defer { restoring = false }
                            do { try await service.restore(item); load() }
                            catch {
                                failure = error.localizedDescription
                                DataSyncMonitor.shared.report("恢复未完成：\(error.localizedDescription)")
                            }
                        }
                    }.disabled(restoring)
                }
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
            Button("刷新") { load() }.disabled(restoring)
        }
        .onAppear { load() }
        .onReceive(NotificationCenter.default.publisher(for: DataSyncMonitor.dataChanged)) { _ in load() }
    }

    private func load() {
        do { items = try service.entries(); failure = nil }
        catch { failure = error.localizedDescription }
    }
}
