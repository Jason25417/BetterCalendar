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
        // 目前只有 Live Activity（灵动岛 + 锁屏计时）；主屏小组件（今日计划/当前块）见 SPEC §5.7，后做。
        BetterCalendarWidgetsLiveActivity()
    }
}
