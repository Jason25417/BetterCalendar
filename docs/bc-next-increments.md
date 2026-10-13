# BC：独立开发与真实体验并行

2026-10-12，Jason授权补研究证据，并开始强提醒、事项编辑和来源缺口的小批原型。完整施工清单在Agent SPEC §17；不再以缺少试用反馈阻挡独立开发。原个人实验目标和所有后续工作保留，不建设通用大平台。

本批实现：

1. **设备保存回执**：服务器在同一SQLite读取窗口提供完整在途状态和最多100个最近已结束版本；保存快照身份、命令/session/revision及哈希。设备将完整状态与待报身份一起落盘，之后才确认。重启/丢响应仍报同一身份；不能跨设备、在途截断或撤权后确认。未覆盖的更旧已结束记录明确finishedComplete=false，不追认历史应用。回执只证明经认证的设备报告本机缓存保存，不证明界面/Live Activity成功或人看到。
2. **本地补充证据**：Recorder.capture留存外部调用的真实资料、参数/返回、来源/发生/读取/分页信息，以及实际usage报告和用户明确反馈。身份防重、纠正追加、秘密字段排除；原文不复制到新服务。明确标记为导入资料，不能冒充BC亲自执行了外部工具。缺失原文不会自动补写。
3. **同输入对照**：compare输出三组固定输入hash和导入模型输出；输入不符拒绝，同模型与三组齐全独立检查，质量保持unrated。没有模型/连接器调用，绝无真实计时、通知或外部写入。全量模型成本仍unknown；已报告费用按币种单列，不用价格表猜测。
4. **后续操作原型**：reminderShadow验证有界授权、渠道、事实/时效、频率、持续时间、安静时段与撤回解除。itemDraft生成现有pool记录的原值/拟值/expectedRevision和可恢复删除稿。二者为纯函数，没有live权限、写库或响铃。原生AlarmKit adapter、建议展示/事项统一执行接口和具体来源修复继续逐批开发。

研究原始文件仍在`~/Library/Application Support/BetterCalendarResearch`，本机700/600，365天/2GiB；保留原数据库与游标，新增supplied_evidence表。完整导出格式升为2，旧本地档案不覆盖或删除；这不改变SwiftData/CloudKit模型。debug默认关。查看页、stats/export同时显示新增证据和明确缺口。

用法（以repo为当前目录）：

```sh
node StateBridge/tools/research-recorder.mjs compare minute_事件编号
node StateBridge/tools/research-recorder.mjs capture /绝对路径/真实资料.json
node StateBridge/tools/research-recorder.mjs view
node StateBridge/tools/research-recorder.mjs stats
```

capture文件必须有version=1、稳定id、已有runId、kind和带时区occurredAt；external_call另需tool/sourceClass/startedAt/returnedAt/result/arguments/response/pagination；model_usage需model/callRef/reportSource/usage（input/output/cachedInput为token数，cost与currency仅实际报告值）；user_feedback必须包含原话、reportSource=user_statement、usefulness及可选attentionSeconds。replay_result需group/inputHash/model/output，hash来自compare。supersedes指同一run同一kind的旧身份。导入记录不当成独立执行证明，用户未反馈仍unknown。

原型操作入口为`StateBridge/tools/action-prototypes.mjs`导出的reminderShadow和itemDraft；当前仅开发试算，无MCP live工具。单次明确强提醒、自动策略、普通通知、原生闹钟、番茄和锁应用各自独立，不因本轮开发授权自动开启真实策略。

验证与发布证据追加在下方。未验证：真实手机新版应用、屏幕/Live Activity呈现、外部调用自动拦截、provider完整费用、真实注意力/收益、三组真实同模型评价、原生闹钟及事项live执行。暂停研究只停Recorder，BC日用与计时不受影响；回滚保留本地档案和回执，新App队列不直接降级覆盖，优先前向修复。没有伪造真实用户任务或反馈。

已指出限制：当前goal工具只有读取、完成/blocked/paused，没有修改目标文字或恢复active的入口；电脑工具也不允许操作Codex自身。用户本轮恢复开发的指示按§17执行，不通过篡改App状态库绕过此限制。App目标卡可能仍显示旧blocked，不能据此说本轮没有推进。


已核验开发检查：2026-10-12 22:52 EDT，Node 50/50、App macOS单测280/280（0失败/跳过）、iOS Simulator BUILD SUCCEEDED、服务TypeScript检查和构建通过。默认全test入口的空UITests bundle加载失败，未将其记为通过；单测门控以only-testing:BetterCalendarTests的独立xcresult为准。此批不修改@Model/CloudKit schema，也不申请新的Apple系统权限。

发布与真实样本（2026-10-12 23:05 EDT）：

- 源码4da7619已push；0.65.8/165双端archive/upload完成，ASC双端VALID、IN_BETA_TESTING、中文说明读回一致，见[evidence/testflight-165.json](evidence/testflight-165.json)。
- 现有owner-private服务v20已成功部署，来源9904ac9e4d2935f8bc7517b48c5007756105ef73，deployment appgdep_6acd9d7ac1bc8191a63e3c6c70a5a397，成功时点2026-10-13T02:55:41.549815Z；没有新服务或扩大访问对象。
- Mac从本次签名archive安装165，旧164备份位于/private/tmp/bc-release-165/previous-164.app。这不是Mac从TestFlight安装的证明。真实服务日志#11842在03:05:08.515Z发出快照，同一身份#11846于03:05:09.208Z收到认证Mac的local_cache_persisted回执；本机待报队列为空。完整元数据见[evidence/device-cache-165.json](evidence/device-cache-165.json)。当前空计时状态，没有为了验证而建立假任务；真实用户计时、iPhone应用、界面/Live Activity和人看到仍未验。
- Recorder由登录LaunchAgent运行，标签com.jason.BetterCalendar.research-recorder；原手动进程已退出，没有并行录制。实际PID7075运行，原游标保留并从11808推进到11834，接收真实新调用；注册或RunAtLoad本身不当成重启后验收。退出登录/整机重启及崩溃自动恢复未验，KeepAlive=false。

登录采集、查看和停止：

```sh
python3 StateBridge/tools/research-launch-agent.py status
node StateBridge/tools/research-recorder.mjs view
node StateBridge/tools/research-recorder.mjs stop
python3 StateBridge/tools/research-launch-agent.py disable
```

stop保存STOP并在下一轮检查后退出，disable撤销登录启动并停止该LaunchAgent，保留配置备份、数据库、原文与游标；BC计时不受影响。安装脚本不会移除STOP，因此显式停止后不会在下次登录悄悄恢复。再次启用需明确移走STOP后install，代码与数据路径无需新凭据。既有本地查看页review.html可直接打开，无外部网络或写入按钮。降级App前保留新增待报快照，不用旧缓存覆盖新缓存；优先前向修复。

当前来源缺口有具体证据：iPhone App/Focus尚未收到，家居home.status报告notification-unavailable；手机最后心跳02:14:32Z，不能称实时。健康和日历有各自时效，不与过期心跳混为一谈。Mac文件partial和浏览器empty分别保留。HomeKit读回调忽略错误、可能把旧缓存值标为新的观测时间，已定位，但Jason在下一轮明确取消该Aqara来源修复；不继续施工，也不称已修。165未包含此修复。原生闹钟适配、事项统一live入口、连接器调用自动留存与实际provider费用仍待开发，真实对照输出与有用性评价待实证，现阶段无需用户拍板。

2026-10-12 后续范围已更新：Aqara/HomeKit修复取消；原生一次闹钟与统一原生事项写入已实现，详见[bc-native-actions-166.md](bc-native-actions-166.md)。Dots远程执行与自动策略尚未接通，不把原生入口误称完整MCP闭环。

2026-10-13 对话执行增量：用户选择Dots内具体按钮确认。后端固定设备队列、独立批准凭据、本机授权与执行日志已实现；详见[bc-dots-native-167.md](bc-dots-native-167.md)。日记单独定范围，未擅自开放；完整目标仍active。

2026-10-13 05:14 UTC线上复测：既有插件刷新后，Dots实际调用read_native_capabilities一次，devices[]；页面报告payload哈希与本地研究行17821/17822匹配。未登记设备能力不等于离线，卡片和真实操作仍待验。日记本地独立读写入口/原文意图/分页版本已补，Mac305/305、iOS编译通过；不自动上传日记、不开放代理权限、未发布此日记增量，见[bc-journal-increment.md](bc-journal-increment.md)。

2026-10-13 168日记对话增量：独立journal.read/create/update、本机权限开关、指定设备读取页结果与用户按钮确认后的文字修改已经接入既有队列。读失败不冒充空页，原读回执冻结重传，并发同读取保留最先请求。服务器49/49、Recorder12/12、Mac308/308、iOS编译/TS通过。发布准备与真实执行分开核验，见[bc-dots-journal-168.md](bc-dots-journal-168.md)。完整目标仍含真机事项/闹钟与计时多端时延，未complete。
