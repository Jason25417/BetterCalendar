import SwiftUI

struct StateBridgeSettingsPanel: View {
    @State private var credentials = ""
    @State private var enabled = StateBridgeCollector.shared.enabled
    @State private var error: String?
    #if os(macOS)
    @State private var folderCount = StateBridgeCollector.shared.selectedFolderCount
    #endif
    private let client = StateBridgeClient.shared
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Text("Dot 接收设备状态；任务开始、暂停和结束直接在对话里说。")
            SecureField("粘贴设备配置 JSON（保存到本机 Keychain）",text:$credentials)
            HStack {
                Button("保存连接") { do { try client.configure(credentials); credentials = ""; error = nil; StateBridgeCollector.shared.start() } catch { self.error = error.localizedDescription } }
                Button("授予采集权限") { Task { await StateBridgeCollector.shared.requestPermissions() } }.disabled(!client.configured || !enabled)
            }
            Toggle("启用个人状态采集",isOn:$enabled).onChange(of:enabled) { _,value in StateBridgeCollector.shared.setEnabled(value) }
            #if os(macOS)
            Button("选择要观察的文件夹（可多选）…") { StateBridgeCollector.shared.chooseFilesFolder(); folderCount = StateBridgeCollector.shared.selectedFolderCount }.disabled(!client.configured)
            Text("已选择 \(folderCount) 个目录；包含子文件夹，排除缓存、依赖和凭据。推荐：学习、Developer、Documents、Desktop、Downloads。 ").font(.caption).foregroundStyle(.secondary)
            Button("选择 Computer History 数据目录…") { StateBridgeCollector.shared.chooseHistoryFolder() }.disabled(!client.configured)
            Text("Mac 在线时每分钟上传变化；浏览器首次读取会请求 Automation 权限。文件只读取名称与修改时间。")
            #else
            Button("允许后台位置更新") { StateBridgePhone.shared.requestAlwaysLocation() }.disabled(!enabled)
            Text("健康、位置和家居由 iOS 按系统允许的时机更新；后台不保证每分钟运行。应用／专注模式变化可用快捷指令的「发送个人状态」动作传入。")
            #endif
            Button("现在采集并上传") { Task { await StateBridgeCollector.shared.sample() } }.disabled(!enabled || !client.configured)
            Text(client.status).font(.caption)
            Text("本机待上传：\(client.pendingCount) 条").font(.caption).foregroundStyle(.secondary)
            if let date = client.lastUpload { Text("上次保存：\(date.formatted())").font(.caption).foregroundStyle(.secondary) }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
        }
    }
}
