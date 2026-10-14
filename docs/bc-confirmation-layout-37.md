# v37：确认回传兼容通过；电脑宿主布局仍未通过

2026-10-14。本轮延续 v35/v36；仅 StateBridge 服务改动，原生仍 0.65.17 / 174，不改事项、权限、计时、通知或数据库。代码 `a17c59079c6ce18946ae44ea0ab07160f26900aa` 已推送。同一 owner-private StateBridge v37 于 15:23:42.625778Z 部署 succeeded / has_mcp；部署 `appgdep_6acf9e740ddc81919cef56d105ad871d`，发布源 `f21da9994872937b01769f452bd847001b18f5fc`，发布时156个服务文件逐项一致。没有增加服务、应用或访问授权。

## BC 修复和真实回传

今天旧请求 `cc7f3428-828a-46b9-b5ec-f8bcf0909dc2` 的 accept/confirm=true 在14:55:27Z、有效期内到达，仍400「请求包含不支持的字段」，因此不是本人点晚。旧日志没有保存额外字段名，不能追认确切被拒字段。另一旧请求 `046f8f93-9f7e-4657-a87f-c07f3b737401` 在14:50回复已超过14:37期限；两者现在均已到期，不追认或复活。

新增 `native-form-response.mjs`：只接受正式业务 action/content 和已知非授权外层 `_meta` 对象、可选 resultType=complete；去除外层元数据后再严格核验内容。未知业务字段、缺少明确 true、字符串/数值冒充勾选仍拒绝。owner、原请求哈希、挑战、工具来源、设备、grant revision、期限及执行前版本校验保持。诊断只记结构和类型，不保存元数据值、令牌或任意响应原文。

真实 Dots choice 显示测试在15:29:58.305Z回传，研究89916：外层恰为 action/content/_meta，_meta为object，confirm为string，未知外层及内容字段均0。归一化成功；Dots报告hostResponse=accept、executed=false。review在15:32:03.268Z回传，研究90046：相同外层，confirm=boolean、review=string，亦成功。这是实际宿主元数据兼容证据；不是原生真实修改的端到端验收。旧严格外层keys检查会拒绝这次观察到的_meta，早先两条400是否为同字段仍缺原始证据。

两种对照均使用已有 record_context 的专用只读模式；不保存context/活动、不批准、排队或重建命令。原 `518db08f-af21-4c4f-99be-56d70d7d73c2` 现场再次核对仍cancelled，approvedAt/attemptId/result均null、原哈希/revision未变。原02:51取消早于期限，取消生产原因仍unknown，不能描述成本人取消。诊断提交也不能当作真实操作授权。

## 分端布局证据

| 表面 | 待处理 | 回复后 | 证据等级 |
|---|---|---|---|
| Edge扩展，1912×931 CSS / DPR2 | choice及review卡宽2px、高849px，form宽0、高847px；正文/按钮被裁剪 | choice仍宽2px | 直接DOM与截图 |
| 用户电脑端 | 本人报告仍长条、内容未完整显示 | 手机回复后开始显示；附图仍偏窄、较长 | 本人陈述与本次附件；具体宿主未独立确认 |
| iPhone Dots | 本人报告正常显示并回复 | 服务收到上述只读结果 | 本人报告+真实回传；不冒充独立录屏/尺寸测量 |

choice和review是逐次对照，第二张在第一张回传结束后才发布，各只准备一次（89863、90034），不是同请求重复业务弹窗。没有把它们替换进真实业务流程。choice默认不执行；review默认false，宿主把两字段分页显示，不能保证提交前全部摘要同时可见。两种对照均未解决电脑宽度，也不符合最终确认UI验收。Edge取消按钮普通点击及键盘激活均无法正常进行，没有force点击、修改宿主CSS或接管受限ChatGPT应用。

本机证据：`/private/tmp/bc-confirmation-37-choice.jpg`、`/private/tmp/bc-confirmation-37-review.jpg`、用户附件`codex-clipboard-1a68f592-6c57-4e87-bd1e-d50e1a934451.png`。不复制含私人聊天侧栏的截图到Git或新服务。

## 最小宿主问题报告和缺证

标准form在Dots电脑端待处理时发生容器宽度收缩与overflow裁剪。choice/review/原boolean皆失败，去UUID、缩短标题、移除旧widget广告未解决。外部聊天行768px，request-card 2px，form 0px；review header/body/footer均存在，body虽166px高仍0px宽。请检查 message-bubble-wrap / message-content 的intrinsic width、request-card宽度约束、header shrink和footer可见性，以及pending到completed跨设备更新的重测布局时序。不得靠取消、默认勾选或自动执行规避。

仍缺：用户电脑原生宿主的pending/completed组件与layout时序、原518取消来源及关联messageId日志、两次旧400的确切额外字段、真正业务boolean本人确认后的设备应用/双端回执。BC没有合法控制宿主原生form宽高的接口；不能把服务更新说成电脑弹窗已修好，也不能把只读成功说成事项修改成功。

## 验证、验收和回滚

发布前110/110隔离测试、构建通过。观察真实_meta后再补隔离回归：元数据不替代内容确认；错误nonce及仅metadata拒绝；正确业务勾选+metadata进入队列；重启/重试只一条命令。补充相关31/31与最终全量111/111测试通过（日志`/private/tmp/bc-confirmation-37-host-regression.log`、`/private/tmp/bc-confirmation-37-final-tests.log`），不会连接设备或改真实活动。新增回归文件不需重复发布服务。

已验证：v37部署、真实只读accept及boolean回传兼容、原关闭命令不变、电脑两种替代表单仍失败。未验证：新版本实际业务批准及设备应用、真实cancel元数据格式、电脑原生全部时序。待修：宿主布局。暂不转为自动授权、改成真实事项测试、擅自延长旧命令或增加BC内审批能力。

本人这次已经完成手机显示/回复对照，无需再重复点或造真实任务。只读卡均已结束；不再自动发布。取消步骤的先前提问晚于review已回传，不需再操作。正常使用时仍只在看清具体改动后本人确认；电脑端不算可用验收。

停止：不再发只读对照；已结束测试无业务状态要撤销。回滚：服务源回到 v36 的 `c4802cecd9db4d189709c0bcf9d58dec757c5396` 后重新发布同一private Site，保留持久请求和回执；这会失去新回传兼容，不会重开旧命令。原生174无需更新或回滚。

依据：[MCP form elicitation](https://modelcontextprotocol.io/specification/2026-07-28/client/elicitation)、[OpenAI原生表单](https://developers.openai.com/plugins/build/extensions)。实际_meta是否出现以本轮日志为证据，不用规范猜测代替观测。
