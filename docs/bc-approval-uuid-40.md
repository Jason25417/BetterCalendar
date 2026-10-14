# 原审批请求 UUID 大小写修复（服务40）

2026-10-14。真实请求 d0fd563b-321c-4e12-a2b9-db31229cef4b 保存成功后，确认展示查找返回409。请求 recordId 为小写，Swift目录 UUID 为大写。confirmation-presentation.mjs 原使用严格字符串相等；隔离同版本/同UUID大小写样本在修复前确实复现409，不把失败归因于过期或本人取消。Dots的17:25/17:26报告已读取；MCP21:33前后读回为awaiting_confirmation、approvedAt/attemptId/result均空，期限到次日21:25:25.484Z。

只改变确认内容读取的UUID值比较，不修改已保存request、requestHash、commandId、grantRevision、expiresAt或expectedRevision。仅标准UUID允许大小写等价，不扩展设备/opaque标识、版本、分页游标；同页多个等价身份拒绝，版本不同仍409。聊天展示、BC读取和BC同意前的展示检查共用这条读取逻辑；不是宿主2px布局修复。

新增隔离测试：大小写双方向解析、原请求不变、不同UUID/版本/非UUID大小写不合并、同页歧义拒绝；真实HTTP路由级read/approve，版本变化阻止批准、原版本恢复后同请求只排队一次。修复前新回归2失败已记录，修复后服务器全部129通过、0失败/跳过。HTTP测试仅内存SQLite/模拟设备，不操作真实用户数据。原生代码未变，不发新TestFlight。

下一步：现有owner-private State Bridge同站点发布；确认部署成功后，只刷新Mac BC已有原请求详情。本人核对完整原/新备注再批准；读回同commandId的服务决定/设备回执和目录版本。不重新submit、不弹新卡、不改旧哈希，不模型代批。若取消/过期则停止，不复活。iPhone通知开关仍等新快照；后台APNs与Dots Mac聊天2px仍未接通/未修复。

上线/回滚：只替换服务confirmation-presentation模块与回归测试，无schema/权限/新服务/原生变更；必要时回滚已保存39版，原请求与回执留存。部署、实机显示/本人决定/设备应用证据单独追加，不把129测试称端到端完成。
