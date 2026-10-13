# Dots 对话中的原生确认

2026-10-13，现有私有服务 v28/v29 已实际部署成功，原生客户端仍 0.65.14/171，不涉及 CloudKit 或新服务。完整目标继续 active；上一轮属于实际实现、发布与新证据的 progress。

v28 增加当前调用的安全能力分类。Dots 真实 read_connection_status 返回 form=declared_implicit、ui=not_declared（callId 与本地记录对应见证据），因此可以按标准尝试原生表单，不能声称组件故障根因已证明，也不能把声明当成真正显示。缺少元数据记 unknown。Codex 当前调用的能力另存本地，不能替代 Dots 能力。

v29 为统一 submit_native_command 和兼容 task_command 接通 MCP2026 MRTR：宿主声明 form 时返回 input_required，具体改动、设备、补记时间、版本和期限在对话表单显示，默认不勾选；仅宿主收集本人的 accept/confirm=true 并续传原请求后才调用现有批准入口。nonce 只放协议 requestState，不进入模型正文、请求数据或研究日志。它是高熵随机令牌，完整令牌及工具名的哈希保存在现有请求行；按 owner、原请求哈希、指定设备、原工具、有效期和 grant revision 核验，不依赖客户端序列化的自述。取消、拒绝或未勾选消耗待确认令牌，不排队；已排队/应用的同请求重试读回既有结果，不重复执行。模型工具参数没有 inputResponses、requestState、confirm 或 userConfirmed，不能以模型自述代批。没有 form 声明的宿主保留既有组件通道。

研究记录保留宿主确认结果类别与实际命令回执，不保存令牌；本地导入/导出的 requestState 一并脱敏。现有运行记录器仅下载不含该令牌的研究接口，本轮不重启。14:23 的 batches 500 在下一分钟以同一游标成功读回，已由本地原始快照证实，根因仍未知。

66 项相关服务测试、13 项记录器测试通过（无失败/跳过），v29 构建通过。覆盖参数/设备/工具/账户篡改、取消/未勾选、过期、撤权、刷新令牌及跨服务实例同请求重试、设备回执与既有版本冲突。测试使用内存隔离样本，不在真实事项池造任务；不能替代实际表单显示和真机执行。

## 试用、查看、停止与回滚

下一次本人真正需要修改事项、计时、日记文字或设置/取消 iPhone 闹钟时，在 Dots 说明具体请求。它先读权限及原记录，统一提案入口将请求交给宿主表单；本人核对后确认。不显示就如实报告未确认，勿换编号/绕过。原5529请求已经过期、未执行，不能自动续期或以它重建样本。

用 read_native_command_status 的原 commandId 查设备回执；本地研究 viewer 与 research.sqlite 仍在原 BetterCalendarResearch 目录。取消表单即可阻止未确认请求；原生设置撤回独立能力可阻止新的执行，不能把已执行结果假装撤销。没有测试期间系统自动暂停或应用屏蔽。

服务回滚可重部署已保存 v28（只诊断、原组件通道）或 v27，不迁移 DB，也不修改已保存命令。回滚不撤销已执行的真实操作，须读原命令结果；确认 nonce 永远不能复制到文档或截图日志。本轮没有新 TestFlight。

未核验：真正表单显示/本人选择/设备应用、双端 UI 同步、iPhone 单次闹钟实际响铃与取消、非空日记页及真实文字修改。下一步以本人自然提出的真实请求核验，不要求编造任务或反馈。目前不需要新产品决策。

协议依据：[OpenAI 原生表单扩展](https://developers.openai.com/plugins/build/extensions)、[MCP MRTR](https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/mrtr)、[MCP clientCapabilities](https://modelcontextprotocol.io/specification/2026-07-28/schema)。正式证据见 [mcp-native-form-28-29.json](evidence/mcp-native-form-28-29.json)。
