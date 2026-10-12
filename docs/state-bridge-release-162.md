# 0.65.5 (162)：状态采集恢复与 Dots 可见性

2026-10-12，America/New_York。本批恢复采集与读取解释，不改变旧 SwiftData / CloudKit 模型，不迁移旧历史。

## 已实现

- Mac 启动、回前台、唤醒、网络恢复时补传队列，再获取新观察；使用原事件 ID 和发生时间。电脑历史游标仅在观察入队成功后推进。损坏队列保留原文件并显示错误。
- 设置页展示已有登录启动、普通退出保留菜单栏选项，默认不替用户开启；彻底退出仍停止本机采集。
- iPhone 健康来源分别读取，单项失败不阻断其余来源；空结果不等于已授权或没有活动。
- 私有云端版本 8 区分新鲜度与可读取性，返回来源覆盖及旧健康汇总矛盾提示。抽象判断接口默认把全部有效变化批次交给 Dots；保留分钟合并、去重和重试。

## 验证与发版

- 源码 f0c12ee 已 push 至 origin/main。
- macOS 全量测试 245/245；iOS Simulator build；SQLite 核心 8/8、TypeScript 与服务 build 通过。
- 云端版本 8 私有部署成功；MCP 实际读取新字段。
- 稳定 Xcode 27.0 (27A266a) 串行归档双端；归档版本已核对 0.65.5 / 162。Mac 10:00:23、iOS 10:02:57 EDT 上传成功，均 EXPORT SUCCEEDED。
- ASC iOS build `1dc6a4d4-3005-4c58-8e84-e36e0d67af56`；macOS build `9f727854-f11a-430a-a341-bff6ada9c63e`。双端 VALID、IN_BETA_TESTING；中文测试说明已写入并读回。外测 READY_FOR_BETA_SUBMISSION，不代表公开 App Store 上架。

## 实际链路与限制

Mac 161 重新运行后，09:57–09:59 EDT 七来源持续更新；文件扫描为 partial，独立浏览器来源 not-frontmost 为已读取空结果。不能把旧版恢复上传当作 162 的唤醒/断网恢复验收。

Dots 批次有真实处理回执：例如 13:59:04Z 创建，13:59:09Z 收到，14:05:23Z 确认处理。收到回调与处理完毕相隔数分钟，不能承诺一分钟内完成。此会话未代 Dots 确认批次，也未创建虚假的用户计时。

手机 162 后台行为、App/Focus 自动化、双端统一旧 UI 与云端计时、长期事项编辑、30 天回收站及迁移演练未完成。原报错 Dots 会话仍未定位；旧会话 ID 返回找不到会话，没有诊断消息送达。

浏览器验证遵循 Jason 最新要求使用 Edge 扩展。扩展可接管；私有状态网页在 Edge 要求登录，MCP 读取成功与网页登录状态不同，不以此认定服务不可用。

## 162 真机与历史恢复：10:35–10:41 EDT

Mac原生UI确认0.65.5/162安装，重新打开后队列0、上传持续更新；已开启登录启动，普通退出保留菜单栏原本开启。重登、重启、断网仍待验收。再次退出时未见主进程，也未见崩溃报告；不据此推断退出原因。

通过App现有完整档案入口导出432条真实数据库记录，并经App在隔离空库恢复校验成功：PlanBlock268、ExecutionSession70、LongTask25、LongTaskCheckpoint9、DayRecord11、DayPlanSnapshot8、ResidualSample5、JournalEntry19、JournalPhoto2、DeviceLog15。字段、关系、照片本体一致；未写入日用库。档案位于用户Downloads/BetterCalendar-Data，未上传或纳入Git；本批备份文件权限600。此验证不是未来任意schema变更兼容，也不是30天回收站完成。
