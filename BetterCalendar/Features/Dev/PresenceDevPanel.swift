import SwiftUI

/// W30（原则 11）：在场设备 + 一处响的路由记录（开发者选项，两端共用）。开发期界面：能用不乱即可（不做交互设计）。
struct PresenceDevPanel: View {
    @AppStorage(ReachSettings.onePlaceKey) private var onePlace = AppChannel.current.isDev
    @AppStorage(DraftHandoff.enabledKey) private var draftHandoff = AppChannel.current.isDev
    @State private var presence = DevicePresence.sharedForDev
    @State private var reach = ReachOutlet.sharedForDev
    @State private var tick = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("一处响，处处知（实验）", isOn: $onePlace)
            Text("打开：BetterCalendar 自己的通知（早晚通知、审批、智能体消息与对话）只在你此刻所在的那台响，其他设备安静地放一份（不亮屏不出声，只进通知中心）；在一台点开 / 读过，其余的自动收起。闹钟默认设在 iPhone，其他设备到点只放安静镜像。关掉 = 每台照常响，同改动前。随设置同步到所有设备。")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("打了一半的字跨设备接力（实验）", isOn: $draftHandoff)
            Text("打开：在 Mac 上没打完的字，到 iPhone / iPad 上打开同一个输入框（框是空的时候）就接着出现；在任一台发送后，其他设备也不再冒出来。每格最多 4000 字。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            if let presence {
                Text("在场设备：").font(.callout.bold())
                Text(presence.statusLine).font(.callout).textSelection(.enabled).id(tick)
            } else {
                Text("在场设备没有接上（测试环境或启动未完成）").font(.caption).foregroundStyle(.orange)
            }
            if let reach {
                Text("最近的路由决定（本机）：").font(.callout.bold())
                let lines = reach.recentLines
                if lines.isEmpty {
                    Text("还没有通知经过这里").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption).textSelection(.enabled)
                    }
                    .id(tick)
                }
            }
            Button("刷新") {
                presence?.tick()
                if let reach { Task { await reach.reevaluate(); tick += 1 } } else { tick += 1 }
            }
            Text("不经过这里、改派不了的（Apple 自己同步到每台设备）：日历事件的会前提醒、提醒事项的到点提醒、iPhone 系统闹钟本体、App 没运行时 iCloud 直接推送的审批通知。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}
