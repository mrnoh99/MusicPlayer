import Foundation

// MARK: - 한 단계(음/화음)의 연주 기록

struct StepResult: Equatable {
    enum Status: Equatable {
        case pending      // 아직 안 침
        case clean        // 한 번에 맞힘
        case recovered    // 틀린 뒤 맞힘
        case skipped      // 건너뜀
    }

    var status: Status = .pending
    /// 이 음에서 틀린 횟수 (새로 건반을 누른 횟수 기준)
    var mistakes = 0
    /// (쳐야 할 음, 실제로 친 음) 기록
    var confusions: [NotePair] = []
    /// 맞게 친 순간 (건반을 누른 시각)
    var onsetTime: Date?
    /// '들어보기'를 사용했는지
    var hintUsed = false

    var isDone: Bool { status != .pending }
}

struct NotePair: Hashable {
    let expected: Int
    let played: Int
}

// MARK: - 틀린 음 힌트

enum MistakeHint {
    /// 친 음에서 가장 가까운 '쳐야 할 음'
    static func nearestExpected(to played: Int, in expected: Set<Int>) -> Int? {
        expected.min { abs($0 - played) < abs($1 - played) }
    }

    /// "반음 높아요 → 바로 왼쪽 건반" 같은 짧은 안내
    static func text(played: Int, expected: Int) -> String {
        let d = played - expected
        guard d != 0 else { return "" }
        let higher = d > 0
        let dir = higher ? "왼쪽" : "오른쪽"
        let hl = higher ? "높아요" : "낮아요"
        let n = abs(d)

        if n % 12 == 0 {
            let oct = n / 12
            return "\(oct == 1 ? "한" : "\(oct)") 옥타브 \(higher ? "높게" : "낮게") 쳤어요 → 같은 이름의 \(dir) 건반"
        }
        var s: String
        switch n {
        case 1: s = "반음 \(hl) → 바로 \(dir) 건반"
        case 2: s = "온음(건반 두 칸) \(hl) → \(dir)으로 두 칸"
        default: s = "\(n)반음 \(hl) → \(dir)으로 \(n)칸"
        }
        if n == 1 {
            if PianoKeyboardView.isBlack(expected) { s += " (♯/♭ 임시표를 확인하세요)" }
            else if PianoKeyboardView.isBlack(played) { s += " (검은 건반이 아니라 흰 건반이에요)" }
        }
        return s
    }

    static func text(played: [Int], expected: Set<Int>) -> String {
        guard let p = played.first, let e = nearestExpected(to: p, in: expected) else { return "" }
        return text(played: p, expected: e)
    }
}

extension NoteName {
    /// "E4(미)"
    static func display(_ midi: Int, preferFlats: Bool = false) -> String {
        "\(name(midi, preferFlats: preferFlats))(\(korean(midi)))"
    }

    static func display(_ pitches: [Int], preferFlats: Bool = false) -> String {
        pitches.map { display($0, preferFlats: preferFlats) }.joined(separator: ", ")
    }
}

// MARK: - 연주 결과 리포트

struct PracticeReport: Equatable {
    struct MeasureStat: Identifiable, Equatable {
        let measure: Int          // 0 부터
        var notes = 0
        var mistakes = 0
        var skipped = 0
        var id: Int { measure }

        enum Grade { case perfect, minor, weak }
        var grade: Grade {
            if skipped > 0 || mistakes >= 3 { return .weak }
            return mistakes == 0 ? .perfect : .minor
        }
    }

    struct Confusion: Identifiable, Equatable {
        let pair: NotePair
        let count: Int
        var id: NotePair { pair }
    }

    struct Rhythm: Equatable {
        /// 실제로 친 빠르기 (4분음표 기준 BPM)
        let userBPM: Int
        /// 박자 간격이 고르게 유지된 비율 (0~100)
        let steadiness: Int
        let rushedMeasures: [Int]
        let draggedMeasures: [Int]
    }

    let totalSteps: Int
    let clean: Int
    let recovered: Int
    let skipped: Int
    let totalMistakes: Int
    let bestStreak: Int
    let elapsed: TimeInterval
    let scoreTempo: Int
    let measureStats: [MeasureStat]
    let confusions: [Confusion]
    let rhythm: Rhythm?

    /// 한 번에 맞힌 비율
    var accuracy: Int { totalSteps == 0 ? 0 : Int((Double(clean) / Double(totalSteps) * 100).rounded()) }
    /// 건너뛰지 않고 친 비율
    var completion: Int {
        totalSteps == 0 ? 0 : Int((Double(clean + recovered) / Double(totalSteps) * 100).rounded())
    }

    var weakMeasures: [MeasureStat] {
        measureStats.filter { $0.mistakes + $0.skipped > 0 }
            .sorted { ($0.mistakes + $0.skipped * 2, -$0.measure) > ($1.mistakes + $1.skipped * 2, -$1.measure) }
    }

    var stars: Int {
        if accuracy >= 90 && skipped == 0 { return 3 }
        if accuracy >= 70 && completion >= 90 { return 2 }
        return 1
    }

    var headline: String {
        switch stars {
        case 3: return accuracy == 100 ? "완벽해요! 실수 없이 끝까지 연주했어요" : "훌륭해요! 거의 완벽한 연주예요"
        case 2: return "잘했어요! 몇 군데만 다듬으면 돼요"
        default: return "좋은 시작이에요. 틀린 마디를 천천히 반복해 봐요"
        }
    }

    func tips(preferFlats: Bool) -> [String] {
        var t: [String] = []
        let weak = weakMeasures.prefix(3).map { "\($0.measure + 1)" }
        if !weak.isEmpty {
            t.append("\(weak.joined(separator: ", "))마디에서 실수가 많았어요. 그 마디만 천천히 3번 반복한 뒤 앞뒤 마디와 이어서 쳐 보세요.")
        }
        if let c = confusions.first {
            let e = NoteName.display(c.pair.expected, preferFlats: preferFlats)
            let p = NoteName.display(c.pair.played, preferFlats: preferFlats)
            t.append("\(e) 자리에서 \(p)를 \(c.count)번 쳤어요. \(MistakeHint.text(played: c.pair.played, expected: c.pair.expected)).")
        }
        if confusions.contains(where: { abs($0.pair.played - $0.pair.expected) % 12 == 0 }) {
            t.append("옥타브를 헷갈린 음이 있어요. 가온 도(C4) 위치를 기준으로 손 위치를 먼저 잡아 보세요.")
        }
        if let r = rhythm {
            if r.steadiness < 60 {
                t.append("음과 음 사이 간격이 고르지 않아요. 메트로놈을 느리게(♩=\(max(40, r.userBPM - 10))) 켜고 일정하게 쳐 보세요.")
            }
            if Double(r.userBPM) < Double(scoreTempo) * 0.6 {
                t.append("지금은 악보 빠르기(♩=\(scoreTempo))보다 많이 느려요. 실수가 줄면 조금씩 빠르게 쳐 보세요.")
            }
        }
        if t.isEmpty {
            t.append(stars == 3 ? "다음에는 악보 빠르기에 맞춰 더 매끄럽게 연주해 보세요." : "천천히, 정확하게 치는 것이 가장 빠른 연습이에요.")
        }
        return t
    }

    // MARK: 만들기

    static func make(steps: [PracticeStep], results: [StepResult], bestStreak: Int,
                     elapsed: TimeInterval, scoreTempo: Int) -> PracticeReport {
        var clean = 0, recovered = 0, skipped = 0, mistakes = 0
        var measures: [Int: MeasureStat] = [:]
        var confusionCounts: [NotePair: Int] = [:]

        for (step, r) in zip(steps, results) {
            var m = measures[step.measureIndex] ?? MeasureStat(measure: step.measureIndex)
            m.notes += 1
            m.mistakes += r.mistakes
            switch r.status {
            case .clean: clean += 1
            case .recovered: recovered += 1
            case .skipped, .pending: skipped += 1; m.skipped += 1
            }
            mistakes += r.mistakes
            for c in r.confusions { confusionCounts[c, default: 0] += 1 }
            measures[step.measureIndex] = m
        }

        let confusions = confusionCounts
            .map { Confusion(pair: $0.key, count: $0.value) }
            .sorted { ($0.count, -$0.pair.expected) > ($1.count, -$1.pair.expected) }
            .prefix(3)

        return PracticeReport(
            totalSteps: steps.count, clean: clean, recovered: recovered, skipped: skipped,
            totalMistakes: mistakes, bestStreak: bestStreak, elapsed: elapsed, scoreTempo: scoreTempo,
            measureStats: measures.values.sorted { $0.measure < $1.measure },
            confusions: Array(confusions),
            rhythm: analyzeRhythm(steps: steps, results: results))
    }

    /// 실수 없이 이어 친 음들의 간격으로 빠르기와 박자 안정도를 계산
    static func analyzeRhythm(steps: [PracticeStep], results: [StepResult]) -> Rhythm? {
        var samples: [(secPerBeat: Double, measure: Int)] = []
        for i in 1..<max(1, steps.count) {
            let a = results[i - 1], b = results[i]
            guard b.status == .clean, a.status == .clean, !b.hintUsed, !a.hintUsed,
                  let t0 = a.onsetTime, let t1 = b.onsetTime else { continue }
            let beats = steps[i].start - steps[i - 1].start
            let sec = t1.timeIntervalSince(t0)
            guard beats > 0, sec > 0.05, sec < 6 else { continue }
            samples.append((sec / beats, steps[i].measureIndex))
        }
        guard samples.count >= 4 else { return nil }

        let sorted = samples.map(\.secPerBeat).sorted()
        let median = sorted[sorted.count / 2]
        guard median > 0 else { return nil }

        var steady = 0
        var rushed = Set<Int>(), dragged = Set<Int>()
        for s in samples {
            let ratio = s.secPerBeat / median
            if ratio >= 0.75 && ratio <= 1.33 { steady += 1 }
            if ratio < 0.65 { rushed.insert(s.measure) }
            if ratio > 1.6 { dragged.insert(s.measure) }
        }
        return Rhythm(userBPM: Int((60 / median).rounded()),
                      steadiness: Int((Double(steady) / Double(samples.count) * 100).rounded()),
                      rushedMeasures: rushed.sorted(), draggedMeasures: dragged.sorted())
    }
}
