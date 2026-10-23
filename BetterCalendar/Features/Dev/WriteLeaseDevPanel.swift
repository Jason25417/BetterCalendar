import SwiftUI

/// W22 写权租约（开发者选项，两端共用）：现在谁在写自动调整、为什么；附应急总闸。
/// 开发期界面：能用不乱即可（不做交互设计）。
struct WriteLeaseDevPanel: View {
    @AppStorage(TimelineWriteLease.enabledKey) private var enabled = true
    @State private var lease = TimelineWriteLease.sharedForDev
    @State private var tick = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("多台设备只让一台写自动调整", isOn: $enabled)
            Text("打开（默认）：顺延 / 活动预报 / 启动补结算只由一台设备写——正在计时的设备优先，其次最近回到前台的设备；其他设备只算不写。你的拖动、批准、删除、日历里的改动不受影响。关掉 = 回到每台设备都写（会让计划块来回翻），只在怀疑它出问题时用；随设置同步到所有设备。")
                .font(.caption).foregroundStyle(.secondary)
            if let lease {
                Text(lease.statusLine).font(.callout).textSelection(.enabled)
                    .id(tick)
                Text("最近变化：\(lease.lastChangeNote)").font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button("刷新") { lease.reloadFromStore(); tick += 1 }
            } else {
                Text("写权租约没有接上（测试环境或启动未完成）").font(.caption).foregroundStyle(.orange)
            }
        }
    }
}
