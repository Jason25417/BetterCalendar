//
//  HomeViewModel.swift
//  BetterCalendar
//

import Foundation
import Observation

@Observable
final class HomeViewModel {
    private let arrangeDay: ArrangeDayUseCase

    var inputText: String = ""
    var decision: PlanDecision?
    var isWorking: Bool = false
    var errorText: String?

    init(arrangeDay: ArrangeDayUseCase) {
        self.arrangeDay = arrangeDay
    }

    func arrange() async {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isWorking = true
        errorText = nil
        do {
            decision = try await arrangeDay(text: trimmed)
        } catch {
            errorText = "排程失败：\(error.localizedDescription)"
        }
        isWorking = false
    }
}
