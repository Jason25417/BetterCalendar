# BC 代理能力增量 spec

2026-10-12。与 Agent 目录功能 SPEC §16.3–16.4 同步保存的接口约定。后续§17已授权开始开发：action-prototypes.mjs已实现强提醒shadow权限判定和事项update/delete/restore草稿，测试通过；统一live接口、原生执行与这些新权限仍未开放。实现进展见[bc-next-increments.md](bc-next-increments.md)。BC管真相/同步/版本/执行回执，代理管理解与建议。

### 16.3 增量 spec：未来事项与展示接口（本轮不开放）

统一逻辑入口、分别权限，不要求唯一物理库：

- `suggest_display(requestId, evidenceRefs, displayPatch, expiresAt)`：只写可撤回的建议投影；不能创建任务义务、改变确认状态或真实计时。权限 `display.suggest`。
- `create_item(commandId, payload, source, userAuthorizationRef)`：确认事实/代理提案分区；提案不自动确认。权限 `items.create`。
- `update_item(commandId, recordId, expectedRevision, patch, evidenceRefs, userAuthorizationRef)`：乐观版本检查、字段级来源、权限 `items.update`；冲突需重读，不自动压过用户事实。
- `delete_item(commandId, recordId, expectedRevision, userAuthorizationRef)` / `restore_item(...)`：回收站、至少30天、保留原文版本，权限 `items.delete`/`items.restore`；删除与展示隐藏不共用授权。
- `task_command` 继续独立 `timing.control`，稳定commandId核对session/revision，仅用户明确请求；idle/offline不暂停。结束计时≠事项完成。

回执统一 `{commandId, acceptedAt, persistedRevision, deviceApplication: pending|applied|failed|unknown, deviceReceipts, conflict, recoverable}`。服务接受/保存/设备应用分层，不能把accepted当跨端已显示。底层 SwiftData/CloudKit 与D1可各司其职；需记录同步来源、版本冲突及可恢复快照。新编辑队列、全量旧史迁移和复杂合并继续后置。

### 16.4 增量 spec：强提醒作为独立能力（首轮仅 shadow）

四个不同能力，不相互扩大：普通通知 `notification.schedule`；原生闹钟 `alarm.schedule`；番茄钟 `pomodoro.control`；应用屏蔽 `apps.block`。允许响铃不等于锁应用；建议展示也不能启动其中任何一个。

支持单次用户明确安排，以及用户主动启用的有界自动策略。策略版本内容必须齐全：policyId/revision、用户授权证据、生效/失效时间、事件范围、所需证据和时效/缺失规则、允许渠道、每小时/每日频率、最长持续时间、安静时段与**明确授权的**例外、撤回/解除入口、已排程清理规则。置信度不是授权；撤权后新操作拒绝，设备已排程内容还需独立取消回执。

先shadow写拟排程理由/证据/将使用的授权/拟通知时刻，不真实响铃或屏蔽。评估误报漏报、延迟、额外注意力、实际帮助后，由用户明确启用 live。未回应不能从 shadow 自动毕业。

已确认关键时刻优先设备原生持久排程，计时/已排闹钟不依赖模型持续运行或实时网络。提供 `inspect_reminder_capabilities`、`schedule_reminder`、`cancel_reminder` 独立接口；设备先核验OS/API、授权与用途说明、请求是否仍在pending/alarms清单，记录系统ID及授权版本。排程已保存不保证用户醒来；失败和未知如实返回，禁止以普通通知替代“保证叫醒”。

2026-10-12已查代码：BC当前使用UserNotifications，没有AlarmKit adapter。Apple官方AlarmKit支持iOS/iPadOS26的原生闹钟/倒计时且需要独立授权与NSAlarmKitUsageDescription；本轮未请求或核验Jason真机该授权，也不推出macOS保证闹钟。资料：[AlarmKit](https://developer.apple.com/documentation/alarmkit)、[Apple官方排程示例](https://developer.apple.com/documentation/alarmkit/scheduling-an-alarm-with-alarmkit)、[普通本地通知](https://developer.apple.com/documentation/usernotifications/scheduling-a-notification-locally-from-your-app)。
