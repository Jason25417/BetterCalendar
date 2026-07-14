//
//  SkinFittingView.swift
//  BetterCalendar
//
//  皮肤试衣间（开发期，美术样品阶段；M8 随开发件整体摘除）——《美术执行Spec》一§三的载体：
//  语义色 4 案 × 计时数字 2 案 × 明暗双面板并排，底色恒定条文 1B 中性阶。
//  样品值来源=美术执行Spec §一（裁定后回写 spec 与 AppTheme）。评审判据：一眼扫读/久看不腻/双模一致。
//

import SwiftUI

// MARK: - 样品数据（dev-only；hex 便于与 Spec 文档一一对照）

private extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// 一个语义色样品（light/dark 各一套；预览恒虚线=形状冗余）。
struct FittingSample: Identifiable {
    struct SchemeSet {
        var bg: Color; var surface: Color; var textPrimary: Color; var textSecondary: Color
        var plannedBG: Color; var plannedFG: Color; var plannedBorder: Color
        var actualBG: Color; var actualFG: Color
        var previewFG: Color
        var accent: Color
    }
    let id: String
    let name: String
    let note: String
    let light: SchemeSet
    let dark: SchemeSet
}

enum FittingSamples {
    /// 中性阶（条文 1B 微暖）——全样品共用底。
    private static func base(light: Bool) -> (Color, Color, Color, Color, Color) {
        light ? (Color(hex: 0xF7F4F0), Color(hex: 0xFFFDFB), Color(hex: 0x211E1B), Color(hex: 0x807870), Color(hex: 0xC97C4E))
              : (Color(hex: 0x1D1B18), Color(hex: 0x292623), Color(hex: 0xF2EFEB), Color(hex: 0xA29A90), Color(hex: 0xD98F5F))
    }

    private static func set(light: Bool,
                            pBG: UInt32, pFG: UInt32, pBD: UInt32,
                            aBG: UInt32, aFG: UInt32, pv: UInt32) -> FittingSample.SchemeSet {
        let (bg, sf, t1, t2, ac) = base(light: light)
        return .init(bg: bg, surface: sf, textPrimary: t1, textSecondary: t2,
                     plannedBG: Color(hex: pBG), plannedFG: Color(hex: pFG), plannedBorder: Color(hex: pBD),
                     actualBG: Color(hex: aBG), actualFG: Color(hex: aFG),
                     previewFG: Color(hex: pv), accent: ac)
    }

    static let all: [FittingSample] = [
        FittingSample(id: "3A-v1", name: "3A-v1 三色相 · 打样版", note: "绿/蓝/橙重选（现状语义的精修）",
            light: set(light: true,  pBG: 0xDFEDE3, pFG: 0x2E5A3C, pBD: 0x86B294, aBG: 0x3E6E9E, aFG: 0xFFFFFF, pv: 0xC77E3A),
            dark:  set(light: false, pBG: 0x28402F, pFG: 0xA9D4B5, pBD: 0x4C6B55, aBG: 0x2E5478, aFG: 0xEAF2FA, pv: 0xD79355)),
        FittingSample(id: "3A-v2", name: "3A-v2 三色相 · 沉稳版", note: "同三色相、饱和更低",
            light: set(light: true,  pBG: 0xE2ECE6, pFG: 0x40634F, pBD: 0x93AF9F, aBG: 0x4A6B8A, aFG: 0xFFFFFF, pv: 0xB8823F),
            dark:  set(light: false, pBG: 0x263830, pFG: 0x9FC4AC, pBD: 0x46604F, aBG: 0x33506E, aFG: 0xE6EEF7, pv: 0xC98E4F)),
        FittingSample(id: "3B-v1", name: "3B-v1 同族双档 · 青瓷", note: "计划=淡档描边 / 实际=深档实心 / 预览=中性虚线",
            light: set(light: true,  pBG: 0xE4EDEF, pFG: 0x2F565F, pBD: 0x8FB4BC, aBG: 0x3E7482, aFG: 0xFFFFFF, pv: 0x8A8A90),
            dark:  set(light: false, pBG: 0x24363B, pFG: 0xA5CBD3, pBD: 0x44626A, aBG: 0x2F5E6B, aFG: 0xE3F0F3, pv: 0x9A9AA1)),
        FittingSample(id: "3B-v2", name: "3B-v2 同族双档 · 黛蓝", note: "同上、族相换黛蓝",
            light: set(light: true,  pBG: 0xE3E9F2, pFG: 0x3D5570, pBD: 0x9AACC4, aBG: 0x46618C, aFG: 0xFFFFFF, pv: 0x8A8A90),
            dark:  set(light: false, pBG: 0x252E3C, pFG: 0xAEC2DE, pBD: 0x485B76, aBG: 0x38517A, aFG: 0xE7EDF7, pv: 0x9A9AA1)),
    ]
}

// MARK: - 试衣间

struct SkinFittingView: View {
    @State private var sampleID = FittingSamples.all[0].id
    @State private var roundedDigits = true   // 条文 8 实测项②：a=off / b=on

    private var sample: FittingSample {
        FittingSamples.all.first { $0.id == sampleID } ?? FittingSamples.all[0]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Picker("语义色", selection: $sampleID) {
                    ForEach(FittingSamples.all) { s in Text(s.name).tag(s.id) }
                }
                .frame(maxWidth: 320)
                Toggle("计时数字 Rounded（b 案）", isOn: $roundedDigits)
                Spacer()
                Text("评审：一眼扫读 · 久看不腻 · 双模一致")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(sample.note).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 14) {
                pane(set: sample.light, label: "Light")
                pane(set: sample.dark, label: "Dark")
            }
            Text("底色恒定=条文 1B 微暖中性阶；值与《美术执行Spec》§一 一一对照；裁定后回写 Spec → 令牌表 v1。")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(minWidth: 760, minHeight: 560)
        .navigationTitle("皮肤试衣间（开发期）")
    }

    // 单面板：一屏浓缩「排日程行 × 三语义 + 执行数字展位 + 收尾情感时刻」
    private func pane(set s: FittingSample.SchemeSet, label: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label).font(.caption.bold()).foregroundStyle(s.textSecondary)

            // ① 排日程行三语义（形状冗余恒定：计划描边/实际实心/预览虚线）
            VStack(alignment: .leading, spacing: 6) {
                mockRow(title: "晨间写作（计划）", time: "09:00–11:00",
                        fg: s.plannedFG, bg: s.plannedBG, border: s.plannedBorder, dashed: false)
                mockRow(title: "健身（实际）", time: "17:00–18:00",
                        fg: s.actualFG, bg: s.actualBG, border: nil, dashed: false)
                mockRow(title: "读论文（预览 · 从现在起）", time: "19:00–20:00",
                        fg: s.previewFG, bg: nil, border: s.previewFG, dashed: true)
            }
            .padding(10)
            .background(s.surface, in: RoundedRectangle(cornerRadius: 12))

            // ② 执行数字展位（条文 8：tabular 恒开；a/b 由开关切换）
            VStack(spacing: 2) {
                Text("改代码").font(.subheadline.weight(.semibold)).foregroundStyle(s.textPrimary)
                Text("24:13")
                    .font(.system(size: 42, weight: .semibold,
                                  design: roundedDigits ? .rounded : .default))
                    .monospacedDigit()
                    .foregroundStyle(s.textPrimary)
                Text("番茄 2/4 · 到 16:00").font(.caption2).foregroundStyle(s.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(10)
            .background(s.surface, in: RoundedRectangle(cornerRadius: 12))

            // ③ 情感时刻（accent 的唯一舞台，条文 2）
            HStack {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(s.accent)
                Text("今天做成 4 件 · 有效投入 5.2h").font(.caption).foregroundStyle(s.textPrimary)
                Spacer()
                Text("完成复盘")
                    .font(.caption.bold()).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(s.accent, in: Capsule())
            }
            .padding(10)
            .background(s.surface, in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(s.bg, in: RoundedRectangle(cornerRadius: 14))
    }

    private func mockRow(title: String, time: String, fg: Color, bg: Color?, border: Color?, dashed: Bool) -> some View {
        HStack {
            Text(title).font(.caption)
            Spacer()
            Text(time).font(.caption2).monospacedDigit().opacity(0.75)
        }
        .foregroundStyle(fg)
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(bg ?? .clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            if let border {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(border, style: StrokeStyle(lineWidth: 1.5, dash: dashed ? [4, 3] : []))
            }
        }
    }
}
