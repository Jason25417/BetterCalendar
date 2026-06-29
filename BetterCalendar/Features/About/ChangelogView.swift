//
//  ChangelogView.swift
//  BetterCalendar
//
//  应用内更新日志 + 版本/署名。
//

import SwiftUI

struct ChangelogView: View {
    var body: some View {
        List {
            Section {
                Text(AppInfo.copyright)
                LabeledContent("版本", value: AppInfo.version)
            }
            ForEach(Changelog.entries) { entry in
                Section("v\(entry.version) · \(entry.date)") {
                    ForEach(entry.changes, id: \.self) { line in
                        Text(line)
                    }
                }
            }
        }
        .navigationTitle("更新日志")
    }
}
