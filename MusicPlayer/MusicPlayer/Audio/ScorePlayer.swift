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
        let event: TimedEvent
    }

    func toggle(_ score: Score, fromMeasure: Int = 0) {
        if isPlaying { stop() } else { play(score, fromMeasure: fromMeasure) }
    }

    func play(_ score: Score, fromMeasure: Int = 0) {
        stop()
        PianoSynth.shared.start()

        let offset = Double(fromMeasure) * score.measureLength
        let secondsPerBeat = 60.0 / (Double(score.tempo) * tempoScale)
        let events = score.timeline(staves: staves).filter { $0.measureIndex >= fromMeasure }
        guard !events.isEmpty else { return }

        var actions: [Action] = []
        for e in events {
            let on = (e.start - offset) * secondsPerBeat
            let off = max(on + 0.03, (e.start - offset + e.duration) * secondsPerBeat - 0.02)
            actions.append(Action(time: on, isOn: true, event: e))
            actions.append(Action(time: off, isOn: false, event: e))
        }
        actions.sort { a, b in
            if abs(a.time - b.time) < 0.0001 { return !a.isOn && b.isOn }
            return a.time < b.time
        }

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
                    action.event.pitches.forEach { PianoSynth.shared.noteOn($0) }
                    self.activeEventIDs.insert(action.event.id)
                    if action.event.staff == .treble || self.focusEventID == nil {
                        self.focusEventID = action.event.id
                    }
                } else {
                    action.event.pitches.forEach { PianoSynth.shared.noteOff($0) }
                    self.activeEventIDs.remove(action.event.id)
                }
            }
            self?.finish()
        }
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
