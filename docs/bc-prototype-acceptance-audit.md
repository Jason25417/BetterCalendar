# 当前个人原型闭环验收对照

2026-10-13，按用户完整目标核对。本轮准备0.65.14/171，把170后已测试的队列修复交付到双端；不增加新功能或资料服务。上一目标轮属于实际进展：ea37ba0改变了真实源码并通过331项单元与iOS编译；本轮不因缺少反馈改变成功标准。

| 原始要求 | 当前可定位实现和隔离验证 | 实际闭环状态 |
| --- | --- | --- |
| 明确请求，经统一MCP进入指定设备 | native-commands.mjs的submit/approve/claim；旧task_command为同一提案入口。NativeRemoteExecutor接手并核验独立本机能力、具体卡片确认、目标设备、请求哈希和尝试身份；AppContainer实际注入并启动 | 已实现。真实Dots卡片按钮及设备接手尚未验证 |
| 事项新增、标题/备注/状态修改、待办删除/恢复；长期事项先放下 | SwiftDataNativeItemWriter和NativeItemCommandTests.actualStoreCreateUpdateTrashRestorePreserveIdentityAndChildren；事务失败/直接修改/原回执恢复测试；NativeRemoteExecutor接同一个本地写入口 | 隔离真实SwiftData已验证。用户本人真实事项及跨端结果尚未验证 |
| iPhone单次闹钟设置/取消，其他平台如实拒绝 | AlarmKitNativeAlarms.schedule/cancel核对AlarmManager现有排程/取消后的缺席，意图先保存；UnsupportedNativeAlarms无普通通知降级。原生与远程调用共用此协议 | iOS编译已验证；Apple系统授权、实际排程、响铃/取消未验证。不能以编译或设备回执保证叫醒 |
| 同commandId，一个执行设备，断线/重启不盲重写 | 服务claim固定attemptId/设备；原生保存准备、接手、结果和已回传阶段；NativeRemoteExecutionTests和服务器native-commands测试覆盖丢失claim/receipt、效果保存后回执失败与撤权 | 隔离验证。真实断线补传仍未验证，不用幂等键或HTTP成功代替 |
| 版本冲突、未知结果如实保留 | 事项/日记检查原文版本，共享计时检查session/revision；未决效果后原文改变不重放。服务接受、设备缓存保存、界面/用户看见分开 | 已实现和隔离验证；真实版本冲突/双端呈现仍待样本 |
| 当前事项/计时多端读取与操作，BC负责时间 | BridgeTaskViewModel共用服务session和授时；原生按钮、Dots确认队列、Live Activity为同一投影。BridgeTaskTests覆盖一份历史、时钟偏差、离线仍计时、过期不续期、缓存失败不报设备应用 | 代码链已接通。Mac/iPhone真实接收延迟及锁屏后台更新未验证；旧本机历史有保留边界，不假装完全迁移 |
| 日记模块 | 独立journal.read与journal.create/update，SwiftDataNativeJournal保留文字/照片引用/格式与原文版本；NativeJournalCommandTests覆盖分页、直接修改、重启、未保存内容与冲突 | 已实现；真实日记读取/卡片编辑未验证。不开放删除或照片二进制，不把代理推断写作本人陈述 |
| 完整参数、来源、错误、重试与回执本地受控可回顾 | native-remote/actions/task-commands原文档案；既有本地ResearchRecorder、170原生导出。171坏页诊断先遮蔽可识别凭据，记录规范化哈希；分页汇总/范围读完单独记录 | 现有自有调用/原生操作有可定位记录；本机导出面板及真实操作档案未实测。其他连接器完整调用、完整provider费用仍有覆盖缺口，分页汇总不是HTTP抓包 |
| 不扩大权限，不因设备状态自动暂停，自动强提醒shadow，取消Aqara | 指定设备能力默认关闭、29天；修改仍逐次卡片确认。原生闹钟为明确单次请求；队列修复不新增计时动作或通知。Aqara不在本轮修改 | 代码/范围核对通过；真实撤权和提醒听到仍需本人设备证据，不授权锁应用 |
| 分批测试、push、有意义的双端TestFlight | 170已可安装；本批队列修复331/331与iOS编译通过；171准备只改变版本与更新说明并串行archive/upload | 上传/Apple可安装状态必须另存实际证据；准备发版不等于交付 |

本表是按源码和测试覆盖作的审核，不是验收清单全勾选。主要来源：[原生167](bc-dots-native-167.md)、[日记168](bc-dots-journal-168.md)、[计时169](bc-dots-timer-169.md)、[锁屏/导出170](bc-lockscreen-state-170.md)、[队列验证](bc-native-queue-validation.md)。现有private服务v24的MCP合同不变，不需要为171再次部署或刷新工具。

正式只读read_native_capabilities于13:06:04.868 UTC仍返回devices[]，callId research_3b4f479b-b4e7-430b-94ed-844d9706e372，responseHash bb9f0bbe2f2278d5bb35502d5d9a46afb30646bd09399d8c2424f57282d90650，recorded=true。证明当时无服务端能力启用记录；不推断设备未安装、离线或用户没有活动。没有真实操作请求可用于执行验收，也不能为验收造任务或替本人启用权限。

后续真机验收沿用已记录的一次本机设置：负责接手的设备在设置→原生操作→Dots对话操作主动启用所需精确能力并保存；闹钟还需本人系统授权。随后使用真正需要的请求，在Dots核对具体卡片并本人点击确认，查同commandId实际回执和另一端呈现。完整目标保持active；已实现不等于实用模式已被认可，无反馈不是认可。除非发现新的实际缺口，不扩建平台来替代这部分证据。
