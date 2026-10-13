# StateBridge v31：已发布，确认界面仍待现场核验

2026-10-13 19:31:25.886863 UTC（美东15:31），本人19:27明确批准后，原私有服务v31发布成功。此前“不部署”限制已被这次明确批准替代，不需要再为同一发布询问。没有新App包、CloudKit迁移、服务或权限；仍需本人对真实操作具体确认。

## 发布和源码证据

- 线上地址：https://jason-state-bridge.jason25417.chatgpt.site
- project：`appgprj_6ac3bb816d3c8191949bac68d45a62bc`
- deployment：`appgdep_6ace8702515c8191be70895773d13cc4`，正式状态succeeded，has_mcp=true。
- saved version：`appgprj_6ac3bb816d3c8191949bac68d45a62bc~appgver_ea635a169d9c8191bb659f67f9c74a70`，实读version_number=31。
- Sites源：`391d4d1e4801d91bf84489c01b7b93c7460e1fcf`；BC源：`c29b3a4a12a984549ca6b13ea48ab6086b3c0843`。152个服务源文件逐Git blob相同，Site发布commit与BC主仓库commit分别记录，不混用。
- 原源码已push到GitHub，c29b3a4时HEAD与remote/main一致；之后文档提交以Git实际为准，不改变已部署服务源。

按Sites官方流程打开同一项目源仓库，覆盖本批受控源码，重新构建，helper提交/推送/打包，再保存并私有部署同一份包。get_site再次核对owner/custom/仅一个允许账户，受众保持。详细关联回执与哈希见[evidence/statebridge-31.json](evidence/statebridge-31.json)。没有把研究原文、截图或秘密上传到其他服务。

## 用户会看到的变化

下一条自然请求的确认表单使用短标题，完整操作放在确认项description，默认不勾选。过期/撤权后迟到的关闭不再盖成“已取消”；关闭文案不把来源不明的宿主取消说成是本人操作。分钟回调增加发送前的持久占用，避免两个服务实例同时发送同一待投递行；重启、结果丢失仍可按原ID重试。

这些代码现在已上线。短标题只是缓解，尚未看到v31真实宿主表单，不能宣布窄长/空白/提前关闭全部修好；服务接收也不等于设备应用。

## 已验证与尚未验证

上线前85项服务测试、13项记录器测试通过；本次部署使用相同152个服务源文件，发布构建再次通过。测试是内存SQLite/虚拟网络，不能当真人确认或真实操作。

19:32与19:36正式MCP只读connection_status、read_instructions成功；25个来源、一个有效订阅，不代表所有来源都新鲜。线上行为约定哈希已更新，三条旧Megahit请求均仍cancelled、approvedAt/attemptId/result=null，没有重开或启动计时。自然设备上传和轮询的研究回执持续保存。

发布后在19:32及19:35观察到两个自然flush时间重叠的窗口，但均没有新待发变化、delivered=0。固定终点读至研究#39225/19:36:04.841Z，没有新callback_attempt记录；最新实际送达仍是发布前minute_29865331/19:31:14.947Z。因此**线上实际发送期间的占用防重仍未取得新样本**，不能将空队列当作修复验收，不制造用户事件来凑样本。

Worker日志的发布前有限窗口有13次设备调用canceled，不能归因于原生表单取消。发布后5分钟错误查询返回两次未认证GET /api/state的HTTP401、Worker outcome=ok；这符合身份检查，也不等于所有端点均无错误。已核验的健康范围为上述真实MCP读取和自然上传。

## 卡片现场阻塞与下一步

已尝试的支持入口：Edge扩展清单没有Dots/ChatGPT会话页；MCP Apps没有现有标签；可用工具没有直接向Dots对话发消息或读取宿主调试日志的接口，50项会话清单也未定位到它。本机应用清单中的“ChatGPT”对应com.openai.codex，实际只读cua.getApp("ChatGPT")返回明确限制：`Computer Use is not allowed to use the app 'com.openai.codex' for safety reasons.` 这不是用户少开一个权限，也不能绕过限制改用脚本或私有会话目录。

本轮宿主排查至此没有可访问现场。没有转用内置浏览器、抓私有宿主接口或制造真实计时请求。已只询问一次在Edge打开现有Dots页/提供链接，供现场只读排查，不要求重新授权或重提关闭请求。这个入口到位前，不重复轮询服务日志代替宿主证据，也不宣称完整目标已完成。

还缺：v31真实表单的完整description是否显示、容器DOM/计算样式、加载与关闭事件时间及原因、approval-card-published生产方/重发合同。BC拥有schema、文案、生命周期与安全日志，不能直接修改Dots原生表单CSS；分钟重复与宿主关闭的因果仍未证实。获得页面后沿真实原请求/自然下一条需求核验，不绕过本人确认。没有现场入口时停止重复检查，不以扩建平台代替缺失证据。

## 查看、停止、回滚

研究原文仍在现有本地BetterCalendarResearch目录；线上状态用原commandId查询，新增callback_attempt_started/finished只记安全身份/次数/HTTP/持久结果，不含URL、密钥、正文或nonce。received只证明接收端HTTP接受，Dots理解和人看到分别核验。

阻止未确认操作可关闭表单或在原生设置撤回对应权限；本轮没有停用正常设备采集。回滚优先从`0a924a2`重建发布现有私有服务，保留前一轮过期/中性取消修复，只移除本轮回调占用。需保留现有投递与关闭请求记录，不清零次数、不重放received、不恢复旧请求。v30可作历史部署定位，但带已知过期/文案缺口，不是无风险推荐回滚；更老版本可能不认识cancelled/declined，不能盲退。本轮没有执行回滚。
