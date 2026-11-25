import Foundation
import SwiftUI

/// 따라치기 연습: 현재 음을 보여 주고, 마이크로 올바르게 쳤는지 확인한 뒤 다음 음으로 넘어갑니다.
/// 음마다 결과를 기록해 끝나면 마디별 실수, 자주 틀린 음, 박자 흐름을 리포트로 보여 줍니다.
@MainActor
final class PracticeSession: ObservableObject {
    enum Feedback: Equatable {
        case idle
        case waiting
        case correct(clean: Bool)
        case partial(missing: [Int])
        case wrong(played: [Int], expected: [Int])
        case finished
    }

    @Published private(set) var steps: [PracticeStep] = []
    @Published private(set) var results: [StepResult] = []
    @Published private(set) var index = 0
    @Published private(set) var feedback: Feedback = .idle
    @Published private(set) var isListening = false
    @Published private(set) var heard: Set<Int> = []
    @Published private(set) var wrongHeard: Set<Int> = []
    @Published private(set) var level: Float = 0
    @Published private(set) var streak = 0
    @Published private(set) var bestStreak = 0
    /// 한 음에서 오래 머물고 있음 → 도움말 표시
    @Published private(set) var isStuck = false
    /// 진동(햅틱) 신호용 카운터
    @Published private(set) var successTick = 0
    @Published private(set) var errorTick = 0
    @Published private(set) var report: PracticeReport?
    @Published var showReport = false
    @Published var errorMessage: String?
    @Published var sensitivity: Double = 1.0
    @Published var staves: Set<Staff> = Set(Staff.allCases) {
        didSet { rebuild() }
    }
    /// 일부 마디만 연습 (nil = 전체)
    @Published private(set) var focusMeasures: Set<Int>?

    let score: Score
    private let mic = MicAnalyzer()
    private var stepStartedAt = Date()
    private var sessionStartedAt: Date?
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

    var cleanCount: Int { results.filter { $0.status == .clean }.count }
    var mistakeCount: Int { results.reduce(0) { $0 + $1.mistakes } }
    /// 지금까지 친 음 중 한 번에 맞힌 비율 (%)
    var liveAccuracy: Int? {
        let done = results.filter(\.isDone).count
        return done == 0 ? nil : Int((Double(cleanCount) / Double(done) * 100).rounded())
    }

    // MARK: 조작

    func start() {
        guard !isListening else { return }
        Task {
            do {
                try await mic.start()
                isListening = true
                if index >= steps.count { restart() }
                if sessionStartedAt == nil { sessionStartedAt = Date() }
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
        results = Array(repeating: StepResult(), count: steps.count)
        streak = 0
        bestStreak = 0
        report = nil
        sessionStartedAt = isListening ? Date() : nil
        resetStepState()
        feedback = isListening ? .waiting : .idle
    }

    /// 건너뛰기 (기록에는 '건너뜀'으로 남음)
    func next() {
        guard current != nil else { return }
        results[index].status = .skipped
        streak = 0
        moveForward()
    }

    /// 이전 음으로 돌아가 다시 치기
    func previous() {
        guard index > 0 else { return }
        index -= 1
        results[index] = StepResult()
        resetStepState()
        feedback = isListening ? .waiting : .idle
    }

    /// 지금 쳐야 할 음을 들려줌 (그동안 마이크 판정은 잠시 멈춤)
    func playCurrent() {
        guard let step = current else { return }
        results[index].hintUsed = true
        ignoreMic(for: 1.1)
        PianoSynth.shared.preview(Array(step.pitches), seconds: 0.7)
    }

    /// 앱이 소리를 내는 동안 마이크가 그 소리를 연주로 착각하지 않도록
    func ignoreMic(for seconds: TimeInterval) {
        ignoreUntil = Date().addingTimeInterval(seconds)
    }

    /// 지정한 마디만 다시 연습
    func practice(measures: Set<Int>) {
        focusMeasures = measures.isEmpty ? nil : measures
        showReport = false
        rebuild()
    }

    func practiceWholePiece() {
        focusMeasures = nil
        showReport = false
        rebuild()
    }

    // MARK: 판정

    private func rebuild() {
        steps = score.practiceSteps(staves: staves, measures: focusMeasures)
        restart()
    }

    private func resetStepState() {
        stepStartedAt = Date()
        matchStreak = 0
        partialSince = nil
        isStuck = false
    }

    private func handle(_ frame: SpectrumFrame) {
        // 입력 레벨 (화면 표시)
        level = min(1, frame.rms * 12)

        // 어택(건반을 새로 누름) 감지
        if frame.rms > 0.008 && frame.rms > previousRMS * 1.5 {
            lastOnsetAt = frame.time
        }
        previousRMS = frame.rms

        guard isListening, let step = current else { return }

        if !isStuck && frame.time.timeIntervalSince(stepStartedAt) > 12 {
            isStuck = true
        }
        guard frame.time > ignoreUntil else { return }

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

        if analysis.matched == step.pitches && analysis.wrong.isEmpty && attackOK {
            matchStreak += 1
            if matchStreak >= 2 { completeCurrent() }
            return
        }
        // 맞는 음은 다 들리지만 다른 음도 섞여 있음 → 잔향일 수 있으니 조금 더 지켜봄
        if analysis.matched == step.pitches && attackOK {
            matchStreak += 1
            if matchStreak >= 4 { completeCurrent() }
            return
        }
        matchStreak = 0

        let recentAttack = frame.time.timeIntervalSince(lastOnsetAt) < 0.5
        if !analysis.wrong.isEmpty && recentAttack && lastOnsetAt > stepStartedAt {
            feedback = .wrong(played: analysis.wrong.sorted(), expected: step.pitches.sorted())
            if lastMistakeOnset != lastOnsetAt {
                lastMistakeOnset = lastOnsetAt
                recordMistake(played: analysis.wrong, expected: step.pitches)
            }
            partialSince = nil
        } else if !analysis.matched.isEmpty && analysis.matched != step.pitches {
            if partialSince == nil { partialSince = frame.time }
            if let since = partialSince, frame.time.timeIntervalSince(since) > 0.6 {
                feedback = .partial(missing: step.pitches.subtracting(analysis.matched).sorted())
            }
        }
    }

    private func recordMistake(played: [Int], expected: Set<Int>) {
        var r = results[index]
        r.mistakes += 1
        for p in played {
            if let e = MistakeHint.nearestExpected(to: p, in: expected) {
                r.confusions.append(NotePair(expected: e, played: p))
            }
        }
        results[index] = r
        streak = 0
        errorTick += 1
    }

    private func completeCurrent() {
        var r = results[index]
        r.status = r.mistakes == 0 ? .clean : .recovered
        r.onsetTime = lastOnsetAt > stepStartedAt ? lastOnsetAt : Date()
        results[index] = r

        if r.status == .clean {
            streak += 1
            bestStreak = max(bestStreak, streak)
        } else {
            streak = 0
        }
        successTick += 1
        feedback = .correct(clean: r.status == .clean)
        moveForward()
    }

    private func moveForward() {
        index += 1
        resetStepState()
        if index >= steps.count { finish() }
    }

    private func finish() {
        feedback = .finished
        mic.stop()
        isListening = false
        heard = []
        wrongHeard = []
        level = 0
        let elapsed = sessionStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        report = PracticeReport.make(steps: steps, results: results, bestStreak: bestStreak,
                                     elapsed: elapsed, scoreTempo: score.tempo)
        showReport = true
    }
}
