//
//  TestHost.swift
//  BetterCalendar
//
//  可靠的「是否运行在测试宿主里」检测（2026-07-21 抽出，实锤修复）。
//
//  为什么不能用 `NSClassFromString("XCTestCase")`：本项目单测用 **Swift Testing**（@Test 宏），
//  它的 test host 里**没有** XCTestCase 这个 ObjC 类 → 该检测恒返回 nil、闸恒失效。
//  受害史：CalendarSettings（恒 fake 闸失效→单测走真 EventKit 挂死 runner）、
//  FoundationModelsPlanRefiner（「单测不跑端侧模型」闸失效→真跑 3B 推理挂/慢）、BehaviorLog（多写日志，无害）。
//
//  可靠依据：Xcode 的 test host（XCTest 与 Swift Testing 共用同一 runner）都会设
//  `XCTestConfigurationFilePath` 环境变量（2026-07-21 实测有效）；再叠两个同族变量与旧类检测做双保险
//  （覆盖命令行 `swift test` 等旁路）。
//
import Foundation

nonisolated enum TestHost {   // W21：纯环境变量读取，标 nonisolated 供功能使用探针（非主线程可调）使用
    static var isActive: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil
            || env["XCTestBundlePath"] != nil
            || env["XCTestSessionIdentifier"] != nil
            || NSClassFromString("XCTestCase") != nil
    }
}
