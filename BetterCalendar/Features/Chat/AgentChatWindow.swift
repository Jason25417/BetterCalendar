//
//  AgentChatWindow.swift
//  BetterCalendar
//
//  SPEC §19 A1（Mac）：对话的独立窗口 id。W19 起主窗口里有「智能体」页（同一个 AgentChatView），
//  独立窗口只是想并排时的便利，入口在系统「窗口」菜单；原主窗口工具栏「对话」按钮已退役。
//

import SwiftUI

enum AgentChatWindow {
    static let id = "agent-chat"
}
