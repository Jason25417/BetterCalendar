# CLAUDE.md — BetterCalendar

> Claude Code 自动加载本文件。完整背景见 `BetterCalendar-交接给ClaudeCode.md`（交接），功能与路线见 `日程软件功能设计.md`（SPEC），产品/行为逻辑见 `产品设计与行为逻辑.md`。
> 注：SPEC/交接文档里的代号 **DayLoop = 本 App**，已正式定名 **BetterCalendar**。

## 这是什么
macOS + iOS 原生日程 App（SwiftUI + SwiftData）。核心闭环：**自然语言说 → 结构化排程 → 写 Apple 日历/提醒事项 → menu bar 单键导航执行（执行陪伴：轻计时默认/番茄钟可选）→ 晚间正反馈复盘（计划 vs 实际）→ 落后自动 re-flow**。
签名功能 = **计划 vs 实际**：前一晚排「预先设计」绿色日历，当晚回填「实际」蓝色日历，App 算完成度/偏差。主打**深度接入 Apple 生态 + 端侧优先 + 隐私优先**。

## 已定决策（开工前已拍板，见 SPEC §9）
- **D4 名字** = BetterCalendar（bundle `com.jason.BetterCalendar`）。
- **D3 起步平台** = macOS 先把核心闭环跑通；Multiplatform 工程，iOS 专属能力（Screen Time 屏蔽）后做。
- **D1 解析+排程大脑** = 原型期云端 LLM（Claude API）全接管（解析 + 排序/优先/re-flow/push），藏在协议后；端侧 FM / 隐私优先降为长期目标、留接口后换。
- **D2 写日历** = EventKit 直写绿/蓝两个日历为主 + ICS 作可移植导出/分享。

## 产品设计原则（必须贯穿 UI/交互）
1. **无感**：记录=导航（menu bar 单键「完成/下一件」）+ 被动信号优先，绝不要求实时写日志。
2. **正反馈优先**：主反馈是"做成了什么"（含计划外 bonus）；完成率/缺口默认隐藏；偏差用中性/正向措辞。
3. **自愈**：落后 → 自动 re-flow → 只呈现"从现在起可行"的剩余日程。
4. **Apple 原生**：深接 EventKit/提醒/iCloud；通知极简（早晚各一条 + 仅固定块提醒）。（隐私/端侧优先=长期目标，原型期让位。）
5. **自主支持式推动**：push 但不控制——要紧事自己设、前向 nudge、可选、预先授权、强度可调（默认温和）。
> 情感目标 = 掌控感 + 成就感，不是纪律；专破"第一件搞砸 → 全盘弃"。

## 工程事实（务必知道）
- Xcode 工程：`BetterCalendar.xcodeproj`，类型 **Multiplatform → App**，bundle `com.jason.BetterCalendar`，PRODUCT_NAME/显示名 `BetterCalendar`。
- **部署目标 iOS 26 / macOS 26 起步**（Foundation Models 最低要求）；建工程时在 General → Deployment 确认，如沿用 BetterTranscribe 的更高版本再调。
- **文件系统同步式工程**（`PBXFileSystemSynchronizedRootGroup`，Xcode 26 默认）：往源码文件夹写 `.swift`，Xcode 自动纳入 target，**无需手动改 pbxproj**。
- **无独立 `.entitlements` 文件**：沙盒/能力/权限由 **build setting + 生成的 Info.plist 键**驱动（同 MyApp/BetterTranscribe）。
- Swift 语言模式 + `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`（默认主 actor 隔离，沿用 BetterTranscribe）。
- App Sandbox + Hardened Runtime：发布需要，M0 即开（`ENABLE_APP_SANDBOX=YES`、`ENABLE_HARDENED_RUNTIME=YES`）。

## 架构约定（必须遵守）
- 分层：**App 组装点 / Models / Services（协议+实现）/ Features（View+ViewModel）**。
- 界面**不直接调系统 API**；上层只依赖**协议**，不依赖具体实现。
- 依赖在**唯一组装点** `BetterCalendarApp.swift` 创建并注入（构造函数注入）。
- 加新能力流程：先「**协议 + 最小实现 + 一个验证 demo**」，再接 ViewModel/UI。
- ViewModel 用 `@Observable` + `@MainActor`；View 用 `@State` 持有 VM（init 注入），跨视图共享用 `@Bindable`。
- 跨平台：核心闭环（解析/日历/对比/re-flow）两端通用；**`FocusService` 按平台注入不同实现**（组装点决定），上层 UI 不变。
- 数据：**SwiftData + CloudKit**，只存**元数据 + 外部事件 ID**；真正的事件存系统日历。
- **排程大脑走 LLM（原型期）**：解析/排序/优先/re-flow/push 的智能藏在协议（`ScheduleParsing`/`PlanningEngine`）后，原型用云端 Claude，后期固化为本地算法。缝必须 **async throws + 超时 + 朴素本地 fallback**、DTO 实现无关——"之后都能换"才成立。

## Services（协议 → 实现，含起步顺序）
- `ScheduleParsing`（自然语言 → `PlanBlock[]`）→ `ClaudeScheduleParser`（云端，**先做**）／`FoundationModelsScheduleParser`（端侧，留接口后换）
- `CalendarStore`（建带色日历、写/读回/删改事件）→ `EventKitCalendarStore`
- `ICSExporting`（`PlanBlock[]` → ICS VEVENT 文本）→ 复用/改造 EasyReminder 的 ICS 能力
- `ReminderStore`（写标准 VTODO 提醒）→ 复用 EasyReminder
- `PlanComparing`（预先设计 × 实际 → 完成度）→ `OverlapTitleComparer`
- `RescheduleService`（re-flow 编排：触发/预览/回写）→ 决策委托 `PlanningEngine`
- `PlanningEngine`（排序/优先/re-flow/温和push 决策；**原型期统一走 LLM**）→ `LLMPlanningEngine`（Claude，**先做**）／`RuleBasedPlanningEngine`（本地，后期固化）
- `FocusService`（执行会话：计时风格 番茄钟/轻计时/无 +（iOS）屏蔽；**轻计时默认**）→ macOS: `TimerOnlyFocusService`（**先做**）／iOS: `ScreenTimeFocusService`（FamilyControls，⚠️ 待 entitlement）
- 备注：**menu bar 单键导航 + 正反馈复盘**属 Feature 层（VM），建在 `CalendarStore`+`PlanComparing` 上，不新增协议。
- `Persistence`（SwiftData + CloudKit）

## 数据模型（SwiftData，随 CloudKit 同步；只存元数据 + 外部 ID）
- `PlanDay` { date, plannedStartAnchor?, actualStartTime?, source }
- `PlanBlock` { id, title, start, end, isFixed, category, kind, timingStyle, **priority: normal|important(要紧事)**, **deadline?（硬DDL，≠isFixed）**, assignedBy, **labels:[String]（扩展接口）**, externalEventID?, completion? }
- `CompletionLink` { plannedBlockID, actualBlockID?, status: done|partial|missed|over|extra }
- `ExecutionSession` { blockID?, start, end?, timingStyle, completedCount?, interruptions }   // 取代 PomodoroSession
- `AppSettings` { plannedCalendarID, actualCalendarID, defaultTimingStyle, hideCompletionRate, notifyMode, parserMode, **calendarBackend: fake|eventKit**, pushIntensity }

## 权限 / 能力（build setting + Info.plist 键）
- 日历 **full access**（建日历 + 读回对比必须）：`INFOPLIST_KEY_NSCalendarsFullAccessUsageDescription`，运行时 `requestFullAccessToEvents`。iOS 17+ 的 *write-only* 权限不够用。
- 提醒事项：`INFOPLIST_KEY_NSRemindersFullAccessUsageDescription`。
- 沙盒日历/提醒能力：`ENABLE_RESOURCE_ACCESS_CALENDARS = YES`。
- ICS 导出/导入文件：`ENABLE_USER_SELECTED_FILES = readwrite`（**必须 readwrite，只读会导致导出崩溃**——EasyReminder 踩过）。
- 通知（块开始/复盘提醒）：运行时 `requestAuthorization`，加 Push/Notifications 能力。
- （iOS）`com.apple.developer.family-controls` entitlement：**须向 Apple 申请、上架前必须获批，审批有周期，别拖**。

## 命令
- 运行：⌘R（自动增量编译）。只编译：⌘B。测试：⌘U（Swift Testing）。清缓存：⇧⌘K。
- 命令行（按需）：`xcodebuild -scheme BetterCalendar -destination 'platform=macOS' build`。

## 当前重点 / 待办（M0 ✅ 2026-06-29 macOS 编译通过；开发期日历走 FakeCalendarStore+预览，下一步 M1 接 ClaudeScheduleParser）
1. Xcode → File → New → Project → **Multiplatform → App**：名 `BetterCalendar`，Interface=SwiftUI，Language=Swift，勾 Storage=SwiftData。
2. 建分层目录：`App/`、`Models/`、`Services/`（每能力一协议+实现）、`Features/`（View+ViewModel）。
3. 定 SwiftData 数据模型（见上「数据模型」）。
4. 组装点：给每个 Service 协议写**空实现/桩**，注入到 UI；一个最简首页能跑起来。
5. 开 App Sandbox + Hardened Runtime。
6. **本步目标：能编译、能启动、空界面在 macOS 跑通，不接任何系统 API。**
7. 之后按 SPEC §10：M1 端侧解析 → M2 写日历/ICS → M3 提醒事项 → M4 实际采集+正反馈复盘 → M5 自愈re-flow → M6 执行陪伴 → M7 iCloud → M8 发布。
> 每完成一项，回 `日程软件功能设计.md` 把 `[ ]` 改 `[x]`、更新 §0 进度总览。

## 已核实的关键 API 约束（核实于 2026-06，实现前请复核——易随系统版本变）
1. **EventKit**：读回事件做对比 + 新建带色日历 → 必须 **full access**；`EKCalendar` 可设 `title` + `cgColor`（绿/蓝），需指定可写 `source`（iCloud 或本地，用户没开 iCloud 日历要回退本地）。
2. **Screen Time（FamilyControls/ManagedSettings/DeviceActivity）**：需特殊 entitlement；**macOS 上基本不可用**（沙盒限制，授权与 picker 运行时失败）→ 硬屏蔽只 iOS 可行，macOS 番茄钟降级为纯计时 + 提示 + 引导系统专注模式。
3. **Foundation Models**：iOS 26/macOS 26+，端侧 ~3B，`@Generable` 直出类型安全结构化输出；设备不支持时 `SystemLanguageModel.default.availability` 返回不可用 → **必须降级**（云端填 key / 手动排）。
4. **提醒事项**：子任务/标签/旗标/附件/紧急提醒属私有 ReminderKit，EventKit 不可写 → **只写标准 VTODO**（标题/备注/截止/提醒）。

## 可复用资产
- **EasyReminder（`~/Developer/App Development/MyApp/`）**：ICS(VTODO) ↔ 提醒事项 双向已实现 → `ICSExporting`（计划块→VEVENT）和 `ReminderStore`（写 VTODO）可直接借鉴代码与踩坑。
- **BetterTranscribe（`~/Developer/App Development/BetterTranscribe/`）**：同一套分层架构骨架 + Foundation Models 调用经验 → 参考 `ScheduleParsing` 实现。

## 沟通
中文、简洁直接、步骤具体（用户是原生开发初学者，第一个真实项目；先骨架跑通再逐能力扩展）。
