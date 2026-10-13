# 原生请求编号约定修复

2026-10-13，既有私有服务v25，原生客户端仍0.65.14/171。

真实触发是Dots提出5529计时补记时，使用了任务名和日期拼接的commandId，日志19801/19802与19823/19825均在接收前400拒绝，没有创建请求或开始计时。服务一直要求UUID，但MCP仅描述string，复合错误未说明具体原因。此次把服务实际UUID约束作为共享schema导出，供原生提案、只读日记、查询/确认与兼容计时提案声明；事项/日记recordId及alarmId同样明确UUID。sessionId和旧研究操作回执编号约定保持原样。

错误分别说明version、commandId、deviceId、userRequest，Dots说明增加首次生成UUID、后续沿用；只有明确格式拒绝且无接收记录才可更正。现有本人确认、单一执行设备、session/revision、补记时间在卡片显示等规则保持原样；不把模型报告授权当人确认。

相关18项服务测试通过，新增回归覆盖文字编号不落库、分项错误、合法UUID接受、明确过去时间保留、重复合法请求保持同一哈希及无确认时设备队列为空。服务构建通过。线上只读格式拒绝已经读回新错误；read_instructions核对新说明。真实Dots再次提出具体卡片与本人确认后的计时效果还未验，不能因发布成功称任务已开始。

部署证据见[evidence/mcp-uuid-service-25.json](evidence/mcp-uuid-service-25.json)。停止真实操作可撤回本机Dots能力；回滚此服务时应重新发布此前已保存v24（不要改数据库或重放请求），然后读取实际部署结果。已接收请求不能用新编号重试。

## 实际 Dots 续接：参数已通过，确认卡片仍失败

14:09 UTC，Dots用合法UUID提交本人真实5529提案，服务接受并保持原08:55:11美东补记起点。14:18刷新现有插件后，通过Edge向同一Dots消息流发送诊断；Dots读取原请求并于14:19原样重试，同commandId、requestHash和所有时间字段未改变，仍awaiting_confirmation。

Dots实际可见回复报告，接下来调用其user_message_send_message(channel=chatgpt, metadata.include_widget=true)时返回“The widget is unavailable.”；没有填写widget身份，发送工具按紧邻前一工具结果取得卡片。此错误是Dots报告、由页面文字见证，尚未独立捕获它内部发送工具原文。Edge页面iframe检查只见角色预览与隐藏宿主执行/安全框架，没有BC卡片。正式接口approvedAt/result均null，未开始计时。证据见[evidence/dots-native-card-25.json](evidence/dots-native-card-25.json)。

目前已核验的是提案参数与同编号重试，不是本人确认或设备执行。MCP已声明resourceUri/outputTemplate、注册HTML资源及隐藏_meta确认凭据；还需核验运行时资源发现、Dots取得widget的交接。官方[Plugin UI Reference](https://developers.openai.com/plugins/reference)要求structuredContent对应outputSchema，原生交互工具目前缺少该声明；应补齐合同并实际重验，不能仅据此宣称已找到卡片根因。若改组件，应更换资源URI以避开缓存；不把模型说同意替代本人确认，不另造提案、不自动延长当前14:39 UTC确认期限。
