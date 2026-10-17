# 0.65.21 /178 实验闭环测试批

服务已发布v41；App两端178已由ASC回读确认VALID+IN_BETA_TESTING，中文测试说明一致。实际回执见evidence/minimum-loop-release178.json。归档源码c64d6e2；后续只加测试/证据的commit不需要重发App。SPEC §18为唯一勾选真相源，仪表盘实时读取。

## 已通过

- 本地Mac全量400测试、服务156测试、0失败/跳过，iOS Simulator和服务构建通过；不等于真机验收。
- 共享light/pomodoro和experiment贯穿MCP、本人确认、服务会话、设备缓存与历史。番茄净投入到目标后静默转正计时，保留累计，不新增session/command/revision，不自动结束/休息/响铃或完成事项。
- 本地隔离测试验证原始commandId重试、暂停冻结、晚读/旧revision不覆盖、旧缓存可读、旧数据库原值及回执原文保留；合成计时不建第二份本地工时、实际日历或成就。
- 普通一次提醒：独立默认关闭read/schedule/update/cancel权限，具体内容/设备/时间/声音本人确认，唯一设备持久排程、系统读回、同identifier改期/取消、未知结果不盲目补排。
- 跨设备审批显式opt-in与主要通知端策略，原command冻结路由、不自动failover；持久通知准备/提交/未知/点击回执与业务状态分开。
- 原有真机证据保留：iPhone聊天批准→Mac创建唯一合成待办、Mac BC备注修改→设备保存与目录读回。Jason已更正只有Mac App亲点，不能把它写成iPhone App审批通过。
- 私有Site v41成功/has_mcp，增量表已见、正式MCP说明及capabilities可读，owner-only受众不变；旧设备grant没有自动增加普通提醒能力。

## 已知失败

- Mac Dots聊天待确认容器2px/正文0px仍为宿主缺陷，支持报告另追踪；未通过切native、缩短文案或本机页面可用来冒充修复。iPhone聊天已有成功保留。
- iPhone逐App用时尚未接入；没有新增Apple entitlement、配置或权限。Mac已有采样累计不证明手机支持或全时覆盖。

## 未验证

- 178 iPhone App审批和两端通知按钮、对端结果收敛/旧通知清理、主要设备实际只响一次。
- 本轮两种共享计时各四动作、同session/revision、真实时差测量；锁屏本批显示系统累计+番茄目标，未声称挂起后自动换倒计时样式。
- 普通提醒实际OS排程及到点、改期/取消旧通知不再出现、锁屏/后台/退出/断网矩阵；普通通知不保证叫醒。
- 完成/取消完成、删除/恢复仍需在唯一标记待办上分别本人批准并读回。测试不是生活活动，别动真实旧事项/真实计时/系统权限。
- 无APNs。新的审批仍依赖App运行中约20秒读取；手机挂起/退出不能保证新审批及时到达。已经设备排程的普通提醒走OS本地计划，与这件事分开验。

## 2026-10-16 20:58 EDT：178首条通知审批在途

本人报告两端已更新；正式MCP在00:55:26.566Z核实iPhone与Mac均0.65.21/178，系统通知允许、审批提醒已开、routingProtocol=1，无APNs。两端完整pool快照读到同一标记待办C5472AF0…、备注及revision23066b61…08332；这只证明目录读回，不替代屏幕验收。跨设备审批策略表仍为空、新普通提醒权限仍无，未代开。

Dots仅提交一条Mac执行的item.update，将测试标题「BC 联调测试｜双入口验收」改成「BC 联调测试｜通知审批178」，其余不变。commandId a92d51c7-73e4-4ce8-8d1e-64fe20b9a178，acceptedAt 2026-10-17T00:57:57.039Z，expiresAt 2026-10-18T00:57:56.895Z。通知唯一目标为原Mac，00:58:13.662Z设备回报system_submitted（接受至提交16.623秒）；clickedAt为空，业务仍awaiting_confirmation，approvedAt/attempt/result为空。单次延迟不是三次在线时延验收，也不证明用户已看见。已请本人仅在Mac系统通知核对并批准，以区分通知入口；不由模型点聊天表单/原生批准，不自动追加提案。

证据evidence/notification-approval178-first.json；本轮没有运行时代码变更、重新发布、计时或提醒排程。SPEC仍22/40，B06/07/08及其他真机格不勾。Dots待确认表单截图仅保留本地/private/tmp/bc178-notification-test-proposal.jpg，当前浏览器样本可读；这不是宿主原2px问题已解决或本人聊天入口验收的结论。

## 试用顺序

1. 两端更新178并各打开一次，先核对设备上传的实际版本/时效。旧177不具备新模式/路由，不做混版本验收。
2. 新能力均保持关闭：本人可在待确认开启跨设备审批，设备新协议与通知状态齐全后选择一个主要通知端；普通提醒在原生操作里独立开启相关权限并保存。已有系统通知授权不要求重复申请，也不会因升级代开新逻辑权限。
3. Dots先只读检查新说明、工具发现和新权限，不重新扫描稳定健康/浏览器/文件来源；工具缓存缺新schema就说明缺什么，刷新已有插件工具需本人操作时请本人处理，不绕过应用限制。
4. 本人说准备好后，一次只测一个具体变更：保留唯一「BC 联调测试」todo；计时另用明显测试标题且experiment=true；普通提醒先明确目标设备、标题正文、未来时间和是否声音。每步保持commandId/revision，具体确认由本人点。
5. 记录服务接受、本人批准、目标设备实际应用、另一端缓存/屏幕四层证据；分别记录发生/接收/应用时刻。端到端未过不勾真机格。

## 停止和回滚

可在待确认关闭审批通知/跨设备审批（本机立即锁定跨确认，撤回服务结果单独核对）。关闭采集不自动暂停既有共享计时。已经系统排程的普通提醒不会因撤销逻辑权限自动消失：需要先明确取消并等原设备系统回执，再撤权；离线设备未应用取消前旧计划仍可能触发。不要把服务queued/accepted当作已取消。

可回装先前测试版，但旧App不会正确展示新的番茄模式或主要通知端策略，应暂停新闭环测试并将参与端统一到新版。服务回滚保持D1增量列/表与已保存请求，不删表、改旧hash、复活旧取消/过期命令；新记录不能用旧快照覆盖。没有CloudKit @Model变更，无需以本批为由部署新CloudKit schema。


发布后Dots只读回报（17:57EDT，代理报告，非本人验收）：新说明已可读，但其工具schema仍旧（缺mode/focusMinutes/experiment、reminder kind和read_native_reminders）；Mac上传177@17:56:46当时有效、iPhone177@17:44:18当时stale。新增提醒权限仍无。已通过Edge官方既有插件管理页点击刷新工具；未改全部允许偏好/BC grant/账户，后续已请Dots再次只读复核，结果尚未返回时不称缓存已修。官方元数据刷新流程：https://developers.openai.com/plugins/deploy/connect-chatgpt#refresh-metadata 。

后归档追加测试不改变App运行时代码：NativeItem逐个create/update/done/active/delete/restore在effect保存、回执失败后用新context恢复、再原命令重试，唯一对象及原revision保留；BridgeTask已finish快照后迟到active不复活。原生目标28/28；服务两实例竞争同revision仅一胜出、原回执幂等，目标55/55。源码tests和证据单独提交，不为此重发178。


后续官方刷新已收到Dots明确回执：当前schema可见timer start mode/focusMinutes/experiment、reminder kind和read_native_reminders。仅工具定义检查，没有调用新提案或提醒查询。原始缓存缺口已解，仍等两端178实际安装打开和本人具体批准；不把新工具可见当作设备执行通过。截图仅保留/private/tmp/bc178-dots-refreshed.jpg，不向Git复制私人聊天。
