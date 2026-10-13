# 确认卡片修复 v32：已发布，真人使用仍待验收

2026-10-13 21:56:50 UTC（美东17:56），原私有 StateBridge v32 发布成功。无新原生包、CloudKit 模型、权限或服务；BC 173 继续使用。代码已推送，部署来源与证据见 [evidence/confirmation-32.json](evidence/confirmation-32.json)。

## 修复了什么

发现并用隔离 SQLite 复现：submit 先读取 awaiting_confirmation，再保存确认凭据，最后返回旧快照。如果期间过期、授权版本改变或另一响应关闭请求，旧实现仍可能返回等待确认的卡片。新回归在旧代码上实际失败：expected expired，actual awaiting_confirmation。

现在凭据写入同时核对期限、授权版本与设备撤权；随后重读实际状态，不能把旧快照当作当前状态。MCP 返回表单前另做一次内部 finalization：核对原 commandId/requestHash/凭据，准备记录保存后再次读取，过期、撤权、关闭时返回实际结果；凭据已被另一提案轮换时明确报冲突，不发布旧卡片。服务完成记录可能仍耗时、网络与宿主展示也可能延迟；不能保证用户看到时尚未过期，执行端仍独立核验。

新增安全研究事件：native_confirmation_prepared、suppressed，以及 response_received、processed、rejected。分别保留原请求、原授权版本、session/expectedRevision、公开表单内容哈希/字数、响应动作、实际状态和接收/处理时间。mcp/confirmation_finalize 是 BC 内部阶段，不是新增外部连接器调用。prepared 只证明 BC 准备过表单，不冒充网络送达或宿主展示；hostDisplayed、关闭原因与是否人为手势仍 unknown。凭据/nonce/其哈希不入研究日志，用户正文仍在现有请求原文定位中，不新复制到云端日志。

原重复提案的凭据轮换合同保持：同 commandId 不能改变请求/设备/session/revision；旧凭据不能取消新确认。同请求取消/拒绝后不重新准备，也不恢复三条旧 Megahit 或旧5529请求。分钟回调和状态读取不触发表单取消、批准或凭据轮换。不能仅凭原生表单名重复就猜测改协议，也不绕过本人确认。

长度方面沿用 v31 的短标题和标准 boolean description，完整改动不截断。本轮没有把宿主 CSS 当作 BC CSS 改，也没有宣称窄列/空白已修好。按 [MCP elicitation 规范](https://modelcontextprotocol.io/specification/2026-07-28/client/elicitation)，布局由宿主决定，cancel 也可能源于加载失败，不能等同于本人取消。

## 已验证

- 服务90/90测试通过、0失败/跳过，发布构建成功。5个新测试覆盖凭据生成窗口的过期/撤权/关闭，以及实际POST在研究记录时过期/撤权/关闭/轮换、审计写入失败、重复准备与旧cancel、计时commandId/session/revision/工具篡改。只用隔离SQLite、虚拟网络和模拟响应，没有真实计时或用户任务。
- v31发布后的本地完整研究区间39226–46226：73个不同deliveryId，各一次started、一次received/HTTP200，无重复started。341个完整flush里9对同一非空批次的重叠调用均为一次delivered=1、另一次0；这次有实际发送并发样本。正式MCP尾页到46226 hasMore=false，逐项核对尾部实际发送。不是接收端恰好一次、模型理解或用户看见的保证。
- 同一区间没有新的submit_native_command/task_command；v32后本地读到46811也没有新提案/表单事件。因此没有新版真人卡片证据，不追认历史缺失日志。
- v32正式只读MCP状态成功：25来源、1订阅，不代表所有来源新鲜。第三条旧Megahit仍cancelled且批准/执行/结果为空。15分钟Worker错误查询返回0条，只限定该查询窗口，不代表所有路径无故障。

## 宿主最小问题报告

**现象：** 原生MCP确认表单窄长、正常消息下出现大段空白，加载后显示“不再处于待处理状态”。已有三张本机截图，短原话仍窄；“继续”按钮识别为宿主原生 form，非BC HTML。截图宽约337像素不是计算CSS宽度。v31/v32新表单还没有真人显示样本。

**服务证据：** 旧三条提案各只见一次首次提交和一次宿主action=cancel；没有重复submit或nonce轮换证据。第一条cancel迟于过期，v31修正这类状态覆盖；另外两条在到期前收到cancel，第三条约39秒。不能由邻近分钟事件推出关闭因果，也不能把BC只声明的state.minute_changed当作approval-card-published生产者。

**确切缺失：** 同一commandId/requestHash及prepared事件对应的宿主收到、渲染、关闭时间；实际requestedSchema/description是否完整显示；卡片DOM与计算宽高、DPR/缩放；加载错误栈；cancel是用户手势还是宿主加载/关闭；若有approval-card-published，需其生产方、事件身份与重试记录。任何共享诊断应删除requestState/nonce及其他秘密。v32新增安全日志可关联BC阶段，但拿不到宿主事件就不能认定它的根因。

**访问边界：** 本轮未访问受限ChatGPT应用，也未用脚本、私有会话目录或内置浏览器绕过。现有许可不等于该工具限制已解除；不再通过重复空轮询替代现场证据。此报告仅保存于既有项目文档，没有发给新服务或第三方。

## 用户只需一步验收

下一次确实要修改事项时，在Dots提出一个具体改动并确认它的新卡片，然后告诉我“成功了”或“仍是同样错误”。不用开新权限、不用重提已关闭旧请求，也不需要造一个计时。若加载即关闭，保持原请求编号；我用新日志核对BC是否准备/抑制、收到哪个关闭动作、是否有设备回执。成功标准是卡片可读、本人确认、同一请求产生实际设备结果；服务接受或测试通过不代替这个标准。

## 停止与回滚

关闭表单/不勾选不执行，可在本机撤回对应对话权限。回滚本批可从033acce重建发布同一私有服务，保留v31过期/中性取消/回调占用修复；保留已有请求、授权、关闭与投递记录，不重开旧请求或回放已收到事件。本轮未执行回滚。完整事项/闹钟/计时/日记真实闭环目标仍未完成，不改变目标范围。
