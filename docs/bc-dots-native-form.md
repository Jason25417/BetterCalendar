# Dots 对话中的原生确认

2026-10-13 15:24 UTC 更新：现有私有服务 v30 已部署成功，原生仍 0.65.14/171。取消或未勾选现在持久保存为 cancelled，明确拒绝为 declined；同请求重试只读回关闭状态，不重新生成确认。保留令牌哈希仅用于识别响应丢失后的同一答复，不能再用于批准。已经排队或应用后，晚到的取消返回冲突，不冒充撤销效果。设备权限和本人确认边界不变。

增加 6 项实际 POST 路由集成测试：真实内存 SQLite 业务层、MRTR 续传、跨实例重试、响应丢失、研究持久化失败、身份/原文篡改、取消/拒绝及兼容入口；共 72 项相关服务测试通过，无失败/跳过，构建通过。这是隔离验证，不是本人已用表单。Dots 已真实只读 read_instructions，callId 与本地原文日志一致；见 [mcp-cancel-30.json](evidence/mcp-cancel-30.json)。

Mac 的另一条只读日记请求已实际完成：指定时间窗返回 1 条保存记录，hasMore=false，服务结果与原生 reported 回执、已有本地研究原文快照一致，约 23.5 秒。该记录正文为空，所以只证明有记录的页可读取，不证明非空文字、跨页或改写成功。原始值仍只在现有受控本地记录器，Git 只含元数据与哈希；见 [native-journal-record-page-171.json](evidence/native-journal-record-page-171.json)。

以下 v28/v29 内容为历史实现说明；取消策略以本次 v30 为准。

2026-10-13，现有私有服务 v28/v29 已实际部署成功，原生客户端仍 0.65.14/171，不涉及 CloudKit 或新服务。完整目标继续 active；上一轮属于实际实现、发布与新证据的 progress。

v28 增加当前调用的安全能力分类。Dots 真实 read_connection_status 返回 form=declared_implicit、ui=not_declared（callId 与本地记录对应见证据），因此可以按标准尝试原生表单，不能声称组件故障根因已证明，也不能把声明当成真正显示。缺少元数据记 unknown。Codex 当前调用的能力另存本地，不能替代 Dots 能力。

v29 为统一 submit_native_command 和兼容 task_command 接通 MCP2026 MRTR：宿主声明 form 时返回 input_required，具体改动、设备、补记时间、版本和期限在对话表单显示，默认不勾选；仅宿主收集本人的 accept/confirm=true 并续传原请求后才调用现有批准入口。nonce 只放协议 requestState，不进入模型正文、请求数据或研究日志。它是高熵随机令牌，完整令牌及工具名的哈希保存在现有请求行；按 owner、原请求哈希、指定设备、原工具、有效期和 grant revision 核验，不依赖客户端序列化的自述。取消、拒绝或未勾选消耗待确认令牌，不排队；已排队/应用的同请求重试读回既有结果，不重复执行。模型工具参数没有 inputResponses、requestState、confirm 或 userConfirmed，不能以模型自述代批。没有 form 声明的宿主保留既有组件通道。

研究记录保留宿主确认结果类别与实际命令回执，不保存令牌；本地导入/导出的 requestState 一并脱敏。现有运行记录器仅下载不含该令牌的研究接口，本轮不重启。14:23 的 batches 500 在下一分钟以同一游标成功读回，已由本地原始快照证实，根因仍未知。

66 项相关服务测试、13 项记录器测试通过（无失败/跳过），v29 构建通过。覆盖参数/设备/工具/账户篡改、取消/未勾选、过期、撤权、刷新令牌及跨服务实例同请求重试、设备回执与既有版本冲突。测试使用内存隔离样本，不在真实事项池造任务；不能替代实际表单显示和真机执行。

## 试用、查看、停止与回滚

下一次本人真正需要修改事项、计时、日记文字或设置/取消 iPhone 闹钟时，在 Dots 说明具体请求。它先读权限及原记录，统一提案入口将请求交给宿主表单；本人核对后确认。不显示就如实报告未确认，勿换编号/绕过。原5529请求已经过期、未执行，不能自动续期或以它重建样本。

用 read_native_command_status 的原 commandId 查设备回执；本地研究 viewer 与 research.sqlite 仍在原 BetterCalendarResearch 目录。取消表单即可阻止未确认请求；原生设置撤回独立能力可阻止新的执行，不能把已执行结果假装撤销。没有测试期间系统自动暂停或应用屏蔽。

停止新增操作可撤回原生独立能力；服务回滚应保留 v30 的 cancelled/declined 状态合同、标签与关闭请求不重提的逻辑。旧 v29 及更早输出 schema 不认识新增状态，不能不加修补直接作为兼容回滚。没有数据库迁移；回滚不撤销已执行的真实操作，须读原命令结果并由本人明确要求恢复。确认 nonce 永远不能复制到文档或截图日志。本轮服务改动不需要新 TestFlight。

未核验：真正表单显示/本人选择/改动设备应用、双端 UI 同步、iPhone 单次闹钟实际响铃与取消、非空日记正文及真实文字修改、跨页读取。下一步以本人自然提出的真实请求核验，不要求编造任务或反馈。目前不需要新产品决策。

协议依据：[OpenAI 原生表单扩展](https://developers.openai.com/plugins/build/extensions)、[MCP MRTR](https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/mrtr)、[MCP clientCapabilities](https://modelcontextprotocol.io/specification/2026-07-28/schema)。正式证据见 [mcp-native-form-28-29.json](evidence/mcp-native-form-28-29.json)。
