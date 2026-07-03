//
//  BetterCalendarWidgetsBundle.swift
//  BetterCalendarWidgets
//
//  Created by Jason Tu on 7/1/26.
//

import WidgetKit
import SwiftUI

@main
struct BetterCalendarWidgetsBundle: WidgetBundle {
    var body: some Widget {
        BetterCalendarTodayWidget()          // 主屏「今天」：正在做/接下来/今日做成（v0.11）
        BetterCalendarControls()             // Control Center：完成当前/下一件（v0.11）
        BetterCalendarWidgetsLiveActivity()  // 灵动岛 + 锁屏实时计时
    }
}
