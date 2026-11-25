import Combine
import Foundation

/// 악보를 피아노 소리로 재생합니다.
@MainActor
final class ScorePlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var activeEventIDs: Set<UUID> = []
    @Published private(set) var focusEventID: UUID?
    @Published var tempoScale: Double = 1.0
    @Published var staves: Set<Staff> = Set(Staff.allCases)

    private var task: Task<Void, Never>?

    private struct Action {
        let time: Double
        let isOn: Bool
        let eventID: UUID
        let staff: Staff
        /// 이 동작에서 실제로 누르거나 뗄 음 (붙임줄로 이어지는 음은 빠짐)
        let pitches: [Int]
        let velocity: Double
    }

    func toggle(_ score: Score, fromMeasure: Int = 0) {
        if isPlaying { stop() } else { play(score, fromMeasure: fromMeasure) }
    }

    func play(_ score: Score, fromMeasure: Int = 0) {
        stop()
        PianoSynth.shared.start()

        let actions = Self.actions(for: score, fromMeasure: fromMeasure, staves: staves,
                                   secondsPerBeat: 60.0 / (Double(score.tempo) * tempoScale))
        guard !actions.isEmpty else { return }

        isPlaying = true
        let startDate = Date().addingTimeInterval(0.1)
        task = Task { [weak self] in
            for action in actions {
                let wait = action.time - Date().timeIntervalSince(startDate)
                if wait > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                }
                if Task.isCancelled { return }
                guard let self else { return }
                if action.isOn {
                    action.pitches.forEach { PianoSynth.shared.noteOn($0, velocity: action.velocity) }
                    self.activeEventIDs.insert(action.eventID)
                    if action.staff == .treble || self.focusEventID == nil {
                        self.focusEventID = action.eventID
                    }
                } else {
                    action.pitches.forEach { PianoSynth.shared.noteOff($0) }
                    self.activeEventIDs.remove(action.eventID)
                }
            }
            self?.finish()
        }
    }

    /// 도돌이표·붙임줄·스타카토·악센트·페르마타·셈여림을 반영한 재생 순서
    private static func actions(for score: Score, fromMeasure: Int, staves: Set<Staff>,
                                secondsPerBeat: Double) -> [Action] {
        let order = score.playbackOrder()
        let first = order.firstIndex(of: fromMeasure) ?? 0
        let length = score.measureLength
        var actions: [Action] = []

        // 손마다 음표를 연주 순서대로 펼침
        var seqs: [Staff: [(event: NoteEvent, beat: Double)]] = [:]
        for staff in Staff.allCases {
            var seq: [(event: NoteEvent, beat: Double)] = []
            for (k, mi) in order[first...].enumerated() {
                var beat = Double(k) * length
                for e in score.measures[mi].events(on: staff) {
                    seq.append((e, beat))
                    beat += e.duration
                }
            }
            seqs[staff] = seq
        }

        // 페르마타: 그 음이 끝나는 지점에서 양손 모두 잠시 늘임
        var fermatas: [(end: Double, extra: Double)] = []
        for seq in seqs.values {
            for item in seq where item.event.has(.fermata) {
                fermatas.append((item.beat + item.event.duration, item.event.duration * 0.7))
            }
        }
        func seconds(_ beat: Double) -> Double {
            let extra = fermatas.filter { $0.end <= beat + 0.0001 }.reduce(0) { $0 + $1.extra }
            return (beat + extra) * secondsPerBeat
        }

        for staff in Staff.allCases where staves.contains(staff) {
            let seq = seqs[staff] ?? []
            var velocity = 0.72
            var tiedIn = Set<Int>()
            for (k, item) in seq.enumerated() {
                let e = item.event
                if let d = e.dynamic { velocity = d.velocity }
                guard !e.isRest else { tiedIn = []; continue }

                var v = velocity
                if e.has(.accent) { v = min(1, v + 0.18) }

                let next = k + 1 < seq.count ? seq[k + 1].event : nil
                let tiedOut: Set<Int> = e.has(.tie) ? Set(e.pitches).intersection(next?.pitches ?? []) : []

                let on = seconds(item.beat)
                let end = e.has(.staccato) ? on + e.duration * 0.45 * secondsPerBeat
                                           : seconds(item.beat + e.duration)
                let off = max(on + 0.03, end - (e.has(.tenuto) || !tiedOut.isEmpty ? 0.005 : 0.02))

                let press = e.pitches.filter { !tiedIn.contains($0) }
                let release = e.pitches.filter { !tiedOut.contains($0) }
                actions.append(Action(time: on, isOn: true, eventID: e.id, staff: staff, pitches: press, velocity: v))
                actions.append(Action(time: off, isOn: false, eventID: e.id, staff: staff, pitches: release, velocity: v))
                tiedIn = tiedOut
            }
        }

        actions.sort { a, b in
            if abs(a.time - b.time) < 0.0001 { return !a.isOn && b.isOn }
            return a.time < b.time
        }
        return actions
    }

    func stop() {
        task?.cancel()
        task = nil
        PianoSynth.shared.allNotesOff()
        finish()
    }

    private func finish() {
        isPlaying = false
        activeEventIDs = []
    }
}
