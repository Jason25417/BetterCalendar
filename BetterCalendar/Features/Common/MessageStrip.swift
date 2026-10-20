//
//  MessageStrip.swift
//  BetterCalendar
//
//  统一消息条（0.28.1，Jason 拍板「统一视觉、不统一位置」）：L3 主动建议 / A+B 状态行 等
//  消息家族共用的视觉语言——图标 + 一句话 + 可选动作。位置各守其位（建议在顶部、回执贴动作），
//  只统一长相：同一套圆角/字号/底色浓度，用户一眼认出「这是 App 在说话」。
//

import SwiftUI

struct MessageStrip<Actions: View>: View {
    var icon: String
    var tint: Color
    var text: String
    var textStyle: Color = .secondary
    @ViewBuilder var actions: () -> Actions

    init(icon: String, tint: Color, text: String, textStyle: Color = .secondary,
         @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }) {
        self.icon = icon
        self.tint = tint
        self.text = text
        self.textStyle = textStyle
        self.actions = actions
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.caption).foregroundStyle(tint)
            Text(text).font(.callout).foregroundStyle(textStyle)
                .fixedSize(horizontal: false, vertical: true)   // W31 自测：旁边是贪婪的 ScrollView 时原因被压成「…」（P4 不让你猜）——整句一定显示全
            Spacer()
            actions()
        }
        .padding(8)
        .background(tint.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
