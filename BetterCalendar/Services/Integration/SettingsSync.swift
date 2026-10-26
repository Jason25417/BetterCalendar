//
//  SettingsSync.swift
//  BetterCalendar
//
//  设置跨端同步（#35，2026-07-15 Jason 要求「设置做成同步的」）：
//  把**平台中立的用户偏好**镜像到 iCloud KV（NSUbiquitousKeyValueStore），Mac / iPhone 两端一致。
//  机制：UserDefaults（本地即时读）↔ iCloud KV（跨端），双向镜像 + 值比较防回环。
//  W8（Jason 2026-10-18 原则：设置本来就该多端同步，不该同步的要先问他）：用户可见的设置默认都进白名单；
//  不同步的只剩本质上属于这台设备的（见 deviceLocalKeys 的逐条理由，已列给 Jason 确认）。
//  白名单制：**只同步平台中立的偏好**；设备专属项绝不同步——
//    - `integration.focusFollowDeviceID`：每台设备必须唯一（同步了会撞号→「自己发的不跟」失效、去重全废）
//    - 屏蔽名单/模式（iOS FamilyActivitySelection=设备绑定 token）、快捷指令名、菜单栏常驻、聪音桥、开机自启=平台/设备专属
//    - 各类瞬时计数（番茄周用量、onboarding 计数、pending IPC）=本地状态
//  依赖 entitlement `com.apple.developer.ubiquity-kvstore-identifier`（两端 .entitlements 已配；同 MilestoneStore）。
//

import Foundation

enum SettingsSync {
    /// 同步白名单：仅含平台中立的用户偏好。增减同步项改这里一处。
    static let syncedKeys: Set<String> = [
        "cloud.model", "cloud.provider", "cloud.sfModel", "cloud.useCloud", "cloud.onDeviceParser",
        "journal.privacyLock", "meeting.autoComplete", "reminder.lead", "push.intensity",
        "workHours.windDown", "pomo.earlyEndLimit", "theme.id", "disclosure.style", "placeholder.mode",
        "calendar.busyExcludedTitles",         // P4 Q4：排布时不当作已占用的日历（存日历名，两端一致）
        "distraction.enabled", "distraction.keywords",
        "integration.focusFollow",
        "agentContext.allowRecentJournal",   // SPEC §19 A2：允许智能体读最近日记（隐私偏好，两端一致；默认关）
        "agentJournal.allowWrite",           // W32b：允许智能体提议写日记（隐私偏好，两端一致；默认关）
        "approvals.lowRiskAutoPass.enabled", // W32d：低风险改动自动通过（默认开；一端关两端关）
        "agentChat.eveningReview.enabled", "agentChat.eveningReview.minute",   // SPEC §19 F1：iPhone 上设、Mac 触发
        // —— W8 审计补入（2026-10-18）——
        "agentEvents.enabled",                 // 关键时刻唤醒智能体：iPhone 上开，由 Mac 的桥接写事件
        "attention.settings.v1",               // 主动通知的总开关/频率上限/安静时段/一键静音：一端静音两端生效
        "approvals.alertPush.userDisabled",    // B5「手动关过」记号：订阅属于 iCloud 账户，一端关了别端启动不再自动打开
        "sharedTimer.icloud.enabled",          // iCloud 共享计时：两端同一后端才看得到彼此的计时；每台设备下次启动各自过闸门
        "execution.runRestorePolicy",          // 退出时有任务在进行 → 怎么恢复（偏好，两端一致）
        "push.muted",                          // 「别再提」的长期事项 id（事项随 iCloud 同步，id 两端相同）
        // —— W10（2026-10-18）——
        "approvals.preauthRules.v1",           // 预授权规则（A3a）：iPhone 上「以后同类都允许」，Mac 导入智能体提案时按它判定
        // —— W12（2026-10-18）——
        "reminder.projection.v1",              // 提醒投影账本（SPEC §19.13 Q5）：你在提醒事项里删掉 / 改过时间的，两端都认、都不重建不改回
        // —— W13（2026-10-18）——
        "activity.recording.enabled", "activity.recording.pausedUntil",   // 设备活动记录总开关 / 暂停到几点：在 iPhone 上暂停，Mac 也停（对人不对设备）
        // —— W16（2026-10-19）——
        "developer.optionsEnabled",            // 「开发者选项」：开发 / 测试控件的总开关（一端打开两端都显示）
        // —— W18（2026-10-19）——
        "agent.planEditing.enabled",           // 智能体排时间线（加 / 改 / 删块、跨天挪、排一天）：一端关了两端都关
        // —— W19（2026-10-19）——
        "reconcile.noticeDismissedKinds",      // 今天页「日历里有你的事件」提示：一端点「知道了」两端都不再出现
        // —— W22（2026-10-19）——
        "timeline.writeLease.enabled",         // 写权租约应急总闸：两端必须一致（一端关一端开 = 半套闸）
        // —— W21（2026-10-19）——
        "featureUsage.shareWithAgent.enabled", // 让智能体参考功能使用统计（隐私偏好，两端一致；日用版默认关）
        // —— W23（2026-10-19）——
        "today.timelineAxis.enabled",          // 今天页用时间轴（Jason 10-19：两个通道都默认开）：一端打开两端都换
        // —— W20（2026-10-19）——
        "agent.active.v1",                     // 当前智能体（Claude Code / 内置）：两端接的是同一个智能体
        "agent.sharedMemory.v1",               // 智能体共享记忆（属于角色，各实现共用；≤6000 字）
        "agent.builtin.dailyBudgetUSD",        // 内置智能体每日预算（稳定性上限；每台设备各自按它记账）
        "agent.builtin.model",                 // 内置智能体用哪个 DeepSeek 模型
        // —— W30（2026-10-19）——
        "reach.onePlace.enabled",              // 「一处响，处处知」：通知只在在场设备响（一端打开两端都按它；关 = 每台照常响）
        "drafts.handoff.enabled",              // 打了一半的字跨设备接力（一端打开两端都接力）
        // —— W38（2026-10-22）——
        "voice.whisper.enabled",               // 端侧语音（Whisper）开关：属于人；模型各台各自下载（设备类，不同步）
        // —— 0.76（2026-10-26）——
        "agent.scheduledWakes.v1",             // 智能体给自己约的唤醒时刻（哪台开着哪台叫，Mac 优先）
    ]

    /// 用户能看到/改到、但**有意不同步**的设置（本质上属于这台设备）。只作审计清单与测试用，不参与同步逻辑。
    /// 改动前先问 Jason（W8 原则）。
    static let deviceLocalKeys: [String: String] = [
        "integration.focusFollowDeviceID": "设备 ID：每台必须唯一，同步会撞号",
        "devicelog.deviceID": "设备 ID：日志按设备区分",
        "agentBridge.folderBookmark": "智能体 bridge 文件夹的安全书签：只在这台 Mac 的这个路径有效",
        "integration.bridgeFolderBookmark": "聪音联动文件夹的安全书签：只在这台 Mac 有效",
        "dotStateBridge.folder": "已冻结 Dots：本机文件夹书签", "dotStateBridge.folders": "已冻结 Dots：本机文件夹书签",
        "dotStateBridge.historyFolder": "已冻结 Dots：本机文件夹书签",
        "focus.screenTimeShield": "番茄绝对专注（屏蔽 App）：只 iOS 有、系统授权按设备",
        "focus.screenTimeShieldMode": "屏蔽模式：与本机的屏蔽名单配套",
        "focus.screenTimeSelection": "屏蔽名单：系统给的 App 令牌只在这台设备有效",
        "focus.shortcut.start": "快捷指令名：Mac 与 iPhone 的快捷指令各自不同",
        "focus.shortcut.end": "快捷指令名：同上",
        "menubar.keepRunningOnQuit": "退出时保留在菜单栏：只 Mac 有",
        "integration.chiyneSync": "聪音联动：只这台 Mac 装了游戏 mod、写本机文件",
        "integration.chiyneTodoProjection": "聪音待办投影：同上",
        "development.dataBridge": "开发期数据文件桥：读写本机下载/文稿目录",
        "approvals.alertPush.enabled": "B5 订阅状态的本机缓存：真相在 iCloud 账户上（本来就全设备生效）",
        "calendar.backend": "已退役的日历后端开关（生产恒为系统日历）",
        "home.inputHeight": "窗口/输入框高度：界面布局状态",
        "execPanelExpanded": "执行面板折叠状态：界面布局状态",
        "bench.cloudModels": "开发工具（算法台）的模型勾选",
        "agent.builtin.usage.v1": "内置智能体本机的用量与成本记账：每台设备记自己的调用，两台同时改一份计数会打架（W20，待 Jason 确认）",
    ]

    /// 远程设置到达通知（设置页据此重读 @State 刷新）。
    static let didSyncRemotely = Notification.Name("SettingsSync.didSyncRemotely")

    private static let kv = NSUbiquitousKeyValueStore.default
    /// 拉取远程写本地期间抑制回推（配合值比较，双保险防回环）。
    private static var applyingRemote = false
    private static var lastLocal: [String: NSObject] = [:]

    /// App 启动时调用一次（组装点）：挂双向监听 + 初次全量拉取远程。
    static func start() {
        guard !TestHost.isActive else { return }
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kv, queue: .main
        ) { note in
            let changed = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
            applyRemote(changedKeys: changed)
        }
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard, queue: .main
        ) { _ in
            pushLocalToCloud()
        }
        lastLocal = localSnapshot()
        kv.synchronize()
        applyRemote(changedKeys: nil)   // 初次全量：远程有值即以远程为准落到本地
    }

    /// 本地 → 云：白名单项，仅值不同才写（防回环；kv.set 不会在本机触发 didChangeExternally）。
    private static func pushLocalToCloud() {
        guard !applyingRemote else { return }
        let ud = UserDefaults.standard
        for key in syncedKeys {
            let local = ud.object(forKey: key)
            guard !valuesEqual(local, lastLocal[key]) else { continue }
            if let value = local as? NSObject { lastLocal[key] = value } else { lastLocal.removeValue(forKey: key) }
            let remote = kv.object(forKey: key)
            guard !valuesEqual(local, remote) else { continue }
            if let local { kv.set(local, forKey: key) } else { kv.removeObject(forKey: key) }
        }
    }

    /// 云 → 本地：白名单∩变更项（nil=全量），仅值不同才写；写完发通知刷新视图。
    private static func applyRemote(changedKeys: [String]?) {
        let keys = changedKeys.map { syncedKeys.intersection($0) } ?? syncedKeys
        guard !keys.isEmpty else { return }
        let ud = UserDefaults.standard
        var applied = false
        applyingRemote = true
        for key in keys {
            guard let remote = kv.object(forKey: key) else {
                if changedKeys != nil {
                    ud.removeObject(forKey: key); lastLocal.removeValue(forKey: key); applied = true
                }
                continue
            }
            guard !valuesEqual(ud.object(forKey: key), remote) else { continue }
            if remoteIsOlder(key: key, local: ud.object(forKey: key), remote: remote) {
                // 0.72.2：远程比本机旧（另一台设备 / iCloud 缓存送来的旧副本）→ 不落地，把本机这份推回去
                if let local = ud.object(forKey: key) { kv.set(local, forKey: key); lastLocal[key] = local as? NSObject }
                DevLog.shared.warn("设置同步", "iCloud 送来的「\(key)」比本机旧，保留本机这份并重新上传")
                continue
            }
            ud.set(remote, forKey: key)
            lastLocal[key] = remote as? NSObject
            applied = true
        }
        applyingRemote = false
        if applied {
            NotificationCenter.default.post(name: didSyncRemotely, object: nil)
            DevLog.shared.info("设置同步", "已从 iCloud 拉取设置变更")
        }
    }

    /// 0.72.2（10-20 晚：智能体 01:45Z 写进共享记忆的跟进，22:26 Mac 换装 191 重启后在 22:27:20「已从 iCloud 拉取设置变更」
    /// 时被旧副本盖掉）：iCloud KV 是整键「后写赢」、启动时又「远程有值即以远程为准」，不看谁新。
    /// 自带更新时间的键在这里登记：远程那份更旧就不覆盖本机。
    nonisolated static let versionedKeys: [String: @Sendable (Any) -> Date?] = [
        "agent.scheduledWakes.v1": { value in   // = AgentWakeSchedule.key（整份带更新时间）
            AgentWakeSchedule.decode(value as? String)?.updatedAt
        },
        "agent.sharedMemory.v1": { value in   // = AgentSharedMemoryStore.key
            guard let raw = value as? String else { return nil }
            let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
            return (try? d.decode(AgentSharedMemory.self, from: Data(raw.utf8)))?.updatedAt
        },
    ]

    /// 远程那份是否比本机旧（只对登记了版本的键；读不出版本 = 不判，照旧以远程为准）。
    nonisolated static func remoteIsOlder(key: String, local: Any?, remote: Any) -> Bool {
        guard let version = versionedKeys[key], let local,
              let l = version(local), let r = version(remote) else { return false }
        return r < l
    }

    private static func localSnapshot() -> [String: NSObject] {
        var values: [String: NSObject] = [:]
        for key in syncedKeys { values[key] = UserDefaults.standard.object(forKey: key) as? NSObject }
        return values
    }

    /// UserDefaults 存的都是 property-list 标量（Bool/Int/Double→NSNumber、String→NSString）→ NSObject 相等即值相等。
    private static func valuesEqual(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return (x as? NSObject) == (y as? NSObject)
        default: return false
        }
    }
}
