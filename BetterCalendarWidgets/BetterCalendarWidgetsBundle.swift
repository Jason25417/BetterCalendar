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
        BetterCalendarWidgets()
        BetterCalendarWidgetsControl()
        BetterCalendarWidgetsLiveActivity()
    }
}
