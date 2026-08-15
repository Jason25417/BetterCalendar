//
//  LongTaskZoneTests.swift
//  BetterCalendarTests
//
//  一池两区（E5a）：zone 口径 / addTodo 幂等与长期归属让路 / add 跨区升格 / discard 只删待办区。
//  内存库显式 cloudKitDatabase: .none（zone setup 竞态教训）。
//

import Testing
import Foundation
import SwiftData
@testable import BetterCalendar

@MainActor
@Suite struct LongTaskZoneTests {
    /// ⚠️ 容器必须随 fixture 活满整个测试：ModelContext 不持有 ModelContainer，
    /// 容器出作用域=内存库拆除，store 下一次 insert/save 即 EXC_BREAKPOINT（2026-08-15 实锤）。
    private struct Fixture {
        let store: LongTaskStore
        let container: ModelContainer   // 只为保活
    }
    private func makeFixture() throws -> Fixture {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: LongTask.self, configurations: config)
        return Fixture(store: LongTaskStore(context: container.mainContext), container: container)
    }

    /// items=长期区在途、todos=待办区，两区互不串；老数据（默认 zone）自动落长期区。
    @Test func zoneSeparation() throws {
        let f = try makeFixture()
        let store = f.store
        store.add(title: "准备 GRE")
        store.addTodo(title: "给自行车打气")
        #expect(store.items.count == 1 && store.items.first?.title == "准备 GRE")
        #expect(store.todos.count == 1 && store.todos.first?.title == "给自行车打气")
        #expect(store.todoItems().first?.poolZone == .todo)
        // 默认 init 不传 zone = 长期区（CloudKit 老数据迁移语义）
        #expect(LongTask(title: "旧数据").poolZone == .longterm)
    }

    /// addTodo 幂等：同名待办条目只更新来源日/族，不重复建。
    @Test func addTodoIdempotent() throws {
        let f = try makeFixture()
        let store = f.store
        let day = Calendar.current.startOfDay(for: .now)
        store.addTodo(title: "改简历")
        let again = store.addTodo(title: "改简历", family: "写作", spilledFromDay: day)
        #expect(store.todos.count == 1)
        #expect(again.spilledFromDay == day && again.family == "写作")
    }

    /// 同名长期任务已在 → addTodo 不建待办条目、返回长期项（溢出的池块回它自己的家）。
    @Test func addTodoYieldsToLongtermHome() throws {
        let f = try makeFixture()
        let store = f.store
        let home = store.add(title: "写论文")
        let got = store.addTodo(title: "写论文", spilledFromDay: .now)
        #expect(got.id == home.id && got.poolZone == .longterm)
        #expect(store.todos.isEmpty)
    }

    /// add 跨区幂等：同名条目在待办区 → 升格为长期区并回填字段，不重建。
    @Test func addUpgradesTodoEntry() throws {
        let f = try makeFixture()
        let store = f.store
        store.addTodo(title: "学 Rust", spilledFromDay: .now)
        let ddl = Calendar.current.date(byAdding: .day, value: 30, to: .now)!
        let upgraded = store.add(title: "学 Rust", deadline: ddl)
        #expect(store.todos.isEmpty && store.items.count == 1)
        #expect(upgraded.poolZone == .longterm && upgraded.deadline == ddl)
        #expect(upgraded.spilledFromDay == nil, "升格后不再是溢出物")
    }

    /// discard 只删待办区；对长期区 no-op（长期区维持「无删除只改状态」裁决）。
    @Test func discardGuardedToTodoZone() throws {
        let f = try makeFixture()
        let store = f.store
        let keep = store.add(title: "长期的事")
        let drop = store.addTodo(title: "小愿望")
        store.discard(keep)
        #expect(store.items.count == 1, "长期区 discard 必须 no-op")
        store.discard(drop)
        #expect(store.todos.isEmpty)
    }

    /// 待办区排序：溢出物在前（新溢出的更前），手动愿望在后。
    @Test func todoOrderingSpilledFirst() throws {
        let f = try makeFixture()
        let store = f.store
        let d1 = Calendar.current.date(byAdding: .day, value: -2, to: .now)!
        let d2 = Calendar.current.date(byAdding: .day, value: -1, to: .now)!
        store.addTodo(title: "手动愿望")
        store.addTodo(title: "旧溢出", spilledFromDay: d1)
        store.addTodo(title: "新溢出", spilledFromDay: d2)
        #expect(store.todos.map(\.title) == ["新溢出", "旧溢出", "手动愿望"])
    }

    /// addTodo 保 DDL（E5d）：带 DDL 的溢出物收池后晨间可置顶。
    @Test func addTodoKeepsDeadline() throws {
        let f = try makeFixture()
        let ddl = Calendar.current.date(byAdding: .day, value: 2, to: .now)!
        let e = f.store.addTodo(title: "交报销单", spilledFromDay: .now, deadline: ddl)
        #expect(e.deadline == ddl)
    }
}
