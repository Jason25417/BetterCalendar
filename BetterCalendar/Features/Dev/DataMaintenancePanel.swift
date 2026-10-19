import SwiftUI
import UniformTypeIdentifiers

/// Development-only diagnostic and data interchange controls, shared by Mac and iOS Settings.
struct DataMaintenancePanel: View {
    @State private var monitor = DataSyncMonitor.shared
    @State private var maintenance = DataMaintenance.shared
    @State private var bridge = DataMaintenance.shared.bridgeEnabled
    @State private var importing = false
    @State private var result = ""
    @State private var focus = FocusSyncDiagnostics.shared
    @State private var syncReport: URL?

    /// 三个子视图在 Form 的 Section 里各成一行（诊断 / 导出 / 修改入口），导出结果不会被大行吞掉。
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(monitor.storage).font(.callout)
            Text(monitor.account).font(.caption)
            #if DEBUG
            Button("开发 schema：创建不活动的执行状态样本") {
                Task {
                    do {
                        try await FocusFollow.seedDevelopmentSchema()
                        result = "已保存不活动样本。请在 CloudKit Console 核对 Development 环境后部署 schema；没有开始任何计时。"
                    } catch { result = error.localizedDescription }
                }
            }
            #endif
            Text("最近收到云端数据：\(stamp(monitor.lastImport))\n最近上传完成：\(stamp(monitor.lastExport))")
                .font(.caption).foregroundStyle(.secondary)
            Text("执行状态：动作立即发送 · 活动时每 5 秒补查 · 空闲时每 15 秒补查 · 60 秒续报")
                .font(.caption).foregroundStyle(.secondary)
            Text("执行状态最近上传：\(stamp(focus.lastWrite))\n最近查询：\(stamp(focus.lastRead))\n推送订阅：\(focus.subscriptionReady ? "本次启动已就绪" : "尚未确认")")
                .font(.caption).foregroundStyle(.secondary)
            if let receipt = focus.latestReceived {
                Text("最近收到：\(receipt.action) · 表观延迟 \(String(format: "%.2f", receipt.apparentAgeSeconds)) 秒\n查询往返 \(String(format: "%.2f", receipt.requestSeconds)) 秒 · 来源 \(receipt.trigger)")
                    .font(.caption).textSelection(.enabled)
            }
            if let issue = focus.issue { Text(issue).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button("导出双端同步测量") {
                    perform { syncReport = try focus.export(to: maintenance.directory) }
                }
                if let syncReport { ShareLink("分享同步测量", item: syncReport) }
            }
            Text("测量只含最近 100 条状态回执，不含任务标题。表观延迟含两端时钟偏差；首次读到旧状态也不代表它刚刚传输。需对照两端报告，才能确认动作到达时间。")
                .font(.caption).foregroundStyle(.secondary)
            if let issue = monitor.issue { Text("最近发现的问题：" + issue).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            Button("检查账号并重读本机数据") {
                monitor.refreshNow()
                Task { await monitor.checkAccount() }
                Task { await FocusFollow.ensureSubscription() }
                Task { await FocusFollow.refreshAndApply(reason: "手动检查") }
            }
        }
        // W19b：导出单独一行，结果（成功/失败）就写在按钮下面那一行 message 里——
        // 0.69.1 时失败文字是大面板末尾「新长出来的一行」，Jason 看不到，等于静默失败。
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("导出完整数据档案") {
                    result = ""
                    // 失败已由 exportArchive 写进下面的 message（橙色）+ DevLog 错误，这里不重复显示
                    _ = try? maintenance.exportArchive()
                }
                .accessibilityIdentifier("bc.data.export")
                if let url = maintenance.latestArchive {
                    ShareLink("分享档案", item: url)
                    Button("校验刚导出的档案") { perform { try maintenance.validate(url) } }
                }
                Button("选择档案做恢复校验") { importing = true }
            }
            Text(maintenance.message)
                .font(.caption).foregroundStyle(maintenance.message.hasPrefix("导出没成功") ? Color.orange : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityIdentifier("bc.data.export.status")
            #if os(macOS)
            Text(maintenance.autoSnapshotIssue ?? "自动快照：每 20 小时存一份到 \(maintenance.autoSnapshotDirectory.path)（发版前保险，只存本机）")
                .font(.caption).foregroundStyle(maintenance.autoSnapshotIssue == nil ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            #endif
            if !result.isEmpty {
                Text(result).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        VStack(alignment: .leading, spacing: 8) {
            Toggle("开发期：允许文件请求修改数据", isOn: $bridge)
                .onChange(of: bridge) { _, v in maintenance.bridgeEnabled = v }
            if bridge {
                Text("修改入口：\(maintenance.directory.path)/request.json\n只接受带原值的既有记录修改；每次写入前保存档案。")
                    .font(.caption).textSelection(.enabled)
            }
            Text("云同步由系统调度，后台无法保证固定秒数。恢复校验只操作隔离空库；不会覆盖日用数据。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { response in
            perform {
                let url = try response.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                try maintenance.validate(url)
            }
        }
    }

    private func stamp(_ date: Date?) -> String {
        date?.formatted(date: .abbreviated, time: .standard) ?? "本次启动尚无回执"
    }
    private func perform(_ operation: () throws -> Void) {
        do { try operation(); result = "" }
        catch { result = error.localizedDescription }
    }
}
