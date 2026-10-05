import AppIntents
import Foundation

struct SubmitPersonalStateIntent: AppIntent {
    static var title: LocalizedStringResource = "发送个人状态"
    static var description = IntentDescription("将快捷指令自动化的应用、专注模式或家居变化发给 Dot；不启动或暂停任务计时。")
    @Parameter(title:"来源（ios.app、ios.focus、home.occupancy 或 user.context）") var source: String
    @Parameter(title:"状态 JSON") var stateJSON: String
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard StateBridgeCollector.shared.enabled, StateBridgeClient.shared.configured else { return .result(dialog:"个人状态采集尚未启用；请在设置里连接。") }
        guard ["ios.app","ios.focus","home.occupancy","user.context"].contains(source),stateJSON.utf8.count < 16000 else { return .result(dialog:"来源或内容无效。") }
        let value = try JSONDecoder().decode(BridgeJSON.self,from:Data(stateJSON.utf8))
        StateBridgeClient.shared.emit(source,value:value,validFor:source == "ios.app" ? 600 : 3600)
        await StateBridgeClient.shared.uploadAndFlush()
        return .result(dialog:"\(StateBridgeClient.shared.status)")
    }
}
