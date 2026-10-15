# BC 实验最小使用闭环（2026-10-15）

当前主线和唯一勾选真相源：BetterCalendar_Agent/日程软件功能设计.md §18（仪表盘 http://127.0.0.1:8765 ，2秒轮询）。本文件保存审查、接口及证据；不与SPEC建立第二套完成计数。目标完整保留事项各写操作、轻计时与番茄各四动作、普通定时提醒全生命周期、多端状态、主要通知设备去重，以及前台/后台/锁屏/退出/断网恢复矩阵。旧Mac聊天2px降级，不作为本轮完成门槛。

## 现状审查

|能力|状态|证据与缺口|
|---|---|---|
|手机聊天批准→Mac合成创建|已实现已验收|8f3e6be2… applied，原生落库读回；不重复测试|
|Mac BC备注修改→结果反馈|已实现已验收|d0fd563b…本人截图，resultAt 2026-10-15T00:28:18.784Z、revision23066b61…08332与Mac目录一致。新目标原文说“仍缺执行证据”已被后来证据更新|
|iPhone BC、系统通知动作|已实现未验收|本人最后更正只在Mac点同意；两端系统authorized且审批enabled不等于送达|
|事项完成/撤销完成/软删除恢复|已实现未验收|NativeItemCommands与native-commands已有路径，不能复用备注验收扩算|
|全端审批与主要设备路由|已实现未部署/未真机验收|新原生独立跨设备开关、本机撤权检查、主要设备协议门控和持久通知日志；隔离59原生/143服务测试通过，仍线上177/40|
|重复与冲突|已实现未全面验收|服务129隔离测试、通知21专项；尚缺真机竞争/断网/重复点击|
|共享轻计时四动作/查询/补记|已实现未验收|shared session/revision、设备缓存及历史接口已有，不自动完成事项；真机多端未齐|
|共享番茄MCP参数|尚未实现|本地番茄与CloudKit FocusFollow已有，BridgeTaskSession/MCP无mode字段，不能标MCP番茄闭环|
|MCP普通定时提醒全生命周期|尚未实现|本机早晚UN提醒已有，独立MCP schedule/update/cancel/read与设备回执未接|
|iPhone单次原生闹钟|已实现未验收|AlarmKit schedule/cancel；Mac Unsupported；不能当普通跨平台提醒或保证唤醒|
|新审批后台推送|尚未实现|2026-10-15实际device.status仍local_poll_20s_while_app_runs/remoteApprovalPush=false；无APNs|

## 本轮逐项验收

实施/真机格均已写入SPEC §18 A01–F08，独立分类初始39格/9勾；加入独立服务端实现项B03a后40格/10勾，本批B03–B05实现后40格/13勾，不能当真机通过率。闭环通过前总目标始终active。测试对象沿用唯一BC联调测试待办；计时与响铃另需先说明对象、时间、声音、experiment影响，取得本人批准。不能把目标当业务批准，不重放已关闭提案。

在线目标是待测指标：审批服务接收到系统提交≤30秒，计时同session另一端在线缓存≤15秒，事项另一端目录≤90秒；同网/双端在线至少3次，记录发生/批准/claim/应用/接收/检索及屏幕观察；超标保留事实不延长TTL遮蔽。定时通知在OS已排程、允许通知且无专注抑制时±10秒，由真实可观察信号核验，不虚构送达/用户看到。前台、后台、锁屏、退出、断网恢复分开；新审批推送与预排提醒不能混为同一个能力。

## 授权和最小实现分批

1. 先完善审批主要设备与跨端观察/决定边界：本机既有权限保持；跨设备审批默认关闭，由本人明确独立启用，绑定本机原grant revision/期限。所有决定仍核对指定执行设备的grant/requestHash/expectedRevision，首有效决定原子生效。主通知设备配置显式、带revision，路由对同commandId冻结，无自动故障转移；更改设置只影响尚未冻结的新请求。设备离线不授权其他端同时提醒。
2. 通知回执区分claimed/system_submitted/failed/unknown/clicked。系统非事务资源，进程在提交与持久回执之间中断必须显示unknown，不能用幂等键承诺exactly once。原通知identifier固定，迟到按钮只读当前结果。
3. 普通提醒独立kind/权限/对象revision，确认后持久设备计划并交系统；查询/修改/取消同reminderId，排程不依赖聊天、实时模型或网络。原生闹钟独立，预排提醒已提交OS与尚未到设备必须分开。
4. timer补mode/experiment字段后贯穿服务、缓存、UI/LiveActivity、history，只一个session；现有轻计时兼容。合成计时不落真实工时、用户完成统计或日历。
5. 所有代码/隔离测试就绪后攒成一次设备更新/手测批次；先给本人具体测试对象与影响，再开始真实写入/计时/响铃。APNs先完成可注入provider隔离测试，新增密钥/权限本人单独处理。

## 当前三张清单

已通过：手机聊天→Mac创建；Mac BC备注修改/完成反馈/读回。失败：旧Mac聊天2px（本轮非门槛），旧UUID大小写409已修复并有真机读回，不重复挂为现存阻断。未验证：其余真机矩阵；尚未实现项按上表与SPEC继续推进。App仍177，线上服务仍40；本轮未改系统权限、无新真实命令/计时/通知。

## 第一批实际实现：审批路由后端（未部署）

新增approval-routing模块与两张增量D1表：native_approval_policy和native_approval_notifications；不修改CloudKit/@Model、旧request/hash/期限。设备API新增approval-policy/read/configure及notification/claim/receipt，非MCP模型工具。独立review opt-in绑定本机既有grant版本与期限，撤回/换grant立即失效；决定SQL事务内再次检查review policy/grant版本，防校验到落库之间撤权竞争。所有设备是否可见由显式opt-in控制，旧target-only默认保持。审批分页保留近30天终态供其他卡片收敛；执行pending仍严格只有目标设备。

主要通知设备按首次领取冻结在commandId记录上；无自动故障转移，切换设置只影响未路由请求。reserved/system_submitted/unknown/failed/clicked不等于业务同意或设备完成，旧回执不降级submitted/clicked。reserved丢响应的OS提交结果仍须原生持久outbox核验，服务唯一键不保证exactly-once；原生接入、系统已存在通知查询/未知处理仍待开发。跨设备收到展示必须携带reviewContext（审核端设备/grant版本/policy版本/期限），决定另传这两个审核版本；target request身份和expectedRevision不改。

140项服务器测试通过，0失败/跳过，含新增10个路由用例与1个真实HTTP端点用例；类型检查和生产build通过。检查中发现旧research.append actor=null推断及既有Env配置缺声明，已只补JSDoc/类型声明，不改运行时权限。审批列表终态保留的旧测试预期相应改为保留declined而非都expired。Python dashboard语法检查、HTTP JSON与Edge新分类10/40均已核实，截图/private/tmp/bc-minimum-loop-dashboard.png。

仍177/线上40；不部署这一中间批，原因是原生尚未读新policy/回执、未提供用户独立开关，且旧177不能识别跨设备reviewContext。下一批先补原生DTO/界面/通知持久outbox和原生测试，再整批发布。主要策略启用前必须核验参与设备均支持新协议，避免旧客户端继续按各自目标发通知；不能为兼容任意放开读取或自动改本人设置。

## 第二批实际实现：原生接入与通知持久日志（本地验证，未发布）

跨端查看/决定默认关闭，需要本人独立开启；原生同时检查本机持久授权是否同步、版本及到期，离线撤回立即锁定，并只重试撤回而不自动启用。请求保留原执行设备；审核端另外带reviewer grant/policy revision，服务器决定写入再次核验。所有近期终态保留在列表，当前选中页及旧通知都会读同commandId的有效状态；只有本人具体按钮才发决定。

主要设备设置是设备认证API，不暴露给MCP模型；参与设备必须最近15分钟报告routingProtocol=1，选中的主要端还须已经主动开启审批通知且系统允许；旧版/过时/缺少状态时不能启用主要设备。规则仅用于设置后接收的新请求，已有请求保持原路由。首次selected-device预留只可消费一次：别端先扫描不占用它，重复领取不再返回beginSubmission。选择之后出现混版本/过时状态的新路由标unknown，不能后来自动重新发出；不自动故障转移。旧版无法被新客户端控制，全部更新是启用条件，不承诺降级客户端也服从规则。

通知先把prepared日志落本机，再提交OS，OS接受后存submitted，最后只重试同条证据回传。进程崩溃/初始预留回包丢失，查询同identifier的OS pending/delivered；查不到是unknown，不盲目再次提醒，BC列表仍兜底。submitted/点击回执在请求结束后也能补传；错误commandId/状态不确认。通知正文包含事项和执行设备（部分系统隐藏subtitle），短完整变更才提供批准/拒绝，否则只开详情。通知动作绑定review元数据；本机通知日志最多2000条，达到容量会明确失败，不无声删去去重证据。系统提交不证明横幅显示，点击只记录设备报告，用户已看到始终未知。服务systemSubmittedAt/clickedAt为接收设备报告时刻，非OS送达时刻，不能用它虚构精确送达延迟。

本地验证：原生NativeApprovalInboxTests 29项 + NativeRemoteExecutionTests 30项通过（59/59，正式Xcode，内存SwiftData/假服务/假通知），服务143/143；Typescript检查和生产build通过，iOS Simulator构建通过。没有读取ChatGPT私有库、没有新增真实提案/计时/响铃，没有代启跨设备权限或更改系统授权。

2026-10-15T16:31:25.990Z正式只读MCP核验：iPhone完整todo页12条、无下一页，15:32:46Z快照已包含唯一c5472af0…测试项，备注新增Mac App审批验收177，revision23066b61…08332与Mac应用回执相同。快照当前stale，故仅证明该时点修改已同步；不证明当前状态、手机UI/本人审批或通知操作。限定单记录证据见evidence/minimum-loop-phone-readback-2026-10-15.json。

待发布前置：普通提醒完整链和计时mode/experiment继续开发后合并有意义的设备测试批；本批不单独要求用户更新/反复点同意。APNs仍无，20秒运行中轮询不变。B03/B04/B05的勾仅实现与隔离验证，B06–B08/F03–F08的真人目标仍未通过。
