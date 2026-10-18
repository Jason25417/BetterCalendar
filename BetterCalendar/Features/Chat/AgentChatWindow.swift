//
//  AgentChatWindow.swift
//  BetterCalendar
//
//  SPEC §19 A1（Mac）：对话是独立窗口。主窗口工具栏的「对话」按钮打开它，
//  并负责消费 router.openChatRequest（通知点击 / Handoff 请求打开对话时置位）。
//

import SwiftUI

enum AgentChatWindow {
    static let id = "agent-chat"

    #if os(macOS)
    struct OpenButton: View {
        @Bindable var router: AppRouter
        @Environment(\.openWindow) private var openWindow

        var body: some View {
            Button { openWindow(id: AgentChatWindow.id) } label: {
                Label("对话", systemImage: "bubble.left.and.bubble.right")
            }
            .help("跟 BetterCalendar 智能体说话")
            .accessibilityIdentifier("bc.chat.open")
            .onAppear(perform: consume)
            .onChange(of: router.openChatRequest) { _, _ in consume() }
        }

        private func consume() {
            guard router.openChatRequest else { return }
            router.openChatRequest = false
            openWindow(id: AgentChatWindow.id)
        }
    }
    #endif
}
