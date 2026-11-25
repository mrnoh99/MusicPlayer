import Foundation
import SwiftUI

/// 따라치기 연습: 현재 음을 보여 주고, 마이크로 올바르게 쳤는지 확인한 뒤 다음 음으로 넘어갑니다.
@MainActor
final class PracticeSession: ObservableObject {
    enum Feedback: Equatable {
        case idle
        case waiting
        case correct
        case partial(missing: [Int])
        case wrong(played: [Int], expected: [Int])
        case finished
    }

    @Published private(set) var steps: [PracticeStep] = []
    @Published private(set) var index = 0
    @Published private(set) var feedback: Feedback = .idle
    @Published private(set) var isListening = false
    @Published private(set) var correctCount = 0
    @Published private(set) var mistakeCount = 0
    @Published private(set) var heard: Set<Int> = []
    @Published private(set) var wrongHeard: Set<Int> = []
    @Published private(set) var level: Float = 0
    @Published private(set) var lastCorrectIDs: Set<UUID> = []
    @Published var errorMessage: String?
    @Published var sensitivity: Double = 1.0
    @Published var staves: Set<Staff> = Set(Staff.allCases) {
        didSet { rebuild() }
    }

    private let score: Score
    private let mic = MicAnalyzer()
    private var stepStartedAt = Date()
    private var lastOnsetAt = Date.distantPast
    private var lastMistakeOnset = Date.distantPast
    private var partialSince: Date?
    private var previousRMS: Float = 0
    private var matchStreak = 0
    private var ignoreUntil = Date.distantPast

    init(score: Score) {
        self.score = score
        rebuild()
        mic.onFrame = { [weak self] frame in
            self?.handle(frame)
        }
    }

    var current: PracticeStep? { steps.indices.contains(index) ? steps[index] : nil }
    var progress: Double { steps.isEmpty ? 0 : Double(index) / Double(steps.count) }

    // MARK: 조작

    func start() {
        guard !isListening else { return }
        Task {
            do {
                try await mic.start()
                isListening = true
                if index >= steps.count { restart() }
                feedback = .waiting
                stepStartedAt = Date()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func stop() {
        mic.stop()
        isListening = false
        if feedback != .finished { feedback = .idle }
        heard = []
        wrongHeard = []
        level = 0
    }

    func restart() {
        index = 0
        correctCount = 0
        mistakeCount = 0
        lastCorrectIDs = []
        feedback = isListening ? .waiting : .idle
        stepStartedAt = Date()
    }

    func next() { advance(countAsCorrect: false) }

    func previous() {
        guard index > 0 else { return }
        index -= 1
        stepStartedAt = Date()
        feedback = isListening ? .waiting : .idle
    }

    /// 지금 쳐야 할 음을 들려줌 (그동안 마이크 판정은 잠시 멈춤)
    func playCurrent() {
        guard let step = current else { return }
        ignoreUntil = Date().addingTimeInterval(1.1)
        PianoSynth.shared.preview(Array(step.pitches), seconds: 0.7)
    }

    // MARK: 판정

    private func rebuild() {
        steps = score.practiceSteps(staves: staves)
        restart()
    }

    private func handle(_ frame: SpectrumFrame) {
        // 입력 레벨 (화면 표시)
        level = min(1, frame.rms * 12)

        // 어택(건반을 새로 누름) 감지
        if frame.rms > 0.008 && frame.rms > previousRMS * 1.5 {
            lastOnsetAt = frame.time
        }
        previousRMS = frame.rms

        guard isListening, let step = current, frame.time > ignoreUntil else { return }

        let analysis = NoteMatcher.analyze(frame, expected: step.pitches, sensitivity: sensitivity)
        heard = analysis.matched.union(analysis.wrong)
        wrongHeard = Set(analysis.wrong)

        guard !analysis.isSilent else {
            matchStreak = 0
            return
        }

        // 같은 음을 연달아 쳐야 하면 새 어택이 있어야 인정
        let prev = index > 0 ? steps[index - 1].pitches : []
        let needsNewAttack = !step.pitches.isDisjoint(with: prev)
        let attackOK = !needsNewAttack || lastOnsetAt > stepStartedAt

        if analysis.matched == step.pitches && attackOK {
            matchStreak += 1
            if matchStreak >= 2 {
                advance(countAsCorrect: true)
            }
            return
        }
        matchStreak = 0

        let recentAttack = frame.time.timeIntervalSince(lastOnsetAt) < 0.5
        if !analysis.wrong.isEmpty && recentAttack && lastOnsetAt > stepStartedAt {
            feedback = .wrong(played: analysis.wrong.sorted(), expected: step.pitches.sorted())
            if lastMistakeOnset != lastOnsetAt {
                lastMistakeOnset = lastOnsetAt
                mistakeCount += 1
            }
            partialSince = nil
        } else if !analysis.matched.isEmpty && analysis.matched != step.pitches {
            if partialSince == nil { partialSince = frame.time }
            if let since = partialSince, frame.time.timeIntervalSince(since) > 0.6 {
                feedback = .partial(missing: step.pitches.subtracting(analysis.matched).sorted())
            }
        }
    }

    private func advance(countAsCorrect: Bool) {
        guard let step = current else { return }
        if countAsCorrect {
            correctCount += 1
            lastCorrectIDs = step.eventIDs
            feedback = .correct
        }
        matchStreak = 0
        partialSince = nil
        index += 1
        stepStartedAt = Date()
        if index >= steps.count {
            feedback = .finished
            mic.stop()
            isListening = false
        }
    }
}
