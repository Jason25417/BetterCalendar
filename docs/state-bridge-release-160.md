# 0.65.3 (160) 发布回执

2026-10-05。原生 App 用作私有状态采集伴随端，任务计时入口在 Dot。

- Git实现已推送：`fc7f976`；构建源码补齐`4d10865`；事件协议/真机清单`380f88f`；Apple要求的HealthKit用途说明`2f944cf`。
- Mac：archive/export upload均成功；ASC build `cbbc34fc-c6c3-4fbb-9917-846ee720d30d`，version0.65.3/build160，VALID，IN_BETA_TESTING；中文测试说明已保存。
- iPhone：首包export因缺少NSHealthUpdateUsageDescription被Apple校验拒绝。补充只读说明后从源代码重新archive，重传成功；ASC build `ea9b0e76-d398-4ee1-a343-9363cf9df010`，version0.65.3/build160，VALID，IN_BETA_TESTING；中文测试说明已保存。健康请求toShare为空，未新增写权限。
- 私有服务：Sites同项目最终源码`61ea423e0ad24106f2e12d38e6945053d24b1fb7`，部署`appgdep_6ac3c40cee348191baacb0731a8d71bf` succeeded，env revision1；https://jason-state-bridge.jason25417.chatgpt.site 。
- 合成上传已确认服务器接收与分钟批次生成。设备凭据读全部状态返回401，符合预期。
- 本次发布未改SwiftData/CloudKit模型，无新生产schema部署；App默认采集关闭。

## 仍需完成的一次连接

15:47 UTC，Jason安装「个人状态接入」后，Codex通过正式插件成功调用read_instructions/read_connection_status/read_current_state；用户身份与读取权限已验证。当前来源仍只有过期的synthetic bridge.probe，subscriptions为空；已通知Dot建立正式订阅，不能把插件安装当作自动推送启用。

Mac/iPhone还需从私有网页复制配置到App，开启并授予系统权限；iPhone的App/Focus状态另配置快捷指令个人自动化。到Dot实际处理的全链路以acknowledge_batch为证据，目前尚未确认真实设备状态或正式订阅。

15:51 UTC，Dot正式创建事件自动化两次，均仅返回`task service unexpected error`，没有error code/data.reason。服务端订阅仍为空，不能宣称自动推送启用。另已确认本机安装Mac160，但Computer Use读取界面失败，未代操作本地设置。网页在缺少用户ID时有401；为此新增平台登录入口，未接受邮箱、服务凭据或自定义用户头替代稳定的登录用户ID。MCP失败诊断只记录方法、错误类别/状态与reason，不记录身份、回调地址、密钥或观察内容。

15:55 UTC，诊断/网页登录补丁源码`391a0a368387de3cc5309643ea0aac4ff7a04572`部署`appgdep_6ac3c852c284819184c0c8d4b02af687` succeeded，保留私有访问与env revision1。核心SQLite 4/4、TypeScript与Worker构建再次通过；已交接Dot作正式订阅重试。无需新TestFlight构建。

独立云端分钟时钟源码在StateBridge/clock，Wrangler dry-run已通过，但Cloudflare CLI当前未连接，尚未部署。Mac在线的60秒循环与手机事件触发仍可转发；不承诺设备离线时独立主动唤醒。不能把iOS后台采集改成固定分钟计时器。
