# 共享计时改由 iCloud 承载（W5 设计稿，2026-10-18）

> 对应 SPEC §19.5 D1/D2、§19.8（StateBridge 冻结）、§19.10；历史决策见 §15.4.3（0.65.6/163 统一计时）与 §18 D 组。
> 状态：设计 + 默认关闭的实现（开关 `sharedTimer.icloud.enabled`，默认关）。开关关闭时行为与改动前完全一致。

## 1. 现状：计时真相今天在哪里

TestFlight 版里「点按钮」和「对话里说一句」用的是同一份计时（canonical timing）。它的结构是：

```
按钮 / 菜单栏 / Live Activity / 执行面板
        │ 只读显示 + 发命令
        ▼
BridgeTaskViewModel（每台设备一份）
  · 本机文件 task-commands-v1.json：最后一次读到的状态（显示缓存）+ 待发送命令队列
  · 命令带 commandId（幂等）、expectedRevision（版本核对）、occurredAt
        │ BridgeTaskServing 协议：readTasks / submitTask
        ▼
StateBridgeClient → StateBridge 云端服务（D1 数据库 sessions / commands 表）  ← 唯一真相
```

几个关键事实：

1. **真相在 StateBridge 的 D1 里**。设备只保存显示缓存和待发送命令；状态机（开始/暂停/继续/结束、版本 +1、幂等回执、409 冲突）全在服务端 `taskCommand` 里执行。
2. **StateBridge 已冻结**（§19.8 G「Dots 相关的整条线：云端状态服务」），协调者已无法再部署它。只要它的服务还活着，计时就能用；它一旦失效或凭据过期，Jason 日用的计时就会整体失灵，而且我们修不了服务端。
3. **ExecutionViewModel 只通过 `BridgeTaskViewModel` 用这份计时**（`usesCanonicalTiming` 为真时，开始/暂停/结束都转给它）；菜单栏 `MenuBarController`、执行面板 `BridgeTaskPanel`、iPhone Live Activity（`syncCanonicalPresentation`）也都只读它。也就是说，**换掉真相的位置只需要换掉 `BridgeTaskServing` 的实现**，上层不用动。
4. `FocusFollow` 已经有一条 iCloud 私有库通道（记录类型 `FocusRunState` + `CKQuerySubscription` 静默推送），但它是**单记录覆盖写**的「跟随显示」通道：没有版本号、没有幂等、没有历史，最后写的人赢，12 分钟无更新就视为过期。它适合当「唤醒另一端」的信号，不适合当真相。
5. 多端审批（§19 B 组）已经在 iCloud 私有库里跑通了「条件保存、首个决定生效」（`ConflictCheckedProposalTransport` + `CloudKitProposalStore`，zone `BCApprovals`），真机验证过，CloudKit schema 已部署正式环境。这是可以直接照搬的并发模式。

## 2. 为什么要换、为什么这样换

- **为什么换**：计时是 Jason 每天都在用的核心功能，真相不能放在一个已冻结、无法再部署的服务上。
- **为什么不直接用 FocusRunState**：它是「最后写的人赢」的单记录，两台设备同时操作会互相覆盖；没有 commandId，断网重试会重复执行；没有历史。改造它等于重写，还会破坏现有跟随功能。
- **为什么保留 `BridgeTaskServing` 这层接口**：现有的本机队列、幂等重试、409 不覆盖、显示时钟对齐、过期判定、Live Activity 投影，都经过 163–182 多个版本和几十个单测打磨。保留这层，新实现只负责「把命令落到 iCloud」，上层零改动，风险最小；W1 将来通过 ExecutionViewModel 做的计时提案执行器也自动适用两种后端。
- **核心思路**：iCloud 没有服务端代码可跑，所以把服务端的状态机（`taskCommand`）**原样搬到设备上做成纯函数**，再用 CloudKit 的「服务器版本未变才保存」（`.ifServerRecordUnchanged`）保证多端只有一个写入能成功——这正是 D1 里 `UPDATE ... WHERE revision=?` 做的事。

## 3. iCloud 里的数据结构

### 3.1 位置

- 容器：`iCloud.com.jason.BetterCalendar`，**私有库**。
- 独立 zone：`BCSharedTimer`（代码自动创建）。不与 `BCApprovals` 混用：推送不互相淹没，回滚时也互不影响。

### 3.2 记录类型 `BCTimerSession`（一次计时一条记录）

| 字段 | 类型 | 说明 |
|---|---|---|
| recordName | — | 会话 ID：`timer_` + SHA256(开始命令的 commandId) 前 32 位十六进制。由开始命令确定性推出，所以同一条开始命令在任何设备重试都落到同一条记录，天然幂等。前缀与旧 StateBridge 的 `task_` 区分。 |
| `payload` | String | **唯一真相**：整份会话 JSON（见 3.3），包含事件历史。 |
| `status` | String | 镜像：running / paused / finished（便于排查与将来做推送文案；不作为判断依据）。 |
| `revision` | Int64 | 镜像：版本号。 |
| `title` | String | 镜像。 |
| `updatedAt` | Date | 镜像：最后一次状态变化的发生时间。 |
| `startedAt` | Date | 镜像。 |
| `mode` | String | 镜像：light / pomodoro。 |
| `experiment` | Int64 | 镜像：1 = 测试计时。 |

不需要任何查询索引：读取一律走 zone 增量变更（`recordZoneChanges`），与 `CloudKitProposalStore` 相同（开发环境不会自动建索引，查询会直接失败）。

### 3.3 payload（`SharedTimerSession`，schemaVersion = 1）

```
id, title, status, startedAt, activeSince?, elapsedMs（已累计、不含当前运行段）,
updatedAt, revision, provenance = "user", relatedRecordId?, origin, lastCommandId,
mode, focusMinutes?, experiment,
events: [SharedTimerEvent]   // 事件历史，按发生顺序
```

`SharedTimerEvent`：`commandId, action（start/pause/resume/finish）, occurredAt, recordedAt, deviceId, revisionAfter, fingerprint`。

- **会话 + 事件历史放在同一条记录里**：一次操作只写一条记录，条件保存就是原子的，不需要跨记录事务；幂等判断（这个 commandId 是否已执行）也只看这条记录。一次计时通常几到几十个事件，远低于 CloudKit 单记录 1 MB 上限；设硬上限 500 个事件，超过拒绝（提示结束后重新开始），不会静默截断。
- `fingerprint`：命令内容的 SHA256（动作、会话、预期版本、标题、发生时间、模式等）。同一 commandId 再次到达时，内容一致 → 返回原回执；内容不同 → 拒绝（与服务端「commandId 不能复用于不同命令」一致）。
- 已结束的会话**保留**在 zone 里作为历史（不删除），读取「当前计时」时过滤掉。

### 3.4 状态机（与 StateBridge `taskCommand` 逐条对齐）

| 规则 | StateBridge 服务端 | iCloud 设备端 |
|---|---|---|
| 只接受用户明确表达 | provenance 必须 user | 同 |
| 模式/番茄时长/实验标记只在开始时指定，之后不可变 | validateTaskMode | 同（`validMode`） |
| 番茄 1–240 分钟；轻计时不能带时长 | 同 | 同 |
| 动作不能在未来（> 2 分钟） | 同 | 同 |
| pause/resume/finish 必须带 expectedRevision 且等于当前版本 | 409 | 同（409 类拒绝） |
| 暂停只能对运行中，继续只能对已暂停，已结束不能再动 | 409 | 同 |
| 动作早于上一状态 | 拒绝 | **差异**：iCloud 没有服务端时钟，两台设备时钟可能差一两秒；早于上一状态 5 分钟以内的，按上一状态时间记（夹紧，不倒流）；超过 5 分钟才拒绝。 |
| 暂停冻结 | elapsed += occurredAt − activeSince，activeSince = null | 同；暂停期间显示不增长 |
| 番茄到时 | 不改任何存储；只是显示从倒计时转为累计 | 同（`BridgeTaskSession.presentation` 原样复用）：静默转正计时，从已工作时长继续，不归零、不结束、不休息、不响铃、不完成事项 |
| 结束计时 ≠ 完成事项 | 只把会话标 finished | 同；不写 SwiftData 执行记录、不写蓝色实际、不标计划块完成 |
| 离线 / 闲置不自动暂停 | 同 | 同（没有任何自动暂停逻辑） |

### 3.5 读取（`readTasks`）

- 增量拉 zone 变更 → 解码 → 过滤掉 finished → 按 startedAt、id 排序 → 最多 100 条（多于 100 标 hasMore）。
- `readAt` 用本机时钟，并保证单调不减（上一次 readAt 与现在取大），满足 ViewModel「读到的状态不能比上次旧」的校验。运行中会话的 `elapsedMs` = 已累计 + (readAt − activeSince)，与服务端 `sessionView` 同义。
- 损坏的记录（解不出 payload、ID 不符）跳过并 `DevLog.error`，不让一条坏记录拖垮整个计时显示。

## 4. 多端并发与冲突

沿用 `ConflictCheckedProposalTransport` 的乐观并发：

```
for 最多 4 次:
    读这条会话的最新版本（同时记住它的 CloudKit 版本标记）
    用纯函数状态机判断这条命令：
        已执行过（commandId 在事件历史里）→ 直接返回原回执（幂等）
        版本不符 / 状态不允许 → 拒绝（409 类）：本机命令标「需要你看一下」，绝不覆盖
        合法 → 生成新版本
    以「服务器版本未变」为条件保存
        成功 → 返回回执
        服务器版本已变 → 拿服务器最新版本回到循环顶部重新判断
```

两台设备同时对同一版本按「暂停」：只有一个条件保存成功；另一个拿到服务器新版本后，状态机发现 expectedRevision 已过期 → 拒绝，本机显示「另一端已改变状态，未覆盖它的操作」，与今天 StateBridge 的 409 体验一致。

「开始」不会冲突：不同设备的开始命令 commandId 不同，会话 ID 也不同，各自是一条新记录（与服务端一致：允许多个并行计时，`primary` 选运行中的那条显示）。同一条开始命令重试，因为会话 ID 由 commandId 推出，第二次保存会撞上已存在的记录 → 拿到服务器记录 → 状态机发现 commandId 已执行 → 返回原回执。

## 5. 离线与恢复

完全复用 ViewModel 现有机制，只是换一份本机文件：

- 命令先写本机队列（iCloud 模式用独立文件 `Application Support/SharedTimer/icloud-timer-v1.json`，**不碰旧的 `DotStateBridge/task-commands-v1.json`**），再尝试保存到 iCloud。
- 网络失败 / iCloud 限流 / 账户暂不可用 = 暂时错误：命令留在队列，显示「计时同步暂未完成；保留最后状态与 N 条待同步操作」，下次刷新用**原 commandId** 重试。
- 「已经保存到 iCloud 但回包丢了」：重试时状态机在事件历史里找到这个 commandId → 返回原回执，不会执行两次。
- 状态机拒绝（版本过期、状态不允许、内容不合法）= 永久错误：标「需要你看一下」，保留请求，不自动重放、不覆盖新状态。
- 离线时不自动暂停，也不声称云端已执行；已运行的计时按本机时钟继续显示，超过 60 秒没拿到新状态显示「待同步」（现有 isStale / presentationValidUntil 逻辑）。

## 6. 各端显示如何跟随

- 执行面板、Mac 菜单栏标题、iPhone 锁屏/灵动岛：**代码不变**，它们只读 `BridgeTaskViewModel`，后端换成 iCloud 后自动跟随。
- 唤醒：
  1. 新 zone 订阅 `bc-shared-timer-zone-sub`（`CKRecordZoneSubscription`，静默推送）：另一端保存后，本机收到推送 → `bridgeTasks.refresh(allowCommands: false)`。双端 AppDelegate 增加一条推送分支。
  2. 轮询兜底：iCloud 模式下活动/有待发命令时每 10 秒、空闲每 30 秒（StateBridge 模式维持原来的 5 / 15 秒不变）。zone 增量拉取在没有变化时很轻。
  3. 现有 Mac → `FocusRunState` 投影（FocusFollow 开着时）照旧保留，作为额外的唤醒信号；iPhone 收到后调用的就是同一个 `bridgeTasks.refresh`。
- 静默推送会被系统限流（§19.10 已核实），所以「另一端几秒内看到」是尽力而为；轮询保证最终一致。

## 7. 与旧 StateBridge 计时的过渡

原则：**不丢旧记录、绝不双写、正在进行的会话不被腰斩。**

1. **开关只在启动时生效**。开关是本机 UserDefaults `sharedTimer.icloud.enabled`（默认关，不随 SettingsSync 跨端同步——每台设备自己决定）。App 启动时读一次，决定这次运行用哪个后端；运行中切换只记录「下次启动生效」。这样不会出现一个 ViewModel 前半段读 StateBridge、后半段读 iCloud 的混合状态。
2. **同一时刻只有一个后端**：组装点按启动决定只创建一种 service + 对应的本机文件。iCloud 模式下不调用 StateBridge 计时接口，StateBridge 模式下不碰 `BCSharedTimer`。不存在双写。
3. **旧记录只读保留**：StateBridge D1 里的会话、命令回执、历史全部不动；旧本机文件 `task-commands-v1.json` 也不动（iCloud 模式根本不打开它写）。回滚时它原样可用。
4. **正在进行的会话怎么切**——切换闸门（两道）：
   - 打开开关时：如果当前（旧）通道里还有非测试的进行中计时，或还有未发送的命令，**拒绝切换**并说明：「旧通道还有正在计时的『X』，先结束它再切换（旧记录保留在原处）」。
   - 启动时：即使开关已打开，如果旧本机文件里仍有非测试的进行中会话或待发送命令（例如打开开关后又在旧通道开始了一个计时），**本次启动继续用旧通道**，并在面板与 DevLog 里说明「切换推迟」。
   - 测试计时（experiment）不阻挡切换：它们是合成数据，留在旧通道原处。
   - 不做自动「接续」（把旧会话的已用时长搬到 iCloud 新会话）：那需要同时结束旧会话、创建新会话，两边无法原子完成，失败时会出现一份计时两处记录。宁可让 Jason 结束旧计时再切。
5. **Dots / MCP 的远程计时命令**（`NativeRemoteExecutor` 里 `kind == "timer"`，经 StateBridge `native/timer`）：iCloud 模式下明确拒绝，提示「共享计时已改用 iCloud，旧通道的计时命令不再执行」。否则它会在 StateBridge 里创建一个本机看不见的计时。Dots 整条线已冻结，智能体的计时操作将由 W1 的提案执行器经 ExecutionViewModel 走（自动适用 iCloud）。
6. 两台设备需要各自打开开关。过渡期如果一台在 iCloud、一台在旧通道，它们看到的是两份不同的计时——面板顶部会写明「计时记在：iCloud / 旧通道（StateBridge）」，便于发现。

## 8. 回滚

- **软回滚**：关掉开关（同样有闸门：iCloud 里还有进行中的计时时拒绝，先结束再切回）→ 重启 App → 回到旧通道，旧本机文件与 D1 原样可用。
- **硬回滚**（开发者）：`defaults delete com.jason.BetterCalendar sharedTimer.icloud.enabled`，或直接回退这批提交。开关默认关，代码回退不影响已有数据。
- iCloud 里的 `BCSharedTimer` 记录不删除（历史保留），回滚后只是不再读取；以后重新打开开关时继续可用。
- CloudKit schema 只做加法（新 zone、新记录类型、新订阅），不改 `FocusRunState`、`BCProposal` 等任何现有类型。

## 9. 需要的 CloudKit 变更（由协调者安排，不由本线操作）

1. 记录类型 `BCTimerSession`，字段：`payload`(String)、`status`(String)、`revision`(Int64)、`title`(String)、`updatedAt`(Date/Time)、`startedAt`(Date/Time)、`mode`(String)、`experiment`(Int64)。无需索引（不做查询）。
2. zone `BCSharedTimer` 由代码创建，zone 订阅 `bc-shared-timer-zone-sub`（`CKRecordZoneSubscription`，与 `bc-approvals-zone-sub` 同类，已证明在正式环境可直接创建，不需要 schema 订阅类型）。
3. 做法：在 Development 环境用 DEBUG 构建打开开关并做一次开始/结束（或点 DEBUG 按钮「在 Development 建出计时 schema」写一条非活动探针记录），然后在 CloudKit Console「Deploy Schema Changes」到 Production。**未部署前，TestFlight 版打开开关会报错（可见），但不会影响旧通道。**

## 10. 测试（`BetterCalendarTests/SharedTimerICloudTests.swift`）

- payload 编解码往返、旧字段可选、损坏记录拒绝；会话 ID 由 commandId 确定性推出。
- 状态机：开始/暂停/继续/结束、版本 +1、模式不可变、未来时间拒绝、时钟夹紧、事件上限。
- 暂停冻结：暂停后显示不增长；继续后从冻结值接着走。
- 番茄转正计时：到时后 `countingDown == false`，累计时长继续增长，状态仍是 running，没有完成/结束。
- 并发：两端同版本同时暂停只有一个成功、另一个标需复核且不覆盖；陈旧缓存的命令被拒；读写之间插入另一端写入（条件保存冲突）后正确重判。
- 离线重放：网络失败保留命令、恢复后原 commandId 重试；「已保存但回包丢失」重试不重复执行。
- 开关关闭零变化：默认值为关；启动决定为旧通道且不触碰 iCloud 工厂；旧通道 ViewModel 的轮询间隔、文案、409 处理与改动前一致；现有 `BridgeTaskTests`、`NativeRemoteExecutionTests` 全部原样通过。
- 切换闸门：旧通道有进行中计时/待发命令时拒绝；测试计时不阻挡；启动时推迟切换。

## 11. 本批未做 / 留待后续

- 旧 StateBridge 历史迁移到 iCloud（只读保留，不迁移；需要时另立批次）。
- 自动接续正在进行的旧会话（见 7.4 理由）。
- 历史查询 UI / 智能体读取 iCloud 计时历史（W2 的 `AgentBridgeContext` 读「当前计时」时可直接读 `bridgeTasks`，两种后端通用）。
- 真机验证：双端开始/暂停/继续/结束、推送到达延迟、锁屏显示，需要 schema 部署后由 Jason 在 TestFlight 版里测。
