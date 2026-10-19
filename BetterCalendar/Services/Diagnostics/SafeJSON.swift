//
//  SafeJSON.swift
//  BetterCalendar
//
//  W25（2026-10-19）：`JSONSerialization.data(withJSONObject:)` 遇到 JSON 表达不了的值（Data / Date / NaN / 自定义类型…）
//  抛的是 **ObjC 异常**（NSInvalidArgumentException），Swift 的 try/catch 接不住：异常越过 Swift 帧，
//  主 actor 任务半路消失（不成功也不报错）、单测宿主无限挂起（DataMaintenance.captureLocalPreferences 事故，见 main cd5d03b）。
//  所以全 App 一律走这里：先用不抛异常的 `isValidJSONObject` 判定，不合法就抛**可接住的** Swift 错误（可见失败）。
//  架构测试（W25IsolationTests）守住：App 源码里除本文件外不许直接调 JSONSerialization.data(withJSONObject:)。
//

import Foundation

nonisolated enum SafeJSON {
    struct InvalidObject: Error, LocalizedError, Equatable {
        var typeName: String
        var errorDescription: String? { "内容含 JSON 表达不了的值（\(typeName)），没有写出" }
    }

    static func data(withJSONObject object: Any, options: JSONSerialization.WritingOptions = []) throws -> Data {
        // 顶层是标量（fragmentsAllowed）时 isValidJSONObject 不认，包一层数组再判（判定本身绝不抛异常）。
        let valid = options.contains(.fragmentsAllowed)
            ? JSONSerialization.isValidJSONObject([object])
            : JSONSerialization.isValidJSONObject(object)
        guard valid else { throw InvalidObject(typeName: String(describing: type(of: object))) }
        return try JSONSerialization.data(withJSONObject: object, options: options)
    }
}
