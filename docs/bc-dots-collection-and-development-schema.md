# 状态采集修复与 Development schema 准备

2026-10-12。此批 App 代码尚未发布；日用版本仍为0.65.6/163。服务端修复已经私有上线。

## 实际访问与来源边界

本地源码读写、Edge扩展、正式个人状态MCP均能实际访问。Computer History状态为running，当前段事件文件可读，最新事件17:04:49 UTC；没有将running当作每分钟都生成新记录。这与BC是否已经把同样的内容上传给Dots是两个问题。17:14 UTC状态查询显示Mac持续分钟上传；iPhone最近17:09上传日历、提醒、健康、位置等来源，但设备心跳已超过自身3分钟有效期。iPhone App/Focus来源仍not_received，文件来源为partial；不能把开发访问放开写成所有设备来源都完整可用。

CloudKit Console仍停在Apple登录页，缺少登录状态。尚未读取实际schema diff，更未部署Production。

## 浏览器状态

新增StateBridgeBrowserReading接口与AppleScriptBridgeBrowserReader actor。可信bundleID白名单包含Safari、Chrome、Edge、Arc；读取有2秒Apple Event超时，执行与描述符留在actor内，不把同步浏览器等待放在UI线程。

区分未授权、浏览器没有运行、读取超时、对象不可读，以及无前台网页。没有窗口或内部页面明确返回可读空集；读取失败不能冒充“没有网页”。URL在进入上传队列前去除用户名、密码、query、fragment；内部页面不附标题或地址，普通网页标题上限300字符。错误发生变化时写DevLog，持续同一错误不每分钟重复刷日志。

设备心跳补充采集器名称、App版本、build和payload版本，用于之后核验到底是哪一版在上传。本批未运行新版日用App，线上尚不能据此证明新浏览器读取已通过真实Automation权限。

NSAppleScript线程约束采用Apple DTS对历史限制已取消的[澄清](https://developer.apple.com/forums/thread/759287)，对象不跨actor共享。最低部署macOS26，验证环境27.2。旧的Thread Safety Summary不作为当前限制的唯一依据。

## 独立Development播种入口

编译条件BC_SCHEMA_SEEDER + DEBUG + macOS选择独立@main；正常入口不构造。运行前核验实际有效签名的CloudKit环境必须为Development，容器必须包含iCloud.com.jason.BetterCalendar；测试宿主禁止云写入。Release或正常Debug不选择该入口。

只在独立Application Support/BetterCalendarSchemaSeeder/retained-deletion-v1/schema.store中保存无个人内容的合成记录。不创建AppContainer、SharedModelContainer、计时或采集器，不打开日用default.store。签名环境通过临时构建entitlements指定，不修改正式entitlements。

五类既有模型各写一个四个删除字段均非空的合成记录，让Development可生成字段。导出回执只接受保存准备时间之后开始的成功export；失败显示在独立窗口及本地receipt.json。回执目录700、文件600，无个人业务内容。

已核验的证据：

- 签名验证成功，环境Development，指定容器正确。
- 独立库五类表各有一条删除元数据全部非空的合成记录。
- 已运行的准备程序收到成功export；本地回执最后exportEndedAt为2026-10-12T17:04:50Z。
- 17:17 UTC只读检查日用default.store，五类表仍没有ZDELETIONID列；正常163进程仍运行。
- 回执早期实现把createdTypes在export时覆盖为空；代码已修复，原回执保留。合成记录存在另由独立库查询确认，不用这个空数组否认或证明云端字段。

以上是Development保存和导出证据，不能替代Console的字段差异预览。预期五个既有Record Type各增加四个可空字段，共20个；实际字段、索引、角色以Console为准。Production未改，双端TestFlight新模型更新仍等待该前置核验。

## 服务端上线

旧格式health.resting-heart-rate对象中bpm为空时，派生状态改为unknown且不可作为当前读数；保留明确error优先级。真实零值或非空样本不因此失效，不据此猜测HealthKit权限、活动或身体状况。

Sites原私有项目保存并部署版本13：

- source SHA：7d20d12523290a700a05b4cd677a7ea823a59e94。
- version：appgprj_6ac3bb816d3c8191949bac68d45a62bc~appgver_d86a0e700cd08191b1ab737a5a8d85ba。
- deployment：appgdep_6acd15dea81c81919ba0099f2da2cb80；succeeded，has_mcp=true。
- 地址：https://jason-state-bridge.jason25417.chatgpt.site；保留owner-private，未修改分享。

17:17 UTC正式MCP可读，当前手机心率来源实际是非空样本数组，仍正确显示available/current；本次没有线上空对象样本可用于实调该分支，空对象/显式失败/可用样本由回归测试覆盖。不制造假健康记录。

## 验证与未完成项

macOS应用单元测试275/275，无跳过或失败，/tmp/bc-browser-tests-final.xcresult。iOS编译成功，/tmp/bc-browser-ios-current.log。独立Development入口签名编译成功，/tmp/bc-schema-build-current.log。服务器SQLite测试21/21、TypeScript与生产构建通过，两份服务器逻辑和测试一致。

没有将此批发布为TestFlight。还需Console实际diff/Production部署、双端新版本和真实删除恢复验收；浏览器新实现真实权限/超时验收、手机App/Focus持续采集、统一历史与长期事项MCP也仍未完成。整体目标保持active。


## 2026-10-12 22:06 UTC 发布前置复核

上一轮研究汇总3705840为实际开发进展；本轮转回长期目标的数据保护发布门槛，保留个人原型优先级，不把全源覆盖或完整事项编辑扩大成新门槛。

当前工作区干净。直接重读本机隔离schema.store：ZPLANBLOCK/ZLONGTASK/ZLONGTASKCHECKPOINT/ZJOURNALENTRY/ZJOURNALPHOTO分别存在四个删除字段，并各有1条全部非空的合成记录。所在目录为App sandbox内Application Support/BetterCalendarSchemaSeeder/retained-deletion-v1，不是宿主全局Application Support。原receipt.json仍为17:04:50 UTC的Development exported回执，expectedTypes=5、expectedAddedFields=20、productionChanged=false；createdTypes空数组的问题已在上文说明，未篡改或重播种该旧回执。

只读检查日用default.store的上述五张表均仍无ZDELETIONID；没有加载新ModelContainer或修改日用库。读取现存bc-browser-tests-final.xcresult的Xcode机器摘要：275 passed、0 failed、0 skipped；这是已有测试产物的本轮核对，**不是重新跑了App门控**。原回收站实现仍未发版。

通过Edge扩展打开CloudKit Console，实际跳转到Apple登录表单。尚不能读取Development→Production真实差异。已请Jason仅完成登录；登录不代表批准Production部署。待实际预览后核对这20个字段及额外索引/角色差异，给出具体可审阅变更，再按独立授权边界处理生产更新。普通仓库push/TestFlight常驻授权不自动覆盖CloudKit Production结构变更。

等待期间不发布含新模型的App，也不停止当前163采集、临时pool、共享计时或本地研究录制。现有原型试用不依赖此登录。完整长期目标尚未完成；本轮是发布前置证据复核，不宣称真实双端删除/恢复验收成功。
