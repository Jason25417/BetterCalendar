# 个人状态接入（内测）

2026-10-05。主入口是 Dot 对话；现有 BetterCalendar 暂时只作为 Mac/iPhone 采集伴随 App。

## 使用

1. 用 Jason 同一账户连接「个人状态接入」插件。
2. 在各设备打开 https://jason-state-bridge.jason25417.chatgpt.site ，点「复制 Mac 配置」或「复制 iPhone 配置」。如提示需要登录，先点「用 ChatGPT 登录」，使用同一账户；不通过放宽权限绕过登录。
3. 在 0.65.3 (160) 内测 App → 设置 → 个人状态与 Dot，粘贴配置、保存、启用采集、授予采集权限。Mac 可开启原有登录时启动，保持 App 常驻；关闭窗口仍有菜单栏。
4. iPhone 如需后台位置，另点「允许后台位置更新」。快捷指令自动化使用「发送个人状态」，来源与 JSON 示例见下。
5. 向 Dot 说开始、暂停、继续或结束任务。必须看到计时工具保存成功，不能把自然语言口头答复当作持久化成功。

私有网页只有同一账户可看。配置含上传凭据，仅进本机 Keychain，不要粘贴到聊天或公开分享。取消采集会停止传感器订阅；取消设备凭据可在认证接口撤销设备。

## 采集实现与边界

| 来源 | 方式 | 周期 / 触发 | 状态 |
|---|---|---|---|
| Mac 前台 App / idle | NSWorkspace + CoreGraphics；不记录按键 | 切换事件；15秒确认空闲类别；60秒上传 | 已实现，须连接设备 |
| Mac 浏览器 | 支持浏览器的 AppleScript，URL去query/fragment | 每60秒前台快照 | 已实现，须 Automation 权限 |
| 日历 | EventKit只读，过去1天 / 未来14天 | 在线每60秒快照 | 已实现，须系统权限；截断有标记 |
| 提醒事项 | EventKit未完成事项 | 在线每60秒快照 | 已实现，须系统权限；截断有标记 |
| 所选文件夹 | security-scoped bookmark，只读直属文件名称/修改时间 | 每60秒，最近30件 | 已实现，须选目录；不是整个磁盘全文 |
| Computer History | 所选输出目录的有界事件尾部；仅App/窗口/URL | 每60秒，最近上下文 | 已实现补充入口；不传AX或键盘文字；不代表capture正在运行 |
| iPhone sleep / steps / workouts / resting HR | HealthKit observer +只读快照 | 变化回调；前台快照；后台由系统决定 | 已实现，真机权限/后台延迟待验收 |
| iPhone location / visits | CoreLocation significant-change / visits | 系统事件，粗粒度位置 | 已实现，不保证分钟更新 |
| iPhone walking/cycling/driving | CoreMotion activity | 系统事件，原置信等级 | 已实现，不能当活动已确认 |
| Home 存在/运动传感器 | HomeKit characteristic读与通知 | 在线通知/读取 | 已实现；后台、远程中枢、桌/床分区身份待实测 |
| iPhone App / Focus | 原生 AppIntent 接快捷指令自动化 | App打开/关闭、Focus变化 | 动作已实现；每台设备需配置自动化 |
| 邮箱 / 云日历 / Drive / GitHub / 课程 | Dot复用已有连接与事件源 | 其连接支持的事件，相关问题时查最新 | 已交接Dot；未宣称全部每分钟推送 |
| 用户意图 / 纠正 / 候选事项 | Dot `record_context` | 对话即时写入；有效期按表述 | 工具已上线，须插件连接 |
| 任务计时 | Dot `task_command` | 用户明确开始/暂停/继续/结束 | 工具已上线；重试去重、revision冲突检查 |
| 天气 / 路程 | Dot按当前地点与问题读取 | 需要出门建议时 | 复用现有查询；不轮询完整生活档案 |

Windows 不在本次已安装设备范围。暂未验证 Home Assistant/MQTT 存在，不虚构现成网关。

## 快捷指令

「App打开/关闭」个人自动化 → 发送个人状态：

- 来源 `ios.app`，JSON `{"app":"指定应用名","state":"opened"}` 或 `closed`。
- 来源 `ios.focus`，JSON `{"focus":"指定专注模式","enabled":true}` / `false`。
- 家居自动化可传 `home.occupancy`，JSON必须含真实的区域标识和值，例如 `{"zone":"confirmed-desk-zone","occupied":true}`。区域需实测，不能因传感器名含FP2 2就叫它床区。
- `user.context` 可传明确说明；原始来源仍标记Shortcut，不代表App已观察到生活事实。

Apple 个人自动化不能靠iCloud同步自动迁移到另一台设备。Home自动化的常驻执行与远程访问需要真实可用的家居中枢，本轮未确认。

## 每分钟与离线

Mac 活跃采集器每60秒上传并调用 flush；手机回调也能直接保存并触发当前分钟批次。服务用UTC分钟桶去重，每分钟最多一个批次，发全部已收到的变化，未变化不发。该分钟首批发送后新到变化进入下分钟。断网队列重试保留eventId与原发生时间；旧序号不覆盖当前状态。补传按原时间解释。

本版本没有已验证的独立云端一分钟调度器。Mac退出/休眠且没有手机事件时，过期状态在下一次flush记账；读取时即时显示stale。不能承诺所有设备离线时Dot仍每分钟处理。MCP webhook接收后模型由平台异步处理，分析频率/延迟另验收。

## 数据与计时

设备观察、用户说明、推断独立保存。当前状态可重建，历史不会因新分类被覆写；纠正用supersedes而非删除原观察。设备超时不等于睡着，空闲不自动暂停显式任务。计时以已保存时间戳计算，暂停段不累计，不依赖模型常驻。

D1迁移使用Drizzle增量SQL；已经部署的迁移不改写。服务记录observedAt/receivedAt、批次时间、回调接收与Dot处理时间。默认长期保留；本轮不执行自动清理，也未实现删除界面。旧BetterCalendar SwiftData/CloudKit模型没有改变。

## 验证

- 核心SQLite测试：重复/乱序/过期恢复、幂等计时与并发版本、分钟批次/签名重试、纠正保留历史。
- `cd server && node --test tests/bridge.test.mjs`；`npx tsc --noEmit`。
- Mac项目门控与iOS Simulator build均需通过；真机的系统权限、电量、后台时效不由编译结果证明。
- 服务已私有发布；正式订阅、挑战验证、合成事件发送和Dot自动读取/理解/acknowledge_batch已确认。单次回调接收约1.7秒、模型处理约70秒；真实设备覆盖、后台延迟与续约仍待实测。

`tools/provision.py`只做私有上传链路登记/合成测试，凭据通过隐藏stdin，不写Git或日志。临时配置文件权限0600，App运行凭据存Keychain。Sites独立源码仓库负责云服务发布；本项目保留其可重复构建的源码副本，排除嵌套Git、依赖和运行目录。
