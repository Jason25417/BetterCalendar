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
|MCP普通定时提醒全生命周期|已实现未发布/未真机验收|已接独立reminder权限、MCP/原审批/指定设备/本地UN排程和读回；82原生/152服务测试通过，不代表真实到点|
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

## 第三批在途：普通提醒本机内核（尚不可从MCP调用）

NativeReminderScheduling.swift提供稳定reminderId/revision、schedule/update/cancel和实际OS pending查询；更新要求完整title/body/fireAt/sound/experiment、expectedRevision，取消不接受新内容，使用同一系统identifier替换/撤除旧计划。控制权检查为本人确认加可重读的本机grant闭包；查询OS权限后、执行前再次检查，权限读取过程中撤回不会继续提交。不会自动请求系统授权或授予持久权限。明确一端执行，后续MCP请求必须指定目标设备，其他端只是展示，不另排通知。

本机先持久操作意图，OS接受后查回内容/排程再持久结果；回执丢失重试只查询同一计划，不自动重排未知通知；取消重复删除同identifier安全，但若原cancel后已经有新revision则阻断旧cancel，不能删掉新计划。已成功旧command只返回历史回执，不重新应用。到点后没有送达信号就elapsed_delivery_unknown，不能把本机saved记录冒充系统仍有计划。当前记录≤500/操作≤2000/文件≤8MiB，700目录/600文件，满容量明确失败；不静默删去去重证据，不写行为日志/计时/成就。experiment字段贯穿计划与回执。

10项新Mac隔离测试通过，全部使用假系统通知/内存或临时目录，另构造UNCalendarNotificationTrigger验证UTC绝对时刻、非重复、stable identifier、默认无声、不含审批category。没有调用真实UN通知中心，没有真实响铃。iOS Simulator构建通过（日志/private/tmp/bc-loop-reminder-core-ios.log）。本机内核不是MCP功能验收，E01–E04仍空；尚未注入AppContainer/NativeRemoteExecutor、没有新增授权按钮或线上工具。

直接下一步：沿用native_requests审批/设备队列，增加kind=reminder及独立reminder.schedule/update/cancel/read权限（默认关闭），请求明确reminderId、expectedRevision、标题/正文/时间/声音/experiment。审批正文完整展示前后与目标设备，提醒不能复用普通item通知直接批准规则。指定设备调用本内核后回传同commandId/版本与系统排程/未知状态；查询优先复用已有按独立读取权限发给设备的只读请求模式，不另造任务数据库。完成MCP schema/执行/查询/权限面板与隔离测试后，再接共享计时mode/experiment并攒批更新。真实提醒对象/声音/时间仍需本人具体批准。

## 第四批：普通提醒接入MCP、审批和指定设备（本地完成，尚未发布）

MCP复用submit_native_command，kind=reminder，schedule/update完整给title/body/fireAt/sound/experiment/reminderId，update/cancel另需expectedRevision；read_native_reminders在独立reminder.read权限下读取设备，不自动授权/批准或排程。所有操作仍同commandId/requestHash/attempt/revision，不重复向每端写入。普通提醒与AlarmKit分开，无应用屏蔽/自动推断/保证叫醒。新read/write默认关闭，旧一键权限不自动包含；旧权限保存会保留已经明确启用的新范围，但不会代替本人开启。

NativeRemoteExecutor接原生队列执行/回执；本机独立grant版本/到期/同步和系统通知状态复查，执行中撤回也停止后续系统修改。BC内/聊天显示完整正文、时刻、声音、实验标记、执行设备和修改前后；服务端before来自认证设备实际排程/读取回执，不信模型自行写的before。父revision关系与设备观察时间共同防迟到旧读回遮住新版本；本机执行前仍查expectedRevision。短完整变更可从系统通知批准/拒绝，长内容只提供详情，通知默认点击不批准。读请求不进入审批列表，避免把独立读取误说成本人刚批准或占满30天审批列表。

查询按目录hash/过滤/游标固定内容，实际系统状态逐页读取并记录readAt；若读取期间目录/权限变化则整页失败，不合并不完整页；每页≤20条/40KiB，返回hasMore/nextCursor。用户点击记录绑定原revision，通知中心有entry仅是OS可观察证据，不是人已看到/听到；缺少pending/delivered时过去时间=elapsed_delivery_unknown，未来时间=system_plan_missing_unknown。撤回对话权限只阻止新读写，不自动取消已被本人安排的系统计划；要停止须先逐条取消。改期/取消尚未收到指定设备系统查回前，旧提醒仍可能触发，尤其设备离线时；服务接收/本人批准不能当作撤旧已完成。

同时修正上批通知路由门槛：首次选择主要设备仍需所有参与端近期新协议，选择后仅另一端15分钟未上报/休眠不再阻挡在线主要设备。记录配置时的兼容设备，运行时明确上报旧协议则unknown保护，不切到别端、不事后重发同command。此前按所有端心跳新鲜度逐请求拦截会损害原型可用性，已以隔离sleep/legacy测试更正；不是把旧活动状态说成当前。

本批验收：NativeApprovalInbox/NativeRemoteExecution/NativeReminderScheduling/NativeConversationPermissions共82/82（xcresult机器摘要、0失败/跳过），服务152/152，TS及production build、iOS Simulator构建通过；额外提醒布局附件单独导出。没有实际ChatGPT宿主回传、系统响铃、本人按钮或真实事项操作，线上仍177/40。E01–E04仅实现格转勾，仪表盘17/40；真人与后台矩阵格不动。

接下来继续共享计时mode/experiment：MCP轻计时/番茄共用同session/revision，默认兼容旧light；番茄阶段从同一服务时间锚推算，不让跟随端建会话；合成计时从真实工时/成就/日历隔离。然后合并为有意义的双端TestFlight批次，先部署兼容服务、再发布App并验实际ASC状态。新提醒与跨端权限由本人在新界面开启；具体事项/计时/声音和时间仍逐次本人确认。APNs另案无凭据/无上线，仍只运行时20秒审批轮询；已交OS的定时提醒与新审批后台到达能力分开。

布局核对：390/620pt Mac离屏图已实际查看，正文/提醒时间（本机时区）/声音/实验标记可读，底部批准/拒绝固定。发现材料底栏透出下层设置文字，已仅改为不透明系统背景，30项审批专项再过；不是iPhone真机或ChatGPT宿主验收。受控图片Agent/evidence/reminder-integration-local/narrow-390.png及wide-620.png。真实测试前不用点这些合成截图中的按钮。


## 2026-10-15 共享番茄与合成隔离（仅本地实现）

Jason明确拍板：番茄到时静默转正计时，从已经工作的时长继续。25分钟到点显示25:00，继续到26:00；不归零、不结束、不自动休息或响铃，不完成关联事项。数据库保留原mode=pomodoro作为来源事实；阶段仅按净投入投影，不写额外命令/revision/session。暂停的净投入不增长，恢复沿用同会话。

- sessions增量0008：mode(light默认)、focus_minutes(番茄1–240整数)、experiment(false默认)；旧会话原值、旧command/result原文不重写。MCP submit_native_command与task_command在start接受mode/focusMinutes/experiment，后续动作不可改变。原生预检、具体确认页/聊天完整展示；执行仍须本人按钮和原grant/hash/command/revision。
- 原生cache缺新字段按旧light解析；App和Mac菜单显示倒计时，到点显示累计。新状态拒绝旧readAt、revision回退、同版本状态/命令变更、原会话模式/实验标记变更、已结束会话复活；失败保留旧cache、不发应用确认。精确执行回读也核对模式/分钟/experiment。
- 锁屏/灵动岛本批使用系统累计用时并在标题显示番茄目标；App挂起也不会出现倒计时归零后等待App唤醒的假结束。未实现/未宣称后台动态切换倒计时样式。时效仍由staleAt提示，显示不代表当前服务已同步。
- 合成start experiment=true永久随会话/动作留存，UI有测试标记，真实会话优先展示，合成不发布FocusFollow活动，不写SwiftData会话、实际日历、成就。默认read_current_state/read_task_history/read_task_commands排除，显式includeExperiments=true可读完整原始命令；分页绑定筛选，不能混页。原始研究变化保留实验标记，Dots指令明确不可算生活工时。
- 本地服务156/156、0失败/跳过；原生三专项80/80后追加隔离/预检测试，最终BridgeTask19/19；类型检查、生产build及iOSSimulator编译通过。机器摘要和日志位置见evidence/minimum-loop-shared-timer-local.json。无真实计时、通知排程、用户权限修改。

发布顺序：先检查/备份现有D1，再以现有发布工具应用0007/0008增量及兼容服务；完整支持需要双端新版App，不能把旧177显示light当番茄验收。旧native请求body/hash/状态不改写。撤回代码时保留增量列和已存数据，勿删表/恢复旧快照覆盖新记录；旧App会忽略模式，暂停试用共享番茄并回到新版后再核验。不重放旧取消/过期命令。

当前仍无新部署/TestFlight；上次实查177/服务40不能代表本批可用。SPEC仅A05/D02实现格更新，所有新真机与延迟/后台矩阵保持未勾，goal active。接下来准备一批值得测试的双端更新，之后逐项本人批准合成对象；APNs凭据、系统权限不随发布自动启用。
