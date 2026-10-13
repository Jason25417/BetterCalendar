# Dots 确认组件的协议核验

2026-10-13，原生客户端仍0.65.14/171，现有私有服务更新到v27；数据、权限范围和CloudKit不变。

真实5529提案已通过UUID校验，但Dots发送工具报告“The widget is unavailable.”。v26补齐submit、状态、确认、只读日记和兼容计时入口的outputSchema；用实际服务产生的待确认、队列、接手与设备结果验证公开回执结构，并拒绝把approval/token加入模型可见对象。既有权限、重试和组件按钮隔离测试仍通过，合计19项，无失败或跳过，构建通过。

新增资源发现诊断只记录固定协议方法、已知UI URI及请求URI是否匹配，不记录身份、请求参数、用户状态或凭据。运行时日志确证发布/刷新期间宿主来读了已知HTML资源，HTTP200；这不证明已生成或发送widget。v26真实Dots原样重试后仍失败，不能把outputSchema修正称为卡片根因修复。

进一步按[MCP 2026-07-28工具规范](https://modelcontextprotocol.io/specification/2026-07-28/server/tools)核对，旧成功响应遗漏resultType=complete。v27补齐工具结果及JSON-RPC完成响应，保留现有正文、structuredContent及隐藏_meta。研究回执哈希仍针对正文，不因外层协议标记改变。19项测试和构建再次通过，服务发布成功；正式状态读取仍可用。

原真实提案于14:39 UTC过期；14:41独立正式查询返回expired、approvedAt/attemptId/result=null。不会延长期限、新建编号或声称已计时。v27用原样过期请求复测，Dots10:44美东再次明确报告widget unavailable；状态与原样submit实际callId分别research_26ae5e45-0485-4283-8c29-d08478218d43、research_19506588-014f-4161-8afb-1521e44eeca8，已停止循环。确认按钮是否禁用也未能核验，因为组件根本没有显示。既有submit对已保存请求只核对同一哈希并返回历史状态，不生成批准凭据、不重新下发。缺少可见卡片和本人按钮确认时，真实执行仍未验。

证据见[evidence/mcp-ui-contract-26-27.json](evidence/mcp-ui-contract-26-27.json)。原始工具内容和截图保持在本地受控研究档案；Git仅留必要关联与回执元数据。现有private audience保持owner-only，未复制资料到新服务，无新增原生发行包。

后续只沿实际结果排查：v27显示复测已实际失败；v28已验证Dots当前请求声明MCP form elicitation能力，v29实现MRTR原生确认方式，见bc-dots-native-form.md。它必须保留人本人确认、同请求/设备/哈希、期限与撤权核验，不能改成模型传userConfirmed。能力声明和适配代码不证明Dots实际显示表单；本人确认及真机应用仍待验。当前目标继续active，完整真机执行和多端验收未完成。
