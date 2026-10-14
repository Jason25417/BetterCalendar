# 审批回传、有效期和 BC 内确认：已实现，未部署

2026-10-14。本轮基于已核对的 `05f4a8145598217a36809c5f14572049932abf5a`，保留 v37 改动。本轮不部署 StateBridge、不发 TestFlight、不改生产数据、不申请系统授权。线上仍 v37，原生仍 0.65.17 / 174。下面的“实现”指源代码和隔离验证，不能理解为手机已经更新。

## 先核对问题和已有修复

- 14:55:27 UTC 的 `cc7f3428-828a-46b9-b5ec-f8bcf0909dc2` 当时未过期，回传遭400；具体额外字段没有保存在旧日志里，仍未知。本轮不重放它，也不改旧哈希、期限或状态。
- 已有 v37 在 `respondForm` 的请求绑定之后，使用 `normalizeFormResponse`，只识别 action/content 及已知非授权 `_meta` 对象、可选 resultType=complete。15:29/15:32 的真实只读回传观察到 action/content/_meta，分别带字符串和布尔字段，成功返回，原关闭命令未执行。这证明该兼容路径实际有效；不能追认旧400一定也是 `_meta`。
- [正式 ElicitResult](https://modelcontextprotocol.io/specification/2026-07-28/schema#elicitresult) 的业务字段是 action/content；本机实际观察到的宿主 `_meta` 作为传输扩展被丢弃，不当授权。日志中的 confirmed=true 是归纳信息，不能据此新增 content.confirmed 授权别名。真实批准仍要求 content.confirm 恰为 boolean true。
- [form elicitation](https://modelcontextprotocol.io/specification/2026-07-28/client/elicitation) 不规定具体宿主UI宽高。电脑 Dots 收缩为2px的缺陷仍未修，原取消来源仍unknown；新增 BC 内确认提供另一个明确的人类按钮入口，不通过默认勾选、自批或复活旧命令规避它。

先完成最小诊断修复并通过21项相关测试，再继续有效期、原子决定和原生界面。曾因隔离checkout缺node_modules而无法启动路由测试，补用已有依赖后通过；不把启动失败算测试通过。

## 实际修改

### 回传诊断与期限

`native-form-response.mjs` 记录结构、有限字段名/类型及缺失项；校验错误带 response.envelope / metadata / action / content / confirm / cancel_content 等阶段。`native-form-confirmation.mjs` 补外部 inputResponses 容器诊断。`app/mcp/route.ts` 的失败证据不保存字段值、响应原文、元数据内容、nonce或其哈希；请求身份与候选请求哈希分开，省略期限的回传也对应正确的原请求哈希。`research.mjs` 不再复制原始回传选择值。取消可带空对象或null，但不能混入肯定业务内容。未知业务字段、confirmed别名、字符串/数字冒充勾选仍拒绝。

`BC_APPROVAL_TTL_SECONDS` 为服务配置，默认86400，可选300–86400秒；非法配置显式失败，不悄悄回退。新请求省略 expiresAt 时只在首次接收生成期限，写入原请求体和哈希；同ID重试与续传从持久记录恢复原期限，配置变化也不能延长它。并发首次无期限投递也使用获胜原记录的同一期限/哈希，只产生一次挑战。显式期限继续遵守最多24小时。capabilities 返回 approvalPolicy；MCP新schema允许省略期限，旧宿主缓存仍可按policy显式传同一固定期限。设备授权可更早失效，服务期限不是执行保证。界面显示截止日期时间；平台卡片展示期限独立且unknown，不承诺一直保留。

### 同一个决定与回执

`native-commands.mjs` 的聊天批准、聊天拒绝/关闭和 BC 按钮共用 `decide`。现有 native_requests 条件UPDATE与唯一 native_approval_decision 回执在一个D1/SQLite批事务内提交；日志写入失败回滚决定，不返回“成功”。第一次有效决定生效，同决定重试取原结果，相反决定409带current最新状态。迟到cancel不能覆盖queued/dispatching/applied等结果。保留 owner/requestHash/commandId/nonce来源/设备/grant revision/有效期约束；设备执行前仍核对 expectedRevision。native决定额外带原requestHash、grantRevision、expectedRevision并限制在指定设备。本机仍必须具有已保存且同步的原有操作授权；离线撤权或授权提供者缺失立即停用同意，默认不放开。过期、撤权、关闭不重开；过了响铃时刻的排程不再批准。

没有数据库迁移，也没有第二个操作真相库。原生本地重试文件只保存已由人点击的决定身份和参数，不是代理可写的审批来源；0600、原子保存、iOS保护。没有MCP新批准工具，也没有给其他设备跨设备批准权限。服务信任已登记指定设备的原生客户端凭据；按钮回传本身不是独立硬件签名或真人点击的独立证明，审计按通道报告，不冒充这种证明。

### BC 原生界面

- 主窗工具栏“待确认”与设置“BC 内审批”共用 `NativeApprovalInbox`；20秒轮询与回前台刷新，指定设备列表有固定范围分页，读完才替换列表。显示有效状态，不把数据库raw awaiting当作仍可操作。
- 用户打开具体详情才核对目标、设备、修改前后、期限及状态；事项前值从固定服务快照及本机版本核对，日记前值仅在本机读取，不新增代理读取授权或上传原文。计时目标从已有共享状态核对会话/revision。缺前值、版本变化或读取失败明确提示并禁止同意，仍可明确拒绝。
- 改值不截断；长值在有界区域内滚动，专用审批页底部固定同意/拒绝。UUID/hash/revision和设备回执收在技术详情。显示queued“等待设备”、dispatching“尚无完成回执”、applied“设备报告已应用”、failed/unknown/expired/revoked/cancelled/declined分别呈现。
- 点击先持久化原决定再请求；HTTP成功但业务仍pending、回执身份不符不清掉本地原决定。响应丢失时查询同ID，不换ID、不自动重发；重启刷新会找回尚待核对的原决定，用户再明确重试。已读取的前值在本次显示期间保留；重启后的已关闭请求若未保存前值，保持未知，不以当前值补造历史。
- 通知默认关闭，单独“允许新审批通知”按钮才申请系统授权并启用。只提醒后续新请求、按commandId去重、静音普通通知；点通知仅路由到详情，没有批准动作。没有远程推送新服务，iOS长期后台/离线即时通知不保证。开发没有点这个按钮或申请实际新授权。

主要文件：`lib/native-commands.mjs`、`native-form-response.mjs`、`native-form-confirmation.mjs`、`confirmation-presentation.mjs`、`service.ts`、`bridge.mjs`、`research.mjs`、`dot-instructions.ts`、两API/MCP route；`NativeApprovalInbox.swift`、`NativeApprovalPanel.swift`、`NativeApprovalNotification.swift`及AppContainer/主窗/Settings/router/delegate/HTTP错误接线。既有授权面板文字更新为“Dots或指定设备BC逐条确认”；既有能力范围与授权内容没有自动改写。

## 验证层次

| 层次 | 本轮证据 | 不能据此宣称 |
|---|---|---|
| 服务代码 | 123/123测试，0失败/跳过；本地服务build通过 | 生产已更新 |
| 原生代码 | Xcode结果355/355 macOS单元测试，0失败/跳过；iOS Simulator build通过；最终包含本机授权默认关闭、离线撤权的355/355全量回归 | 实机按钮、通知已验证 |
| 实际宿主回传 | 之前v37的两次手机只读回传：89916/90046，确有_meta并成功；本轮没有新真实命令 | 新native通道端到端已验证 |
| 视觉检查 | 测试专用离屏NSHostingView，390/620pt固定测试数据，正文和固定底栏可见 | iPhone真机或电脑Dots宽度已修 |
| BC通知/双端审批 | 模拟通知授权/去重、API竞争、原决定重试已验证 | OS通知已送达、用户已看到、两端真人点击成功 |

自动化覆盖：合法_meta、额外/缺失/错类型确认、容器失败、默认期限冻结、关闭/过期/撤权、同意和拒绝竞争、相同选择重试、服务重建、审批审计磁盘失败、HTTP成功但仍pending、丢回传、本机日志失败、错设备/hash/grant/revision、完整分页/错游标、版本缺口、设备claim/receipt与重复回执。既有NativeRemoteExecution隔离内存写入/丢回执/重复执行防护仍通过。

一个隔离API样本：`12345678-1234-4234-8234-000000003800` 首次无显式expiresAt→保存24小时原请求→native/read显示设备→BC同意→queued及唯一审批回执→同决定重试仍queued→拒绝返回409/current=queued→模拟设备claim→dispatching→模拟receipt→applied→重复receipt仍一个结果回执。它由 `native-approval-api.test.mjs` 在内存SQLite、fake认证设备和禁止网络fetch中运行，**不是个人活动或真实设备应用**。

初次全test误含UITestsRunner，runner未连接而挂起；已只停止明确属于本轮DerivedData的runner/xcodebuild，之后完整跑BetterCalendarTests。没有把UI runner说成通过。ImageRenderer无法渲染AppKit滚动容器的早期黑图也已排除，最终改离屏NSHostingView并实际检查图像。日志在本机`/private/tmp/bc-approval-38-*.log`，完整Xcode结果位于`bc-approval-38-dd/Logs/Test/`；不追认过去缺失的日志。

## 当前试用、停止、上线与回滚

**目前尚不能在日用174看到这些新界面。** 审查代码或运行使用内存数据的上述单元测试即可；本轮不要求本人再造任务验收。

上线必须另行获得本轮明确批准后：先发布同一private StateBridge（可设TTL，不新增服务/授权范围，核对部署与源一致）；再按既有流程为双端升新build并发布TestFlight。用户更新后先只读查看同一待审批请求；通知仍由本人在各机单独启用。最后选一项真正需要的改动，由本人确认具体内容，核对聊天与BC同ID状态、设备实际回执及相反决定冲突。此步骤不能以模拟审批代替。

停止通知：点“关闭审批通知”或系统关闭；此前已展示通知仍只是打开详情。停止改动：不点同意或明确拒绝；点窗体关闭不批准也不假装拒绝。旧过期/取消命令不重建，复提必须有本人新的具体需求。

回滚代码只退本批，不删请求/审批/执行回执。不改CloudKit或SwiftData模型；本地重试文件留作核对，不自动重放。若将来上线后需服务回滚到v37，保留数据库和已接受请求：v37不认识无显式期限的原始续传参数，新卡可能无法继续，必须如实报告且不轮换凭据；已排队的设备执行和旧有效授权仍按原状态核验。撤销已发生改动需要独立新请求，不把迟到cancel当撤销。

## 产品审查与剩余限制

通过产品原则2/4/5/7：不记任务债务、不把未回复当认可；通知默认关闭且由用户新请求触发；同意/拒绝明确，代理不能自己批准；只读日志/展示不等于生活活动。主动通知不是原有早晚两条的一般建议推送，而是用户要求的新审批回声，单独 opt-in；记录这个用途差别，不静默扩张通知约定。

仍未验证：部署后的真实boolean写入回传、BC通知系统送达/点击、Mac/iPhone实机界面与共同真人审批、离线后台及时性、生产D1竞争时序。电脑Dots的2px宿主问题及旧cancel生产原因仍在v37报告中；本轮原生入口不改宿主。当前仅指定执行设备能在BC内批准，不新增其他设备的代理批准范围。唯一待决策是是否批准后续部署/双端发版；没有把已有“一键全部权限”当通知新用途授权。
