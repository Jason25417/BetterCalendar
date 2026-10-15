# 原审批请求 UUID 大小写修复（服务40）

2026-10-14。真实请求 d0fd563b-321c-4e12-a2b9-db31229cef4b 保存成功后，确认展示查找返回409。请求 recordId 为小写，Swift目录 UUID 为大写。confirmation-presentation.mjs 原使用严格字符串相等；隔离同版本/同UUID大小写样本在修复前确实复现409，不把失败归因于过期或本人取消。Dots的17:25/17:26报告已读取；MCP21:33前后读回为awaiting_confirmation、approvedAt/attemptId/result均空，期限到次日21:25:25.484Z。

只改变确认内容读取的UUID值比较，不修改已保存request、requestHash、commandId、grantRevision、expiresAt或expectedRevision。仅标准UUID允许大小写等价，不扩展设备/opaque标识、版本、分页游标；同页多个等价身份拒绝，版本不同仍409。聊天展示、BC读取和BC同意前的展示检查共用这条读取逻辑；不是宿主2px布局修复。

新增隔离测试：大小写双方向解析、原请求不变、不同UUID/版本/非UUID大小写不合并、同页歧义拒绝；真实HTTP路由级read/approve，版本变化阻止批准、原版本恢复后同请求只排队一次。修复前新回归2失败已记录，修复后服务器全部129通过、0失败/跳过。HTTP测试仅内存SQLite/模拟设备，不操作真实用户数据。原生代码未变，不发新TestFlight。

下一步：现有owner-private State Bridge同站点发布；确认部署成功后，只刷新Mac BC已有原请求详情。本人核对完整原/新备注再批准；读回同commandId的服务决定/设备回执和目录版本。不重新submit、不弹新卡、不改旧哈希，不模型代批。若取消/过期则停止，不复活。iPhone通知开关仍等新快照；后台APNs与Dots Mac聊天2px仍未接通/未修复。

上线/回滚：只替换服务confirmation-presentation模块与回归测试，无schema/权限/新服务/原生变更；必要时回滚已保存39版，原请求与回执留存。部署、实机显示/本人决定/设备应用证据单独追加，不把129测试称端到端完成。

## 发布及真实只读界面结果

40已于21:35:36Z部署成功，MCP可用，仍原owner-private站点 https://jason-state-bridge.jason25417.chatgpt.site 。发布源bb53aa5a、App仓库修复096580d，无原生更新。Mac /Applications/BetterCalendar.app实际运行177；打开原请求成功，AX读到完整原/新备注、标题、设备、截止与可用同意/拒绝。实际初始窗口需要滚动才能读完整差异；原生Scroll Down已实测，前后文本可见且底部决定按钮固定。不能把AX包含正文说成初始视口全可见。截图分别保留初始/滚动后。

只读核验iPhone21:20:35Z完整目录已含同一测试待办、同revision，说明此前缺失已在该快照同步；不表示未来修改或当前通知开启已核。已告知Dots只查原ID，禁止重新submit/补发卡。最新原请求仍awaiting_confirmation、未有approvedAt/attempt/result；本人已被请求在Mac详情核对后点击，agent没有代点。Mac/iPhone真人反馈、通知入口仍待验；Mac聊天2px独立未修，手机后台APNs仍待开发。

## 2026-10-14 20:32 EDT 真人反馈与实际保存

Jason报告“两个都同意了”，并提供Mac真实审批结束截图，底部明确“设备报告已应用”；Mac BC本人批准及完成反馈可记通过，本人随后最终更正为“我只在mac里点了”：只认Mac BC入口；iPhone BC和两端通知操作均未验收。原d0fd…请求approvedAt=2026-10-15T00:28:01.938Z，resultAt=00:28:18.784Z，attemptId=bb3d465e-f2ad-4559-b816-284e7bb6958d，state=applied / local_store_saved。00:31:55Z的Mac完整目录读回备注仅新增Mac App审批验收177，新revision23066b61…08332与设备回执一致。未创建新提案，未启动计时。

手机已读到177、通知开关true与系统authorized，但最新pool00:27:30Z早于批准仍旧revision077306fc…56，因此本次修改后同步未知，不认定失败。Mac系统通知/iPhone BC与通知未由该截图验收；Mac聊天2px仍未修。原截图受控保存在Agent本地evidence/native-approval-40/mac-human-applied.png，未上传图片到新服务。完整限定测试项回执见evidence/approval-uuid-40-human-receipt.json。
