# 0.65.7 / 164 双端内测发布

2026-10-12。候选内容：保留原行的回收站与恢复、兼容旧格式的完整档案、原生长期事项/阶段只读目录上传、后台浏览器读取及敏感网址参数排除。研究第一阶段已经以私有 v19 和本地录制工具独立运行；不是本版新增的手机通知能力。

## 发布前置与验证

- Edge Console 实读 BC Production：五类记录各四个删除字段，全部所需20个字段与 Development 类型/索引一致；本轮没有部署 schema 或修改安全角色。证据：[字段清单](evidence/cloudkit-production-retained-deletion.json)、[截图](evidence/cloudkit-production-retained-deletion.png)。
- 工程 objectVersion=77；版本与 build 在八处同步。当前正式 Xcode.app 27.0/27A266a 与 xcode-select 的27 beta分开；使用正式 Xcode 编译和签名。
- macOS 278/278、零失败/跳过：/private/tmp/bc-release-164-tests.xcresult。已有393条旧业务内容/关系/照片隔离升级通过的证据仍见 bc-dots-retained-deletion.md，本轮未重复改动日用库。
- iOS Simulator 编译通过：/private/tmp/bc-release-164-ios-build.log。
- 双端 archive/upload 成功，包内0.65.7/164、bundle com.jason.BetterCalendar、最低系统26.0；mac与ios上传日志均为Upload succeeded / EXPORT SUCCEEDED。
- 2026-10-12T23:58:20.676890+00:00 ASC真实回读：macOS 495ab505-954f-414f-807e-e1cbd217e674、iOS 17aa33df-21d2-46c3-a93f-9f04f2a57c71，均VALID + IN_BETA_TESTING，中文测试说明逐字一致。
- 本轮门控与版本源码8aa6dd6已push；上传/分发原始运行材料位于/private/tmp/bc-release-164，记录不含密钥。安装到用户设备、真实同步和可恢复删除效果仍未核验。

## 如何试用及回滚边界

两端都安装164后，设置→数据与同步→回收站可查看和恢复；用一条非重要记录验证删除后另一端消失、恢复后另一端出现、照片和阶段关系完整。旧版本可能物理删除，不用旧版本参与删除验收。计时仍只响应明确开始/暂停/继续/结束；本版不自动暂停或编辑事项。原始历史不清空，公开报告不包含私人原文。

回收站没有永久清除或自动30天清理。升级前可使用完整档案导出；对新库的恢复先隔离校验，不能直接降级回163读新格式2。问题时停止涉及写入的测试、保留档案和错误日志，再修复或发布前向版本；schema不可通过卸载撤销。研究录制可单独stop，具体查看/导出/停止步骤见bc-research-stage-one.md，独立于App和临时pool。

尚未验证：真实双端删除/恢复传播、离线并发、用户手机安装、Live Activity后台接收以及生活收益。目录schema兼容、单元测试或服务器接受均不替代设备实际应用证据。强提醒/完整事项编辑继续仅保留增量spec，不为本次原型试用追加泛用平台。

## Mac实际安装与恢复采集

23:59 UTC /Applications/BetterCalendar.app包内0.65.7/164，实际App进程95324启动。正式MCP收到23:59:12观察、23:59:17.541接收的device.status心跳，collector明确version=0.65.7、build=164，freshness=current。日用default.store的五类表已全部加载ZDELETIONID字段，核心记录数量仍为计划268、执行70、日记19、照片2、长期事项25、阶段9；这是字段与数量核验，不冒充本轮逐条内容比对或真实双端同步。临时pool PID65901与研究录制PID83250仍存活，未主动停用。手机心跳仍为21:48旧数据，手机164安装/后台覆盖未核验。启动时电脑UI读取超时，但随后实际进程、库和MCP证明App已正常启动；不把UI超时隐藏成首次打开界面验收。
