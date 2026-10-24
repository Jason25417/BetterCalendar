//
//  DictationSegmentsTests.swift
//  BetterCalendarTests
//
//  0.74.1（Jason 2026-10-24）：苹果听写停顿后从头开一段，前面说的不能被后一段盖掉。
//

import Testing
@testable import BetterCalendar

@Suite struct DictationSegmentsTests {
    @Test func segmentMarkedEndedIsKept() {
        var s = DictationSegments()
        _ = s.receive("明天", segmentEnded: false)
        _ = s.receive("明天下午开会", segmentEnded: false)
        #expect(s.receive("明天下午开会。", segmentEnded: true) == "明天下午开会。")
        _ = s.receive("然后", segmentEnded: false)
        #expect(s.receive("然后去跑步", segmentEnded: false) == "明天下午开会。然后去跑步")
    }

    @Test func restartWithoutMetadataStillKeepsEarlierSegment() {
        var s = DictationSegments()
        _ = s.receive("把写论文挪到晚上", segmentEnded: false)
        #expect(s.receive("再", segmentEnded: false) == "把写论文挪到晚上再")          // 开头对不上且更短 → 新的一段
        #expect(s.receive("再加个跑步", segmentEnded: false) == "把写论文挪到晚上再加个跑步")
    }

    @Test func revisionsOfTheSameSegmentReplaceIt() {
        var s = DictationSegments()
        _ = s.receive("今天下午", segmentEnded: false)
        #expect(s.receive("今天下五三点", segmentEnded: false) == "今天下五三点")
        #expect(s.receive("今天下午三点", segmentEnded: false) == "今天下午三点")
    }

    @Test func duplicateOrWholeTextFinalsAreNotDoubled() {
        var s = DictationSegments()
        _ = s.receive("第一句", segmentEnded: true)
        #expect(s.receive("第一句", segmentEnded: true) == "第一句")                 // 段尾结果又送了一遍
        _ = s.receive("第二句", segmentEnded: true)
        #expect(s.receive("第一句第二句", segmentEnded: false) == "第一句第二句")     // 最后给了整段全文
    }

    @Test func spaceOnlyBetweenLatinWords() {
        #expect(DictationSegments.join("call", "Gregory") == "call Gregory")
        #expect(DictationSegments.join("开会", "然后") == "开会然后")
        #expect(DictationSegments.join("Zoom", "开会") == "Zoom开会")
    }
}
