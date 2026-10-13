# 当前个人原型闭环验收对照

2026-10-13 14:41 UTC 续接：v26补齐原生输出schema并以实际回执验证（19项通过）；实际宿主读取已知HTML资源HTTP200，但Dots复测仍报widget unavailable。v27进一步补上所声明MCP版本要求的complete结果标记，已发布并正式读回原请求expired、approvedAt/attemptId/result=null；计时没有执行。此轮确有协议实现和部署进展，卡片根因尚未证实；详见[确认组件协议核验](bc-dots-mcp-ui-contract.md)。

2026-10-13 14:24 UTC 续接：已通过Edge直接向同一Dots消息流传达修复并核对重试。真实5529提案合法UUID已接受，刷新现有插件后原样重试保持同编号/哈希/08:55:11美东起点；Dots发送卡片工具报告“The widget is unavailable.”，页面未加载BC卡片。正式状态仍awaiting_confirmation，approvedAt/result=null。故障已推进到卡片注册/宿主发送交接，不能称计时已开始，暂时无需本人重复查找会话。详见[evidence/dots-native-card-25.json](evidence/dots-native-card-25.json)与[原生编号修复后续](bc-dots-mcp-uuid-fix.md)。

2026-10-13 14:03 UTC 更新：本人保存权限后，Mac grant revision 1 已出现在正式接口，事项/计时/日记能力有效至11月11日；最新device.status实际报告0.65.14/171。只读日记请求已经由Mac真正接手并回传，commandId、requestHash、attemptId与本机reported记录、本地ResearchRecorder完整原文逐项一致。本次仅查美东今天的保存日记，实际为空、hasMore=false；不证明其他日期/另一端没有日记，也未验证非空正文、分页、编辑或照片。详见[evidence/native-journal-read-171.json](evidence/native-journal-read-171.json)。下表较早的“设备接手/日记读取未验”在这一只读范围内已补上证据，改动确认与执行仍未验。

本人随后转来Dots真实“5529轻计时、补记一小时”失败：日志19801/19802、19823/19825显示commandId使用文字/日期拼接，服务在接收前拒绝。MCP原schema仅string、说明遗漏UUID，复合错误也未指出具体字段。本轮共享同一UUID校验与schema，明确说明和分项报错；不放宽权限、不自动开始计时。18项服务测试和构建通过，既有私有服务v25已成功部署；原生171与CloudKit结构不变。只有明确未接收的格式拒绝允许更正编号；已接收/unknown仍沿用原编号。真实Dots确认卡片与5529执行尚待继续，不能用只读成功代替。

2026-10-13，按用户完整目标核对。本轮已发布0.65.14/171，把170后已测试的队列修复交付到双端；不增加新功能或资料服务。上一目标轮属于实际进展：ea37ba0改变了真实源码并通过331项单元与iOS编译；本轮不因缺少反馈改变成功标准。实际发布证据见[evidence/testflight-171.json](evidence/testflight-171.json)。

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
| 分批测试、push、有意义的双端TestFlight | 本批队列修复331/331与iOS编译通过；171只改变版本与更新说明并串行archive/upload，双端ASC已VALID/IN_BETA_TESTING且中文说明读回一致 | 源码、双端archive版本/widget版本、ASC实际版本和可安装状态均已核验；设备安装和实际操作仍未验 |

本表是按源码和测试覆盖作的审核，不是验收清单全勾选。主要来源：[原生167](bc-dots-native-167.md)、[日记168](bc-dots-journal-168.md)、[计时169](bc-dots-timer-169.md)、[锁屏/导出170](bc-lockscreen-state-170.md)、[队列验证](bc-native-queue-validation.md)。现有private服务v24的MCP合同不变，不需要为171再次部署或刷新工具。

正式只读read_native_capabilities于13:06:04.868 UTC仍返回devices[]，callId research_3b4f479b-b4e7-430b-94ed-844d9706e372，responseHash bb9f0bbe2f2278d5bb35502d5d9a46afb30646bd09399d8c2424f57282d90650，recorded=true。证明当时无服务端能力启用记录；不推断设备未安装、离线或用户没有活动。没有真实操作请求可用于执行验收，也不能为验收造任务或替本人启用权限。

后续真机验收沿用已记录的一次本机设置：负责接手的设备在设置→原生操作→Dots对话操作主动启用所需精确能力并保存；闹钟还需本人系统授权。随后使用真正需要的请求，在Dots核对具体卡片并本人点击确认，查同commandId实际回执和另一端呈现。完整目标保持active；已实现不等于实用模式已被认可，无反馈不是认可。除非发现新的实际缺口，不扩建平台来替代这部分证据。

只读研究证据另外核验本地实际calls19252/19253的开始/返回（13:06:04.708→04.868 UTC）；后来于13:14:43.935补存原工具structuredContent至既有ResearchRecorder snapshots表，快照f5d44934561a0bf3c2ca68ad0cc5fbb5b490f3a847879f9c85219d64658e87a1，规范化内容哈希与真实返回记录一致。补存时间、原读取时间、来源与原始日志位置分开记录，不追认当时已经有全文录像，未复制到新服务。它仍是只读工具调用而非用户操作执行，详见[evidence/native-readonly-trace-171.json](evidence/native-readonly-trace-171.json)。
