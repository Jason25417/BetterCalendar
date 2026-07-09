//
//  BuildInfo.swift
//  BetterCalendar
//
//  区分构建（2026-07-09 Jason：内测版和 debug 版跑起来看着一样、分不清）：平台 + 渠道 + 版本(build)。
//  渠道判定：DEBUG 编译宏 → Debug；否则看收据文件名——TestFlight 沙盒收据=sandboxReceipt → 内测；
//  App Store 正式收据 → 发行版。macOS 同理（沙盒收据也叫 sandboxReceipt）。
//

import Foundation

enum BuildInfo {
    static var platform: String {
        #if os(macOS)
        "Mac"
        #else
        "iOS"
        #endif
    }

    enum Channel { case debug, testFlight, release }

    static var channel: Channel {
        #if DEBUG
        return .debug
        #else
        if Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt" { return .testFlight }
        return .release
        #endif
    }

    static var channelLabel: String {
        switch channel {
        case .debug: "Debug"
        case .testFlight: "内测"
        case .release: "发行版"
        }
    }

    /// 非发行版（Debug / 内测）——菜单栏版本标签只在这两种下显示（发行版不打扰用户）。
    static var isPreRelease: Bool { channel != .release }

    static var buildNumber: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
    }

    /// 完整标签：如「iOS · 内测 · v0.25.2 (74)」。
    static var tag: String {
        "\(platform) · \(channelLabel) · v\(AppInfo.version) (\(buildNumber))"
    }
}
