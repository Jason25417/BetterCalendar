# BC 个人研究原型：第一阶段

2026-10-12。本轮范围由 Jason 明确授权：先做可回顾的个人实验闭环，不把全源覆盖、完整编辑、复杂冲突或旧史全迁移作为门槛。本文与 Agent 目录 SPEC §16 配套；后续接口已另存 [事项与强提醒增量 spec](bc-agent-actions-incremental-spec.md)；部署与真实样本证据补在本文末尾。

## 阅读后发现的差异

已读产品设计与行为逻辑（尤其 §2 自主/通知铁则）、CLAUDE/AGENTS 产品原则、功能 SPEC §15、架构地图唯一写者表、当前 handoff；对照 StateBridge core、MCP/API、状态/历史/pool 查询、原生采集与计时持久化、通知服务及临时 pool 发布器。

| 目标 | 现有状态 | 第一阶段改变 |
|---|---|---|
| 个人高保真实验 | §15 已将泛用性后置；App 163 可读状态和共享计时；临时目录可用 | 保留这些路径，不改 SwiftData 模型、CloudKit schema 或 App UI |
| 事件→证据→判断→结果 | observations/changes/batches/deliveries/commands 各有记录，但缺少实际工具调用与结论关联 | 增加实际调用元数据、原文身份与哈希、完整读取校验、处理结果回执；本地下载原文 |
| 四个独立决定 | ForwardAll 只决定转交；提醒/执行主要靠 prompt | 本地研究记录分别呈现接收、唤醒、提醒、执行；真实调用和代理报告分开 |
| 降低唤醒实验 | 只有 ForwardAll，无规则对照 | 旁路 SimpleRulesShadow；不改变 ForwardAll，不影响计时或通知 |
| 可回放对照 | 历史查询有分页，未形成固定输入样本 | 同一归档批次/时间窗构建三组输入；只重放纯规则，无网络或真实写入 |
| 原文与隐私 | 原始观察已在既有私有服务，开发报告常只有摘要 | 本地 700 目录/600 SQLite；保留完整读取响应及可解析的原文引用，排除凭据；不接新服务 |
| 端到端成功 | 计时 saved 与 callback received 不能证明设备应用或理解完成 | 分别呈现服务保存、模型调用、代理自述、设备实际应用未知 |
| 强提醒/事项编辑 | 普通通知、番茄与屏蔽是既有不同模块；无统一代理编辑入口 | 只补增量接口与权限 spec，不在本轮直接开放写日历、响铃或锁应用 |

哲学张力及处理：

1. 旧“永不审计过去”针对用户算账。本轮回看的是助手行为、证据与成本，不产生自律分数、欠债事项或未完成清单。不追认旧调用日志。没有用户反馈永远记 unknown。
2. 旧“失败可见”与“无感/通知极简”有张力。研究错误可查；`debugFeedback` 默认 false，只在本地查看页显示额外静默反馈，不自动变成手机通知。
3. 原“代理而不代权”容许事后可改的自动化，不是任意权限许可证。本轮维持计时仅响应明确请求；设备空闲/离线不暂停；未来强提醒和事项编辑分别授权。
4. 产品行为文档仍有历史 streak 文案，SPEC 后续明确累计优先/streak 永不做。本轮登记为历史文档冲突，不静默重写整个产品行为来源，也不把它带入研究反馈。

## 实际实现

服务 `lib/research.mjs` 与追加 0005 migration：

- 从本轮上线起包围真实 MCP/设备调用，记录开始/返回/分类错误、必要非秘密参数、发生/检索时间、responseHash、原文 observation/command/note 身份、会话版本、时效与覆盖、分页信息。请求开始持久化失败则不执行；已执行但返回记录失败如实报未确认，计时重试保持 commandId。
- 云端不再复制一份工具全文；只保存身份/参数摘要/结果回执。原文仍在原来的观察、commands、notes 表，本地记录器下载可定位原文。日志不会包含请求头、设备凭据或回调密钥。
- `complete_batch` 用实际研究 callId 校验：本批变化按固定 throughId 读完，各页输入游标连贯；读取结果身份与数据库本批一致，不能将第一页当全部；至少读取状态正文。判断内容不是模型私有思维链。
- 结论包含 sourceClass（BC 原生/连接器/用户说明/公开资料/习惯/推断）、confidence、rationale、evidenceCallIds、alternatives。纠正以 supersedes 追加。通知与操作分列；结果回执本身不执行任何通知/计时。
- 稳定 resultId 保证同一结果重试；不同内容不能复用身份。保存结果和 processed_at 在同一事务，失败不假装确认。
- Dots 本轮会话缓存没有发现新增工具，因此现有 record_context 仅对专用 kind=bc.research.batch_result 接入同一 complete 校验；不另存为活动推断，不增加权限。已让 Dots 真实调用成功；新工具可见时可直接 complete_batch。
- 老 acknowledge_batch 保留兼容；它的 processed_at 不升级成“完整研究处理”，查看页以是否有 batch_result 区分。研究完整读取不等于证明模型理解正确。

本地 `tools/research-recorder.mjs`：

- 仅调用现有服务新增的五个**只读**研究端点，凭据从既有 Keychain 读取，origin 固定。没有 command、ack、通知或外部写入客户端。
- SQLite FULL 同步，批次和游标一起提交；断线重试同一游标；进程重启继续，容量不足停采保留游标。最初从本轮当前分钟开始，不假装补齐从前不存在的研究日志。上线后尚未本地下载的回执可补传。
- 完整分页下载变化、当前状态和原始观察/命令/说明证据。每次本地真实 HTTP 的参数/完整响应成为内容哈希快照；代理远端读取保留原文定位与返回哈希。动态会话投影/当时全部外部连接器原文不可能自动复原，明确显示缺口。
- 默认 365 天/2 GiB、每 60 秒读取，版本 1、debugFeedback=false，可编辑 config.json。容量含目录中的导出与页面，SQLite 页有小量分配开销；到上限停采，不静默淘汰。保留期限通过显式 prune 执行，不自动清理；保留仍被未过期样本引用的原文。
- ForwardAll 继续真实转交；shadow 试验重复身份、刷新时间噪声、无实质变化。用户说明/计时/错误/过期保护不省略；只显示候选“可省唤醒”。已被工具证明唤醒却没动作，与 shadow 建议将来不唤醒分开。
- 三组能力输入：BC 原生+同一用户意图；再加入已采集/获准的连接器源；再加入归档推断与已存 habit/preference/personalization 说明（保留原 assertion/basis）。分组保留来源与相同批次/读取窗，报告覆盖差异。当前没有独立习惯库，第三组如无材料就明确缺失；这不是三次模型建议的质量评测，也不会回放时补调连接器。
- 本地 offline HTML 查看页、JSON 全量导出、纯规则 replay。成本/tokens、漏报误报、有用程度及注意力时间未知就保留 null，不能用沉默当认可。调试反馈无通知能力。

来源分类口径：BC 原生指事项与共享计时；Apple 日历/健康/电脑活动等即使由 BC 采集，保留外部源类别以及采集器身份。用户陈述和代理推断不提升为 BC 确认事实。

## 试用、查看、停止与回滚

App 和 Dots 用法不变：自然问下一步，明确说开始/暂停/继续/结束。研究记录器额外在本机运行，不要求手工写日志。

本地目录：`~/Library/Application Support/BetterCalendarResearch`（不入 Git、不上传新服务）。用 Node 22.13+，实际 Node26 已核验：

```sh
node StateBridge/tools/research-recorder.mjs once
node StateBridge/tools/research-recorder.mjs watch
node StateBridge/tools/research-recorder.mjs view
node StateBridge/tools/research-recorder.mjs stats
node StateBridge/tools/research-recorder.mjs export '/选择的本地路径/研究导出.json'
node StateBridge/tools/research-recorder.mjs replay minute_事件编号
node StateBridge/tools/research-recorder.mjs stop
```

`view` 生成目录下 review.html，可直接打开；SQLite snapshots 是完整原文，calls/runs 以哈希和身份串联。export 只写本地、目标存在就拒绝覆盖；replay 没有网络和执行能力。STOP 下次循环停止；恢复时移走 STOP 后再运行 watch。每次启动读取 config.json；改配置需重启。当前会话后台运行，不保证电脑重启自动恢复。

显式 `prune` 会按 config 的 retentionDays 清理过期本地样本和不再引用的原文，先导出需要保留的资料；不会删除 BC 原库或云端计时。没有自动执行该清理。

回滚：先 stop 本地研究记录器，保留目录和导出；部署上一已保存私有服务 v16 可恢复原路径（新增研究表保留，不反向删除 schema）。或者只撤回本轮代码并部署跟进版本。只停止此记录器不会停止 BC 原生采集、临时 pool 发布或计时。不能宽泛杀 BetterCalendar 进程。

## 本轮验收边界

已验证：42 项 SQLite/纯规则/本地持久化检查通过（26 既有，16 本轮）。涵盖重复投递、旧状态/乱序、分页、重启、断线补传、实际计时成功但响应/日志丢失、旧 revision 冲突、设备撤权、结果持久化失败、shadow 与真实路径分离、回放零联网/写入、来源对照、凭据过滤与离线查看/导出。

未验证：这些测试不是生产设备端到端可靠性；未证明用户真的看到提醒、设备应用每条计时、所有 iPhone 后台分钟持续覆盖、Dots 每批都用新研究回执、实际模型费用、真实注意力成本或生活改善。

待开发：外部连接器完整调用捕获（先解决本地留存与批准边界）；固定输入上的同模型三组 reasoning 回放/盲评；模型成本真实回执；设备应用确认；强提醒原生 adapter/权限与事项编辑。全覆盖/全旧史迁移/复杂冲突继续后置。

需 Jason 决策：本轮无阻塞决策；默认一年/2GiB可改。未来启用强提醒时再选择具体范围、渠道和解除方式；允许响铃不能自动允许锁应用。新服务/外发原始资料仍需单独批准。研究产品收益仍由真实体验判断。


## 生产部署与真实样本（2026-10-12）

既有私有 Site v19 于 21:52:09 UTC 部署成功，来源提交 `e3c28316cc424947058d806cf270d147f0133b78`。项目 `appgprj_6ac3bb816d3c8191949bac68d45a62bc`；version `appgprj_6ac3bb816d3c8191949bac68d45a62bc~appgver_87ff2a9d7c848191807c61a71194d565`；deployment `appgdep_6acd567fe92c81918f3cd44dfebede38`。访问仍为 Jason 私有，未增加第三方服务或扩大访问。TypeScript 与 Site build 通过。服务端源码和主仓库的 server 文件一致；本轮未改原生 App，不发 TestFlight。

真实样本 `minute_29864028`：

1. 21:48 UTC 生成实际状态变化批次，范围 165188–165198，去重后有 7 条变化；没有创建假的计时或测试事项。
2. Dots 实际调用了 instructions、状态元数据、变化正文及当前状态正文。变化调用 `research_110c7708-d648-4fdf-91de-43d079d7a413` 从 165187 读到 165198，hasMore=false；状态正文调用 `research_9a868d78-499d-458f-b7af-d2f66e651332`。
3. Dots 将“本批不足以确认任务结束”保存为 inference/medium，关联两条实际读取证据，写明传感器覆盖不足及旧观察补传的替代解释。没有将代理判断覆盖为用户确认事实。
4. 权限/操作结果为 silent/not_requested、operation=none；没有手机通知、没有计时变化。完整读取与结果事务校验通过。处理结果保存失败的先前尝试没有被追认为成功。
5. 21:54:15.925 UTC 保存 `result_dots-minute_29864028-result-1`，保存工具调用 `research_56406cb6-fcd9-4b96-ae40-095d1bac8865`；本地 calls 第 278 条已下载同一 batch_result、结论及引用。查看页按同一批次串联原文和结果。后续两批亦保存了真实静默回执，但不以三个样本证明长期稳定。
6. 本地 replay 对同一问题/窗口构建三组输入，BC-only 0、已采集连接器 7、个性化 7；本批没有额外习惯材料，不能声称个性化带来收益。network=false、sideEffects=false。已调用模型后未行动，与 shadow 的未来节省候选分别保留；没有宣布已节省费用。

首次本地读取曾遇空事件游标 HTTP 400，错误被保存、游标没有假推进；已修复并回归验证，后续继续读取。Dots 工具发现缓存问题通过专用兼容路径解决；未卸载插件、扩大权限或伪造新工具调用。

21:55:36 UTC 本地录制器实查存活，3 个批次、310 条研究日志，约 1.92 MB；会话 PID 83250，日志 recorder-session.log。这些是该时点快照，不是全天覆盖承诺。原临时 pool 发布器 PID 65901 保持独立运行；研究记录器没有原生写入能力。

本机资料入口：

- `~/Library/Application Support/BetterCalendarResearch/review.html`：离线查看页。
- 同目录 `sample-replay.json`：纯规则对照结果；`stage-one-export.json`：本次本地原文导出。
- 同目录 `research.sqlite`：持续采集原文/回执；config.json 可调期限、容量和本地调试反馈。

上述原始资料不进入源码仓库，不复制到新云服务。查看页是手动生成的静态快照，重新运行 view 更新；持续采集不代表页面自动刷新。日常每批使用新回执、设备实际应用、成本和生活收益继续保持未验证。


### 22:02 UTC 持续运行检查与汇总增量

- 本轮没有再向 Dots 发送测试消息。后续真实批次 minute_29864037 和 minute_29864039 分别于22:00:03.327和22:00:19.033 UTC保存研究回执；本地已下载calls#411/#426，均有实际读取callIds、1条结论、silent/not_requested和operation=none。先前“接收但尚无结果”如实呈现，后来按回执转成已记录，不以接收HTTP宣称处理成功。
- 22:01:26本地5批已保存结果；22:02:04新增第6批，仍为待回执。不能把某一时点pending=0当持续清空保证。Mac状态/目录在21:58继续更新，两个后台进程实查存活；手机最新心跳21:48已stale，位置/家庭数据也有缺口，仍不宣称手机每分钟后台持续覆盖。
- 新stats离线汇总同时呈现已保存结果、处理后无动作、尚无结果、shadow未来可省唤醒；后者不是真实节约。更正按一批当前结果计一次，原始证据保留。已增加聚焦测试，累计42/42通过。
- 延迟口径单独写清：服务端批次createdAt→第一次结果保存，另列最新纠正时间差；不是原始事情发生→用户看到。上述两个后续样本为167.815秒及63.323秒；早期三批包含工具缓存和人工核验过程，不能拿来声称常态响应速度。
- 查看页和JSON导出加入这份汇总；sample-summary.json是当前本地快照。无需新部署、无App修改、无新增通知或写入权限。费用、注意力时间、实际帮助、用户认可仍为未知。原始资料与页仍只在本机。

### Shadow v2：正常在线刷新不当作异常（2026-10-13 UTC）

实际检查发现：36批已归档样本、35批完整静默回执；没有通知/计时操作回执。v1旁路规则把device.status的availability=online落入未知/异常分支，不论内容是否变化均保护，导致正常心跳无法参与刷新噪声实验。v2仅对明确device.status的online放行正常内容对照；版本/平台/内容变化仍算实质变化，offline/未知异常、stale、用户意图和计时仍保护。ForwardAll真实转交不改，不触发通知或计时。没有拿35次无动作当成应省掉35次唤醒。

每条新判断记录version=2；旧归档判断保持原样。回放新增recordedShadow、replayShadowVersion和policyChanged，明确分开当时规则与现在规则；汇总分列shadowPolicyVersions，避免把新算法冒充旧样本的实际历史决定。44/44检查通过，涵盖正常在线刷新、版本变化、离线/过期/用户意图、不借用其他来源的online状态、不同规则回放不重写旧样本且无网络或写入。

stop命令只报告stopRequested，真实停止需由watch的stopped回执或进程消失核验；不再把请求停止当作已经停止。研究录制器按原游标安全重启以加载新模块，不停止BC、临时pool或Dots。此批只改本地实验，不另部署云端v19或发布新App。手机用户明确尚未更新/打开，正在更新164；旧心跳不能推断新版采集失败。原型真实计时/一天收益仍须真实使用证据，不能伪造样本补齐。

00:05 UTC运行核验：原watch实际stopped回执00:04:22.688、PID83250消失后才恢复，当前95953实查存活；00:04:57续到37批/4177研究日志，shadowPolicyVersions={1:36,2:1}，没有重写前36批。离线查看页已刷新。MCP实读手机/Mac164心跳current；两端pool各25事项/9阶段、完整分页、同内容hash、无设备差异。详见bc-release-164.md及docs/evidence/dual-device-164.json。
