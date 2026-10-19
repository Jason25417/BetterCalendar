//
//  AxisBlockEditor.swift
//  BetterCalendar
//
//  W23：点一下时间轴上的计划块 → 改标题 / 性质 / 删除。改动走 HomeViewModel 的绑定（W19b 原路：改了即自动保存）。
//  时间不在这里改：时间 = 在轴上拖（拖动按排布规则校验，放不下会写明原因）——一个意图一个入口（U7）。
//  删除 = 移入回收站（30 天内可在 设置 → 回收站 找回），做完可撤销，所以不弹「确定吗」（U10 v2）。
//

import SwiftUI

struct AxisBlockEditor: View {
    @Binding var block: EditableBlock
    var onDelete: () -> Void
    var onDone: () -> Void

    @State private var deadlineHint: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("标题", text: $block.title)
                        .accessibilityIdentifier("bc.today.axis.edit.title")
                    LabeledContent("时间", value: PlanEditRules.span(block.start, block.end))
                    Text("改时间：在时间轴上拖这一块；拉它的底边改时长。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("性质") {
                    Toggle("尽早（重排时优先靠前）", isOn: Binding(
                        get: { block.priority == .important },
                        set: { block.priority = $0 ? .important : .normal; if $0 { block.isAnchor = false } }))
                    Toggle("固定（与他人约定，时刻不可改）", isOn: $block.isFixed)
                    Toggle("生活锚点（午饭 / 通勤这类，不催完成）", isOn: Binding(
                        get: { block.isAnchor },
                        set: { block.isAnchor = $0; if $0 { block.priority = .normal; block.deadline = nil } }))
                    Toggle("有具体截止", isOn: Binding(
                        get: { block.deadline != nil },
                        set: { on in
                            deadlineHint = nil
                            block.deadline = on ? block.end : nil
                        }))
                    if let ddl = block.deadline {
                        DatePicker("截止", selection: Binding(
                            get: { ddl },
                            set: { d in
                                // 不越截止（与排布规则同一条）：截止早于这块的结束 → 不改，写明原因
                                if d < block.end {
                                    deadlineHint = "截止 \(PlanEditRules.hm(d)) 早于这块的结束 \(PlanEditRules.hm(block.end))——按规则不越截止：先把块拖早，或把截止设晚一点"
                                } else {
                                    deadlineHint = nil
                                    block.deadline = d
                                }
                            }), displayedComponents: [.date, .hourAndMinute])
                        if let deadlineHint {
                            Text(deadlineHint).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Picker("计时方式", selection: $block.timingStyle) {
                        Text("轻计时").tag(TimingStyle.light)
                        Text("番茄钟").tag(TimingStyle.pomodoro)
                        Text("不计时").tag(TimingStyle.none)
                    }
                }
                Section {
                    Button(role: .destructive) { onDelete() } label: {
                        Label("删除（移入回收站，30 天内可找回）", systemImage: "trash")
                    }
                    .accessibilityIdentifier("bc.today.axis.edit.delete")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("编辑")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成", action: onDone)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 420)
        #endif
    }
}
