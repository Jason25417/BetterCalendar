# 对话计时独立确认（169增量）

2026-10-13。完整目标仍是个人实验原型，含事项、单次原生闹钟、日记与当前计时多端接入；Aqara取消。本批修正168审计发现的授权差异，不新建计时数据库、不修改SwiftData/CloudKit模型，不创建真实假任务。

## 差异与实际改动

旧MCP `task_command`直接调用共享计时核心，仅核验模型填的provenance=user，不能独立证明用户确认。本批使它成为`submit_native_command(kind=timer)`的兼容提案入口；两者走同一确认、固定设备、执行身份与回执队列，不再有MCP直接计时写入。旧参数不满足新合同会明确拒绝，不降级为模型批准。BC原生按钮保留原有明确操作路径。

本机Dots对话操作新增独立计时开关，默认不因事项/闹钟/日记权限开放。能力为timer.start/pause/resume/finish，沿用29天本机有界授权、版本核验、先禁用再更新和明确撤回。每次请求须用户在Dots具体卡片点击确认，固定commandId、设备、请求哈希、attemptId。非开始操作需读取sessionId和整数expectedRevision；结束计时不标记事项完成。

默认计时生效时刻是BC服务保存的用户按钮确认时间，接手设备不上线时等待，不能说已开始。只有用户明确补记过去时间时，可用effectiveAt，具体日期时间显示在卡片供本人确认；不能擅自推断过去起止。设备离线、空闲和传感器变化不会自动暂停。设备用native/timer交共享计时核心，session与BC按钮、其他设备完全共用，沒有第二套运行历史。

服务器在实际session写入事务中再次检查指定设备、原请求/尝试、确认、授权版本/范围/期限和撤销状态；两端版本冲突不覆盖。重复返回同一原始命令结果，不换身份。服务器保存后，设备先保存完整真实服务返回，再只读刷新共享计时缓存；完整快照已本机保存，且session/revision覆盖操作版本才报local_cache_persisted。版本相同时还须核对状态和lastCommandId；更高版本明确superseded=true，不称现在仍是旧状态。结束版本从快照的finishedVersions核对。

HTTP成功或saved=true仅是服务保存。缓存未保存、读取失败、版本缺失或返回丢失均不假装设备完成。已保存远程结果重报同一回执；服务成功但回复丢失时报unknown，不盲目重新发新ID，可读read_task_commands核对同commandId。屏幕/灵动岛呈现和人看到始终另列unknown，尚无真实设备证明。

## 研究记录与产品约定

完整提案、用户按钮确认时间、接手身份、服务结果、保存快照身份/版本、错误和重试继续在本机native-remote-v1.json及既有研究档案留存。native/timer服务调用引用共享commands原记录，提案/设备结果可按nativeCommandIds定位。确认秘密和设备凭据不进模型正文、Git或研究导出；没有新资料服务。格式/容量沿用167：原生16MiB/1000请求/10000失败，满或损坏保留原件并停止新接手；研究365天/2GiB配置继续。

哲学审查：符合CLAUDE五原则与行为文档§2/§5的掌控感、自主支持和代理不代权；不设持续手填日志、任务债务墙、回溯审计或服从评分。与“无感”有实际张力：具体卡片确认会增加一次点击及设备等待，这是Jason已选择的独立授权方式，真实注意力成本仍需样本，不编造低成本结论。不追加系统通知，不因为高置信度开放自动计时、闹钟策略或锁应用。

## 试用、查看、停止与回滚

待新版实际可安装后，在负责接手的设备主动开启计时对话权限并保存。在Dots明确说真正需要开始/暂停/继续/结束的事，检查具体卡片后本人点确认；需要核对进度时让它查询同一commandId。后台及时执行尚未保证，打开执行设备BC会继续检查；不为验收造假任务。共享状态由现有5秒活动轮询/15秒空态轮询更新，native队列约20秒轮询，真实双端延迟仍待样本。

查看原生操作原件与本地BetterCalendarResearch查看页/导出；read_native_command_status核对接手回执，read_task_commands核对共享保存结果与独立设备缓存回执，read_current_state/read_task_history核对目前与历史版本。服务保存、设备缓存保存、界面呈现和用户看到不能混为一项。

停止：关闭计时权限并保存，或撤回全部对话操作。本机停止新接手，服务端状态联网后核验；已经发送在途的事务、已保存的计时不会被撤权自动撤销，也不会自动暂停。要暂停/结束现有计时仍需明确操作。回滚先撤权并保留原生/共享缓存/研究原件，回退App或现有私有服务版本，不删新增记录、不重写旧历史；旧版无法处理timer队列时可见报错，优先前向修复。回退旧服务会恢复旧计时入口，故需要独立确认边界时应保留新服务并只回退App。

## 验证与交付状态

已核验：服务器55/55（隔离真实SQLite及MCP确认组件），Mac最终314/314（0失败/跳过），iOS Simulator BUILD SUCCEEDED，TS及服务构建通过。实际部署与TestFlight证据随后按真实结果追加。只有隔离fixture，没有真实用户任务、日记或闹钟。

未验证：用户主动开启本机权限、Dots真实卡片/按钮、一个真正请求的完整设备执行、手机响铃/取消、两端当前计时/Live Activity实测延迟。外部连接器原始调用及provider完整费用仍有覆盖缺口，用户不反馈仍unknown。完整目标保持active，不能把测试、上传或工具可见性当作真机闭环已验收。

## 实际部署与Dots只读样本（2026-10-13）

源码a57e1ae已push并核对origin/main。现有私有服务v24部署succeeded（11:56:42.221687 UTC），source c6754f4c61464721b8da82c72c19996997dab2cc，deployment appgdep_6ace1c6efda08191bfe4200ac0ab6740；没有扩大访问对象、没有新资料服务。

通过Edge扩展刷新现有插件后，Dots真实read_instructions与read_native_capabilities各1次，分别为research_94103f7e-b42c-4699-bf76-1341f666e192与research_22ecc000-beeb-43c2-91b2-11d158972a04。本地calls18965/18966及18968/18969保留开始/返回和原文定位；前者的返回hash与部署源码的完整instructions规范化hash相符，后者的devices[]页面返回重建hash与服务记录相符。不是原始HTTP抓包，也没有用一段总结补造原始调用。Dots已读到独立计时权限、指定设备、本人卡片确认、BC确认时刻及服务/设备分开报告规则。

12:06:30.015 UTC实际设备权限列表为空；没有提交计时或其他写入，没有代启本机权限。工具可见/规则读到证明接入可读，不证明真实卡片或设备执行。证据详见[evidence/timer-readiness-169.json](evidence/timer-readiness-169.json)。

双端0.65.12/169已archive+upload成功，归档bundle/version/build一致；Apple实际IOS fd5a5904-fa25-4d12-a559-1976a3ab26d6与MAC_OS cda7f50c-4d4b-4c5e-bad1-4565f8d7d718均VALID、IN_BETA_TESTING，中文说明已读回核对。可安装不代表已安装、主动授权或设备验收；完整目标仍active。[TestFlight证据](evidence/testflight-169.json)。
