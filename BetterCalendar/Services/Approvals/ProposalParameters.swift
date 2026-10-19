//
//  ProposalParameters.swift
//  BetterCalendar
//
//  SPEC §19 W11（Jason 2026-10-18 的新想法）：审批卡上的「可调参数」。
//  除了固定的方案，智能体还可以给提案挂上可调的数值——卡片上出一个滑块或时间选择器，你调好再批准：
//    「休息多久」「提前几分钟提醒」「持续多久」→ 滑块；「挪到几点」「几点提醒」→ 时间选择器。
//  设计要点：
//    - 小而封闭的类型集合（数字带单位 / 时长 / 当天的几点 / 日期加时间），不是通用表单；
//    - 每个参数显式绑定到动作里的一个字段（挪块的开始/结束/时长、计时的回溯起点、提醒的时刻/提前量），
//      绑到这种动作没有的字段一律拒收；
//    - 默认值 = 动作里写的那个（App 依据准备好的动作算出，智能体写了 default 就必须一致）；
//    - 智能体给的范围只是界面提示；**合法性归 App**：你选的最终值套回动作后，重新走同一套 prepare 校验，
//      「改动前 → 改动后」依据真实数据实时重算；不合法就当场写明原因、不能批准，**绝不悄悄夹到范围里**。
//  全部存在提案 JSON 载荷里（可选字段），旧记录照常解码，不改 CloudKit schema。
//

import Foundation

/// 参数的类型（小而封闭）。
nonisolated enum ProposalParameterKind: String, Codable, Sendable, CaseIterable {
    /// 数字 + 单位（分钟 / 小时），滑块
    case number
    /// 时长（以分钟计，显示成「1 小时 20 分钟」），滑块
    case duration
    /// 当天的几点（与默认值同一天：逻辑日从凌晨 4:00 起），时间选择器
    case timeOfDay
    /// 日期 + 时间，选择器
    case dateTime

    var isDate: Bool { self == .timeOfDay || self == .dateTime }
}

/// 数字参数的单位（只用于 number；时长固定按分钟）。
nonisolated enum ProposalParameterUnit: String, Codable, Sendable, CaseIterable {
    case minute, hour
    var label: String { self == .minute ? "分钟" : "小时" }
    var seconds: TimeInterval { self == .minute ? 60 : 3600 }
}

/// 参数绑定到动作里的哪个字段（显式、可校验）。
nonisolated enum ProposalParameterBinding: String, Codable, Sendable, CaseIterable {
    /// moveBlock：新开始时间（保持原时长整体平移）
    case start
    /// moveBlock：新结束时间（开始不动）
    case end
    /// moveBlock：持续多久（开始不动，结束 = 开始 + 时长）
    case duration
    /// timer start：回溯起点（从几点开始算）
    case startedAt
    /// reminder / alarm：响的时刻
    case fireAt
    /// reminder / alarm：提前量（时刻 = anchor − 提前量；anchor = 要提醒的那件事的时刻）
    case leadTime

    /// 这种绑定接受哪些参数类型。
    var kinds: Set<ProposalParameterKind> {
        switch self {
        case .start, .end, .startedAt, .fireAt: [.timeOfDay, .dateTime]
        case .duration, .leadTime: [.number, .duration]
        }
    }

    /// 同一份方案里不能同时出现的绑定（都在决定同一个字段）。
    var clashes: Set<ProposalParameterBinding> {
        switch self {
        case .end: [.duration]
        case .duration: [.end]
        case .fireAt: [.leadTime]
        case .leadTime: [.fireAt]
        default: []
        }
    }
}

/// 参数的值：数字（number = 单位数；duration = 分钟）或时刻。
nonisolated enum ProposalParameterValue: Codable, Equatable, Sendable {
    case number(Double)
    case date(Date)

    var number: Double? { if case let .number(v) = self { v } else { nil } }
    var date: Date? { if case let .date(d) = self { d } else { nil } }
}

/// 一个可调参数的声明。范围 / 步长只是界面提示；合法性由 App 对最终值重新校验。
nonisolated struct ProposalParameter: Codable, Equatable, Sendable, Identifiable {
    /// 参数 id（同一方案内唯一；字母数字、- 或 _）
    var id: String
    /// 卡片上的名字，如「提醒时间」「休息多久」
    var label: String
    var kind: ProposalParameterKind
    var bind: ProposalParameterBinding
    /// 只用于 number
    var unit: ProposalParameterUnit? = nil
    /// 默认值 = 动作里写的那个（App 准备提案时依据动作算出并写进来；智能体写的 default 只用于核对一致）。
    var defaultValue: ProposalParameterValue? = nil
    /// 界面范围提示（number / duration 必填；时刻类可选）
    var min: ProposalParameterValue? = nil
    var max: ProposalParameterValue? = nil
    /// 滑块步长（number = 单位数，duration = 分钟）；nil = 1
    var step: Double? = nil
    /// 只用于 leadTime：要提醒的那件事的时刻
    var anchor: Date? = nil
    /// W18：作用于这份方案里的哪一块（计划块 id）。一份方案里有多块（一起挪 / 加多块 / 排一天）时必填；只有一块时可省略。
    var target: UUID? = nil
}

/// 你在卡片上调好的结果：最终值 + 套回动作后重新校验过的动作与「改动前 → 改动后」。
nonisolated struct ProposalTuning: Equatable, Sendable {
    var values: [String: ProposalParameterValue]
    var action: ProposalAction
    var changes: [ProposalChange]
}

/// 参数规则（纯函数、可单测）。
nonisolated enum ProposalParameterRules {
    /// 技术防失控上限（**不是产品规则**）：一份方案最多挂几个参数。卡片上放几个合适由智能体判断（CLAUDE.md 建议 ≤2）。
    static let maxPerOption = 5
    static let labelLimit = 20
    static let idLimit = 32
    /// 技术防失控上限：滑块最多多少档（(max−min)/step），防文件出错塞进离谱的步长。
    static let maxSliderPositions = 10_000

    // MARK: 绑定合法性

    private struct BindKey: Hashable { var target: String; var bind: ProposalParameterBinding }

    /// 这种动作有哪些可调字段（没有的绑定一律拒收）。
    static func bindings(for action: ProposalAction) -> Set<ProposalParameterBinding> {
        switch action {
        case .moveBlock, .moveBlocks(_, false), .blockCreate, .planDay(_, _, false): [.start, .end, .duration]
        case .blockEdit: [.duration]
        case .timer(.start, _, _, _, _): [.startedAt]
        case .reminder, .alarm: [.fireAt, .leadTime]
        default: []
        }
    }

    // MARK: W18 时间线多块：参数作用于其中一块（target）

    /// 方案里可调时间的那几块（id → 开始 / 结束；结束 nil = 挪动时保持原时长）。单块动作（moveBlock）不在这里。
    private static func slots(_ action: ProposalAction) -> [(id: UUID, start: Date?, end: Date?, op: String)]? {
        switch action {
        case let .moveBlocks(moves, false): return moves.map { ($0.id, $0.start, $0.end, "move") }
        case let .blockCreate(_, blocks): return blocks.map { ($0.id, $0.start, $0.end, "create") }
        case let .blockEdit(e): return [(e.id, nil, nil, e.duration == nil ? "edit" : "editDuration")]
        case let .planDay(_, steps, false):
            return steps.compactMap { step in
                switch step {
                case let .create(b): (b.id, b.start, b.end, "create")
                case let .move(m): (m.id, m.start, m.end, "move")
                case let .edit(e): (e.id, nil, nil, e.duration == nil ? "edit" : "editDuration")
                default: nil
                }
            }
        default: return nil
        }
    }

    /// 参数作用于哪一块：多块时必须写 target；只有一块时可省略。
    private static func slot(_ p: ProposalParameter, in action: ProposalAction, name: String) throws -> (id: UUID, start: Date?, end: Date?, op: String) {
        guard let all = slots(action) else { throw ProposalExecutionError.invalid("\(name)绑定的字段不属于这项改动") }
        if let target = p.target {
            guard let s = all.first(where: { $0.id == target }) else {
                throw ProposalExecutionError.invalid("\(name)的 target 不是这份方案里的块（要填方案里那一块的 id）")
            }
            return s
        }
        guard all.count == 1 else { throw ProposalExecutionError.invalid("\(name)：方案里有 \(all.count) 块，要用 target 写明调的是哪一块") }
        return all[0]
    }

    /// 改方案里某一块的开始 / 结束（只用于 W18 多块动作）。
    private static func setSlot(_ action: ProposalAction, _ id: UUID, start: Date?, end: Date??, duration: TimeInterval?) -> ProposalAction {
        func shift(_ s0: Date, _ e0: Date?) -> (Date, Date?) {
            var s = s0, e = e0
            if let start { e = e0.map { start.addingTimeInterval($0.timeIntervalSince(s0)) }; s = start }
            if let end { e = end }
            if let duration { e = s.addingTimeInterval(duration) }
            return (s, e)
        }
        func move(_ m: ProposalBlockMove) -> ProposalBlockMove {
            guard m.id == id else { return m }
            let (s, e) = shift(m.start, m.end)
            return ProposalBlockMove(id: m.id, start: s, end: e, expectedRevision: m.expectedRevision)
        }
        func create(_ b: ProposalNewBlock) -> ProposalNewBlock {
            guard b.id == id else { return b }
            var b = b; let (s, e) = shift(b.start, b.end); b.start = s; b.end = e ?? b.end
            return b
        }
        func edit(_ e: ProposalBlockEdit) -> ProposalBlockEdit {
            guard e.id == id, let duration else { return e }
            var e = e; e.duration = duration; return e
        }
        switch action {
        case let .moveBlocks(moves, undo): return .moveBlocks(moves: moves.map(move), isUndo: undo)
        case let .blockCreate(day, blocks): return .blockCreate(day: day, blocks: blocks.map(create))
        case let .blockEdit(e): return .blockEdit(edit(e))
        case let .planDay(day, steps, undo):
            return .planDay(day: day, steps: steps.map { step in
                switch step {
                case let .create(b): .create(create(b))
                case let .move(m): .move(move(m))
                case let .edit(e): .edit(edit(e))
                default: step
                }
            }, isUndo: undo)
        default: return action
        }
    }

    /// 格式与绑定校验（桥接导入、ProposalCenter.prepare 都走这里）。where = 报错时的位置描述（「参数」「备选方案 2 的参数」）。
    static func validateDeclarations(_ params: [ProposalParameter], for action: ProposalAction, where place: String = "参数") throws {
        guard params.count <= maxPerOption else {
            throw ProposalExecutionError.invalid("\(place)最多 \(maxPerOption) 个（技术上限；卡片上建议不超过 2 个）")
        }
        let allowed = bindings(for: action)
        var ids = Set<String>(), binds = Set<BindKey>()
        for p in params {
            let name = "\(place)「\(p.label.isEmpty ? p.id : p.label)」"
            guard !p.id.isEmpty, p.id.count <= idLimit,
                  p.id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }) else {
                throw ProposalExecutionError.invalid("\(place)的 id 必须是 1–\(idLimit) 位字母、数字、- 或 _（「\(p.id)」）")
            }
            guard ids.insert(p.id).inserted else { throw ProposalExecutionError.invalid("\(place) id「\(p.id)」重复") }
            let label = p.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, label.count <= labelLimit else {
                throw ProposalExecutionError.invalid("\(place)「\(p.id)」要有名字（不超过 \(labelLimit) 字）")
            }
            guard allowed.contains(p.bind) else {
                let list = allowed.isEmpty ? "这种改动没有可调的字段" : "可绑：" + allowed.map(\.rawValue).sorted().joined(separator: " / ")
                throw ProposalExecutionError.invalid("\(name)绑定的字段「\(p.bind.rawValue)」不属于「\(action.kindLabel)」（\(list)）")
            }
            guard p.bind.kinds.contains(p.kind) else {
                throw ProposalExecutionError.invalid("\(name)：字段「\(p.bind.rawValue)」只接受 " + p.bind.kinds.map(\.rawValue).sorted().joined(separator: " / ") + " 类型")
            }
            let key = p.target?.uuidString ?? ""
            if let clash = binds.first(where: { $0.target == key && p.bind.clashes.contains($0.bind) }) {
                throw ProposalExecutionError.invalid("\(name)和绑定「\(clash.bind.rawValue)」的参数在改同一个字段，只能留一个")
            }
            guard binds.insert(BindKey(target: key, bind: p.bind)).inserted else { throw ProposalExecutionError.invalid("\(place)里字段「\(p.bind.rawValue)」被绑了两次") }
            // 单位：只有 number 带
            if p.kind == .number { guard p.unit != nil else { throw ProposalExecutionError.invalid("\(name)是数字，需要单位 unit（minute / hour）") } }
            else if p.unit != nil { throw ProposalExecutionError.invalid("\(name)：只有 number 类型带 unit") }
            // 提前量需要 anchor；别的不要
            if p.bind == .leadTime { guard p.anchor != nil else { throw ProposalExecutionError.invalid("\(name)是提前量，需要 anchor（要提醒的那件事的时刻）") } }
            else if p.anchor != nil { throw ProposalExecutionError.invalid("\(name)：只有提前量 leadTime 带 anchor") }
            // W18：多块方案里参数作用于哪一块（target）；同一块的同一字段不能绑两次（上面的「被绑了两次」按块分开算）
            if slots(action) != nil {
                let s = try slot(p, in: action, name: name)
                if p.bind != .duration, s.op.hasPrefix("edit") { throw ProposalExecutionError.invalid("\(name)：改块只能调时长（duration）") }
                if p.bind == .duration, s.op == "edit" { throw ProposalExecutionError.invalid("\(name)：这一步没有改时长，没有可调的时长") }
            } else if p.target != nil {
                throw ProposalExecutionError.invalid("\(name)：只有多块的时间线改动（一起挪 / 加块 / 排一天）带 target")
            }
            try validateRange(p, name: name)
        }
    }

    private static func validateRange(_ p: ProposalParameter, name: String) throws {
        let wantsDate = p.kind.isDate
        for v in [p.defaultValue, p.min, p.max].compactMap({ $0 }) {
            switch v {
            case .date where !wantsDate, .number where wantsDate:
                throw ProposalExecutionError.invalid("\(name)的默认值/范围类型不对（\(wantsDate ? "要时刻" : "要数字")）")
            case let .number(n) where !n.isFinite:
                throw ProposalExecutionError.invalid("\(name)的数字不是有效值")
            default: break
            }
        }
        if wantsDate {
            guard p.step == nil else { throw ProposalExecutionError.invalid("\(name)：时刻类参数不带 step") }
            if let lo = p.min?.date, let hi = p.max?.date, lo >= hi { throw ProposalExecutionError.invalid("\(name)的范围 min 要早于 max") }
            return
        }
        guard let lo = p.min?.number, let hi = p.max?.number else {
            throw ProposalExecutionError.invalid("\(name)是滑块，需要范围 min / max（只是界面提示，合法性由 BetterCalendar 再查）")
        }
        guard lo < hi else { throw ProposalExecutionError.invalid("\(name)的范围 min 要小于 max") }
        let step = p.step ?? 1
        guard step.isFinite, step > 0 else { throw ProposalExecutionError.invalid("\(name)的步长 step 必须大于 0") }
        guard (hi - lo) / step <= Double(maxSliderPositions) else {
            throw ProposalExecutionError.invalid("\(name)的滑块档数超过技术上限 \(maxSliderPositions)（步长太小或范围太大，疑似出错）")
        }
    }

    // MARK: 默认值（= 动作里写的那个）

    /// 依据准备好的动作算出每个参数的默认值，写进声明；智能体写了 default 就必须与之一致；默认值须落在给的范围里。
    static func normalize(_ params: [ProposalParameter], for action: ProposalAction, where place: String = "参数") throws -> [ProposalParameter] {
        try validateDeclarations(params, for: action, where: place)
        return try params.map { raw in
            var p = raw
            p.label = raw.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = "\(place)「\(p.label)」"
            let current = try currentValue(p, in: action, name: name)
            if let declared = raw.defaultValue, !same(declared, current, p) {
                throw ProposalExecutionError.invalid("\(name)的默认值（\(format(declared, p))）和改动里写的（\(format(current, p))）不一致：默认值就是改动里写的那个")
            }
            p.defaultValue = current
            if let lo = p.min, less(current, lo, p) {
                throw ProposalExecutionError.invalid("\(name)的默认值 \(format(current, p)) 在给的范围下限 \(format(lo, p)) 之外")
            }
            if let hi = p.max, less(hi, current, p) {
                throw ProposalExecutionError.invalid("\(name)的默认值 \(format(current, p)) 在给的范围上限 \(format(hi, p)) 之外")
            }
            return p
        }
    }

    /// 字段在动作里的当前值（换算成参数的类型）。
    static func currentValue(_ p: ProposalParameter, in action: ProposalAction, name: String = "参数") throws -> ProposalParameterValue {
        switch (p.bind, action) {
        case let (.start, .moveBlock(_, start, _, _)): return .date(start)
        case let (.end, .moveBlock(_, _, end?, _)): return .date(end)
        case let (.duration, .moveBlock(_, start, end?, _)): return .number(amount(end.timeIntervalSince(start), p))
        case let (.startedAt, .timer(.start, _, _, _, startAt)):
            guard let startAt else { throw ProposalExecutionError.invalid("\(name)要调回溯起点，改动里得先写一个 startedAt（现在是「从批准那刻算」）") }
            return .date(startAt)
        case (.start, _) where slots(action) != nil, (.end, _) where slots(action) != nil, (.duration, _) where slots(action) != nil:
            let s = try slot(p, in: action, name: name)
            if case let .blockEdit(e) = action, let d = e.duration { return .number(amount(d, p)) }
            if case let .planDay(_, steps, _) = action, case let .edit(e)? = steps.first(where: { $0.blockID == s.id }), let d = e.duration {
                return .number(amount(d, p))
            }
            switch p.bind {
            case .start: if let st = s.start { return .date(st) }
            case .end: if let e = s.end { return .date(e) }
            default: if let st = s.start, let e = s.end { return .number(amount(e.timeIntervalSince(st), p)) }
            }
            throw ProposalExecutionError.invalid("\(name)绑定的字段在这一块里没有值（挪动没写 end 时不能调结束 / 时长）")
        case let (.fireAt, .reminder(_, _, _, fireAt, _)), let (.fireAt, .alarm(_, _, fireAt, _)): return .date(fireAt)
        case let (.leadTime, .reminder(_, _, _, fireAt, _)), let (.leadTime, .alarm(_, _, fireAt, _)):
            guard let anchor = p.anchor, anchor >= fireAt else { throw ProposalExecutionError.invalid("\(name)的 anchor 要不早于提醒时刻（提前量 = anchor − 提醒时刻）") }
            return .number(amount(anchor.timeIntervalSince(fireAt), p))
        default:
            throw ProposalExecutionError.invalid("\(name)绑定的字段在这项改动里没有值")
        }
    }

    // MARK: 把你选的值套回动作

    /// 只改你给了值的字段；没给的保持动作原样（= 默认）。不夹范围：合法性交给 prepare。
    static func apply(_ values: [String: ProposalParameterValue], _ params: [ProposalParameter], to action: ProposalAction) throws -> ProposalAction {
        let known = Set(params.map(\.id))
        if let unknown = values.keys.first(where: { !known.contains($0) }) {
            throw ProposalExecutionError.invalid("没有叫「\(unknown)」的可调参数")
        }
        var result = action
        // 先开始时间、再结束/时长（「挪到几点 + 持续多久」组合时，时长从新的开始算）。
        let ordered = params.sorted { ($0.bind == .start ? 0 : 1) < ($1.bind == .start ? 0 : 1) }
        for p in ordered {
            guard let v = values[p.id] else { continue }
            let name = "「\(p.label)」"
            switch (p.kind.isDate, v) {
            case (true, .number), (false, .date): throw ProposalExecutionError.invalid("\(name)的值类型不对")
            case let (false, .number(n)) where !n.isFinite: throw ProposalExecutionError.invalid("\(name)的值不是有效数字")
            default: break
            }
            result = try set(p, v, in: result)
        }
        return result
    }

    private static func set(_ p: ProposalParameter, _ v: ProposalParameterValue, in action: ProposalAction) throws -> ProposalAction {
        let name = "「\(p.label)」"
        let date = v.date.map { p.kind == .timeOfDay ? onSameDay($0, as: p.defaultValue?.date) : $0 }
        let seconds = v.number.map { $0 * (p.kind == .duration ? 60 : (p.unit ?? .minute).seconds) }
        switch (p.bind, action) {
        case let (.start, .moveBlock(id, start, end, rev)):
            let newStart = date!
            return .moveBlock(id: id, start: newStart, end: end.map { newStart.addingTimeInterval($0.timeIntervalSince(start)) }, expectedRevision: rev)
        case let (.end, .moveBlock(id, start, _, rev)):
            return .moveBlock(id: id, start: start, end: date!, expectedRevision: rev)
        case let (.duration, .moveBlock(id, start, _, rev)):
            return .moveBlock(id: id, start: start, end: start.addingTimeInterval(seconds!), expectedRevision: rev)
        case let (.startedAt, .timer(.start, blockId, title, rev, _)):
            return .timer(command: .start, blockId: blockId, title: title, expectedRevision: rev, startAt: date!)
        case (.start, _) where slots(action) != nil:
            return setSlot(action, try slot(p, in: action, name: name).id, start: date!, end: nil, duration: nil)
        case (.end, _) where slots(action) != nil:
            return setSlot(action, try slot(p, in: action, name: name).id, start: nil, end: .some(date!), duration: nil)
        case (.duration, _) where slots(action) != nil:
            return setSlot(action, try slot(p, in: action, name: name).id, start: nil, end: nil, duration: seconds!)
        case let (.fireAt, .reminder(id, title, body, _, device)):
            return .reminder(id: id, title: title, body: body, fireAt: date!, deviceId: device)
        case let (.fireAt, .alarm(id, title, _, device)):
            return .alarm(id: id, title: title, fireAt: date!, deviceId: device)
        case let (.leadTime, .reminder(id, title, body, _, device)):
            return .reminder(id: id, title: title, body: body, fireAt: try lead(p, seconds!), deviceId: device)
        case let (.leadTime, .alarm(id, title, _, device)):
            return .alarm(id: id, title: title, fireAt: try lead(p, seconds!), deviceId: device)
        default:
            throw ProposalExecutionError.invalid("\(name)绑定的字段不属于这项改动")
        }
    }

    private static func lead(_ p: ProposalParameter, _ seconds: TimeInterval) throws -> Date {
        guard seconds >= 0 else { throw ProposalExecutionError.invalid("「\(p.label)」是提前量，不能是负数") }
        guard let anchor = p.anchor else { throw ProposalExecutionError.invalid("「\(p.label)」缺少 anchor") }
        return anchor.addingTimeInterval(-seconds)
    }

    /// 「当天的几点」：取你选的时分，放到默认值所在的那一天（逻辑日从凌晨 4:00 起：默认 0:30、你选 23:00 = 同一晚的 23:00）。
    static func onSameDay(_ picked: Date, as reference: Date?) -> Date {
        guard let reference else { return picked }
        let cal = Calendar.current
        let hm = cal.dateComponents([.hour, .minute], from: picked)
        guard var d = cal.date(bySettingHour: hm.hour ?? 0, minute: hm.minute ?? 0, second: 0, of: reference) else { return picked }
        if !DayContext.isSameLogicalDay(d, reference) {
            d = cal.date(byAdding: .day, value: d < reference ? 1 : -1, to: d) ?? d
        }
        return d
    }

    // MARK: 比较与显示

    private static func amount(_ seconds: TimeInterval, _ p: ProposalParameter) -> Double {
        seconds / (p.kind == .duration ? 60 : (p.unit ?? .minute).seconds)
    }

    /// 两个值是否算同一个（时刻按分钟、数字按值）。
    static func same(_ a: ProposalParameterValue, _ b: ProposalParameterValue, _ p: ProposalParameter) -> Bool {
        switch (a, b) {
        case let (.number(x), .number(y)): return abs(x - y) < 1e-6
        case let (.date(x), .date(y)):
            let x2 = p.kind == .timeOfDay ? onSameDay(x, as: p.defaultValue?.date ?? y) : x
            return abs(x2.timeIntervalSince(y)) < 30
        default: return false
        }
    }

    private static func less(_ a: ProposalParameterValue, _ b: ProposalParameterValue, _ p: ProposalParameter) -> Bool {
        switch (a, b) {
        case let (.number(x), .number(y)): x < y - 1e-9
        case let (.date(x), .date(y)): x.timeIntervalSince(y) < -30
        default: false
        }
    }

    /// 你选的值和默认值不一样吗。
    static func isChanged(_ p: ProposalParameter, _ value: ProposalParameterValue?) -> Bool {
        guard let value, let d = p.defaultValue else { return false }
        return !same(value, d, p)
    }

    /// 给人看的值：「15 分钟」「1 小时 20 分钟」「07:45」「10月19日 07:45」。
    static func format(_ v: ProposalParameterValue, _ p: ProposalParameter) -> String {
        switch v {
        case let .date(d):
            guard p.kind == .timeOfDay else { return ProposalReminderRules.when(d) }
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm"
            return f.string(from: d)
        case let .number(n):
            if p.kind == .duration {
                let minutes = Int(n.rounded()), h = minutes / 60, m = minutes % 60
                return h > 0 ? "\(h) 小时" + (m > 0 ? " \(m) 分钟" : "") : "\(m) 分钟"
            }
            let text = n == n.rounded() ? String(Int(n)) : String(format: "%.1f", n)
            return "\(text) \((p.unit ?? .minute).label)"
        }
    }

    /// 留底 / 通知 / 结果文件用的一行行说明：「提醒时间：08:00 → 你改成 07:45」或「提醒时间：08:00（默认）」。
    static func summary(_ params: [ProposalParameter], values: [String: ProposalParameterValue]?) -> [String] {
        params.compactMap { p in
            guard let d = p.defaultValue else { return nil }
            if let v = values?[p.id], isChanged(p, v) { return "\(p.label)：\(format(d, p)) → 你改成 \(format(v, p))" }
            return "\(p.label)：\(format(d, p))（默认）"
        }
    }
}
