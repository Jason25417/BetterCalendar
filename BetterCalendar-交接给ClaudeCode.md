# BetterCalendar 日程 App — 交接给 Claude Code 开发

> 这是给 **Claude Code** 的冷启动上手文档（它没有 Cowork 这边的对话与记忆，所以本文自带必要上下文）。
> 配套**功能 SPEC**：`日程软件功能设计.md`（同目录），功能细节以那份为准。
> 建议：把本文（或其精简版）放到 BetterCalendar 工程根目录，命名为 `CLAUDE.md`，Claude Code 会在该目录启动时自动加载。

---

## 0. 一分钟摘要

要做第 4 个原生 App **BetterCalendar**：macOS + iOS 的日程管理工具。
核心闭环 = **自然语言说 → 结构化排程 → 写 Apple 日历/提醒事项 → 番茄钟执行 → 晚间「计划 vs 实际」对比 → 晨间按实际开工时间顺延**。
签名功能 = 计划 vs 实际对比（前一晚排「预先设计」绿色日历，当晚回填「实际」蓝色日历，App 算完成度/偏差）。
当前进度：**构想 + SPEC 已成形，工程尚未创建**。下一步是 M0 骨架（见 §8）。

---

## 1. 我是谁 & 协作约定（重要）

- 我是**原生开发初学者**，这是第一个真实项目。请**中文**沟通，**简洁直接、少冗余**。
- 步骤要**非常具体**，包含"在 Xcode 里点哪里 / 在哪个文件写什么"。
- 工作节奏：**先把最小骨架编译跑通，再逐能力扩展**。先骨架 → 逐能力打通 → UI 成形 → 打磨 → 发布。
- 每个新能力的做法：**先"协议 + 最小实现 + 一个验证 demo"，再接 UI**。
- **动手前先核实相关 Apple API 现状**（容易随系统版本变化）——本文 §6 给了已核实结论作为起点，但实现时请复核。

---

## 2. 四个 App 全景（本次交接对象 = BetterCalendar）

| App | 平台 | 状态 | 说明 |
|---|---|---|---|
| **EasyReminder**（工程名 `MyApp`） | macOS | 基本完成 | ICS(VTODO) ↔ 系统「提醒事项」双向导入导出。**ICS / 提醒事项能力可被 BetterCalendar 复用** |
| **BetterTranscribe** | macOS | 开发中 | 系统音频+麦克风录音→转录→翻译。**同一套分层架构 + Foundation Models 使用经验可参考** |
| **BetterCalendar**（本次） | macOS + iOS | 仅 SPEC | 本文档的主角 |
| 手记/日记 App | — | 规划中 | 暂不动 |

---

## 3. 路径与连接（把这些接进 Claude Code 会话）★

### 3.1 已确认存在（本套文档所在文件夹）
```
~/Developer/App Development/BetterCalendar_Claude/
├── 日程软件功能设计.md          ← BetterCalendar 功能 SPEC（活文档，开发时实时勾选）
├── BetterCalendar-交接给ClaudeCode.md  ← 本文件
├── BetterCalendar开发项目.ics          ← 项目本身的提醒事项（VTODO）
└── 录音软件功能设计.md          ← BetterTranscribe SPEC（参考）
```

### 3.2 来自项目记忆、**请你本人确认实际路径**（Cowork 这边没连、未核验）
```
~/Developer/App Development/
├── MyApp/            ← EasyReminder 工程（复用 ICS/提醒事项代码）
├── BetterTranscribe/ ← 架构参考
└── BetterCalendar/          ← 【还不存在，待新建】BetterCalendar 工程建议放这里
```
> 注：以上 `App Development` 下的路径来自旧会话记忆（约 2026-06-26），请在 Finder 里确认无误。

### 3.3 建议给 Claude Code 会话连接的目录
1. **主工作目录** = 新建的 `~/Developer/App Development/BetterCalendar/`（工程建好后在此启动 Claude Code）。
2. **加 SPEC 文档目录**：`~/Developer/App Development/BetterCalendar_Claude/`（读功能 SPEC + 本交接文档）。
3. **加参考工程**：`~/Developer/App Development/MyApp/`（EasyReminder，复用 ICS/提醒事项）。
4. （可选）`~/Developer/App Development/BetterTranscribe/`（架构 + Foundation Models 参考）。

在 Claude Code 里加目录：启动时 `claude --add-dir <路径> --add-dir <路径>`，或会话中用 `/add-dir <路径>`。
（路径含空格要加引号，如 `"~/Developer/App Development/BetterCalendar_Claude"`。）

---

## 4. BetterCalendar 是什么（细节见 SPEC）

核心闭环（SPEC §2 有图）：
```
前一晚：自然语言说出明天 → 生成结构化计划 → 写【预先设计】绿色日历 + 关键任务进提醒事项
当天早上：点「开始今天」→ 按实际开工时间把弹性块顺延/提前（固定块不动）
当天：照着做，用番茄钟专注（iOS 可屏蔽分心 App）
当晚：写【实际】蓝色日历 → 和【预先设计】对比完成度
```
完整功能需求、用户流程、数据模型见 `日程软件功能设计.md`。

---

## 5. 架构约定（必须遵守）

沿用既有 macOS/iOS SwiftUI 分层：**App 组装点 / Models / Services（协议+实现）/ Features（View+ViewModel）**。
- 界面**不直接调系统 API**；上层只依赖**协议**、不依赖具体实现。
- 依赖在**唯一组装点**创建并注入。
- 跨平台：核心闭环（解析/日历/对比/re-flow）两端通用；按平台注入不同 `FocusService` 实现（见 §6 屏蔽约束）。
- 数据：**SwiftData + CloudKit**，只存元数据 + 外部事件 ID；真正的事件存系统日历。

计划中的 Services 协议（详见 SPEC §7）：
`ScheduleParsing` / `CalendarStore` / `ICSExporting` / `ReminderStore` / `PlanComparing` / `RescheduleService` / `FocusService` / `Persistence`。

---

## 6. 已核实的关键 Apple API 约束（核实于 2026-06，实现前请复核）

1. **EventKit（日历）**：要"读回事件做对比"和"新建带色日历"，必须 **full access**（`requestFullAccessToEvents` + Info.plist `NSCalendarsFullAccessUsageDescription`）。iOS 17+ 的 write-only 权限**不能读事件、不能建日历**，满足不了本 App。`EKCalendar` 可设 `title` + `cgColor`（绿/蓝两个日历），需指定可写 `source`（iCloud 或本地）。

2. **Screen Time / 屏蔽分心 App（FamilyControls / ManagedSettings / DeviceActivity）**：需 `com.apple.developer.family-controls` **特殊 entitlement，须向 Apple 申请，上架前必须获批**。⚠️ **macOS 上基本不可用**（原生/Catalyst 受沙盒限制，授权与 picker 运行时失败）。结论：**硬屏蔽 App 只 iOS 可行**；**macOS 番茄钟降级为纯计时 + 提示 + 引导系统专注模式**。`FocusService` 因此按平台注入不同实现。

3. **Foundation Models（端侧 LLM，做自然语言解析）**：iOS 26 / macOS 26+ 提供端侧 ~3B 模型；`@Generable` 宏可直接产出**类型安全结构化输出**（"自然语言 → `PlanBlock[]`"一步到位）。需设备支持 Apple Intelligence 且已开启；不支持时 `SystemLanguageModel.default.availability` 返回不可用 → **必须有降级**（云端填 key / 手动排）。

4. **提醒事项**：子任务/标签/旗标/附件/紧急提醒等属私有 **ReminderKit**，EventKit **不可写**（可解析不可写）。**只写标准 VTODO 字段**（标题/备注/截止/提醒）。

---

## 7. 可复用资产

- **EasyReminder（MyApp）**：已实现 ICS(VTODO) ↔ 提醒事项 双向。BetterCalendar 的 `ICSExporting`（计划块→ICS 的 VEVENT）和 `ReminderStore`（写 VTODO）可直接借鉴其代码与踩坑经验。
- **BetterTranscribe**：同一套分层架构骨架；Foundation Models（本地大模型）调用经验可参考 `ScheduleParsing` 的实现。

---

## 8. 建议的起步：M0 骨架（先求编译跑通）

1. **新建工程**（Xcode → File → New → Project → **Multiplatform → App**）：
   - 名称建议 `BetterCalendar`；Interface = SwiftUI；Language = Swift；**勾选 Storage = SwiftData**（或后续手动加）。
   - bundle id 建议 `com.jason.BetterCalendar`（沿用 `com.jason.*` 命名）。
   - 部署目标：iOS 26 / macOS 26（Foundation Models 需要）。
2. **建分层目录**：`App/`（组装点）、`Models/`、`Services/`（每个能力一个协议 + 实现）、`Features/`（View+ViewModel）。
3. **定数据模型**（SwiftData，见 SPEC §7.2）：`PlanDay` / `PlanBlock` / `CompletionLink` / `PomodoroSession` / `AppSettings`。
4. **建组装点**：先给每个 Service 协议写**空实现/桩**，注入到 UI；一个最简首页能跑起来。
5. **开 App Sandbox + Hardened Runtime**（发布需要）。
6. 目标：**此步只要能编译、能启动、空界面在两端跑通**，不接任何系统 API。
7. 之后按 SPEC §10 里程碑推进：M1 自然语言解析 → M2 写日历/ICS → M3 提醒事项 → M4 对比 → M5 re-flow → M6 番茄钟 → M7 iCloud → M8 发布。

> 每完成一项，回 `日程软件功能设计.md` 把对应 `[ ]` 改成 `[x]`、更新 §0 进度总览表。

---

## 9. 已拍板的决策（D1–D4，2026-06-28 定）

- **D1 自然语言解析引擎** = 端侧 Foundation Models 优先（`@Generable` 直出结构化）+ 云端 `ScheduleParsing` 协议占位（不实现）。
- **D2 写日历方式** = EventKit 直写绿/蓝两个日历为主 + ICS 作可移植导出/分享。
- **D3 起步平台** = macOS 先把核心闭环跑通（Multiplatform 工程；iOS 的 Screen Time 屏蔽后做）。
- **D4 App 名字** = BetterCalendar（bundle `com.jason.BetterCalendar`）。

---

## 10. 发布约定

- 已注册 Apple Developer Program（审核中，已付费）。
- 路线：本地独立 `.app` → Developer ID 签名 + 公证（网络分发）→ Mac App Store；iOS 走 App Store。
- 工程开 **App Sandbox + Hardened Runtime**。
- ⚠️ iOS 番茄钟屏蔽需**提前申请 Family Controls entitlement**（审批有周期，别拖到上架前才弄）。

---

## 附：环境信息（截至 2026-06-27）
- 平台目标：iOS 26 / macOS 26（Foundation Models、Screen Time 新 API 都依赖新系统）。
- 开发语言/框架：Swift + SwiftUI + SwiftData + EventKit + FoundationModels +（iOS）FamilyControls/ManagedSettings/DeviceActivity + CloudKit。
- 命名惯例参考：bundle `com.jason.*`；EasyReminder 工程名是 `MyApp`。
- 本项目所有"功能设计/活文档"放在 `~/Developer/App Development/BetterCalendar_Claude/`。
