import Foundation

/// 높은음자리표(오른손) / 낮은음자리표(왼손)
enum Staff: String, Codable, CaseIterable, Identifiable {
    case treble
    case bass

    var id: String { rawValue }
    var label: String { self == .treble ? "오른손" : "왼손" }
}

/// 하나의 음표(또는 화음) 혹은 쉼표. pitches 가 비어 있으면 쉼표.
struct NoteEvent: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    /// MIDI 번호 (가온 C = 60)
    var pitches: [Int]
    /// 4분음표 = 1.0 박
    var duration: Double
    var staff: Staff

    var isRest: Bool { pitches.isEmpty }

    static func rest(_ duration: Double, staff: Staff) -> NoteEvent {
        NoteEvent(pitches: [], duration: duration, staff: staff)
    }
}

struct Measure: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var events: [NoteEvent]

    func events(on staff: Staff) -> [NoteEvent] {
        events.filter { $0.staff == staff }
    }
}

struct Score: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var composer: String = ""
    var tempo: Int = 90
    var beatsPerMeasure: Int = 4
    var beatUnit: Int = 4
    /// 조표: 양수 = 샵 개수, 음수 = 플랫 개수
    var keyFifths: Int = 0
    var measures: [Measure]
    var createdAt: Date = Date()

    /// 한 마디의 길이 (4분음표 단위)
    var measureLength: Double {
        Double(beatsPerMeasure) * 4.0 / Double(max(beatUnit, 1))
    }

    var allPitches: [Int] {
        measures.flatMap { $0.events.flatMap(\.pitches) }
    }

    static func blank(title: String = "새 악보") -> Score {
        var s = Score(title: title, measures: [])
        s.measures = (0..<4).map { _ in s.emptyMeasure() }
        return s
    }

    func emptyMeasure() -> Measure {
        Measure(events: [
            .rest(measureLength, staff: .treble),
            .rest(measureLength, staff: .bass),
        ])
    }

    /// 이벤트 위치 찾기
    func locate(_ eventID: UUID) -> (measure: Int, event: Int)? {
        for (mi, m) in measures.enumerated() {
            if let ei = m.events.firstIndex(where: { $0.id == eventID }) {
                return (mi, ei)
            }
        }
        return nil
    }
}

// MARK: - 시간축 (재생 / 연습용)

struct TimedEvent: Hashable {
    let id: UUID
    let measureIndex: Int
    let start: Double      // 곡 시작부터의 박 (4분음표 단위)
    let duration: Double
    let pitches: [Int]
    let staff: Staff
}

/// 동시에 눌러야 하는 음들의 묶음
struct PracticeStep: Hashable {
    let start: Double
    let pitches: Set<Int>
    let eventIDs: Set<UUID>
    /// 0 부터 시작하는 마디 번호
    let measureIndex: Int
}

extension Score {
    func timeline(staves: Set<Staff> = Set(Staff.allCases)) -> [TimedEvent] {
        var result: [TimedEvent] = []
        for (mi, m) in measures.enumerated() {
            let measureStart = Double(mi) * measureLength
            for staff in Staff.allCases where staves.contains(staff) {
                var t = measureStart
                for e in m.events(on: staff) {
                    result.append(TimedEvent(id: e.id, measureIndex: mi, start: t,
                                             duration: e.duration, pitches: e.pitches, staff: staff))
                    t += e.duration
                }
            }
        }
        return result.sorted { $0.start < $1.start }
    }

    /// measures: 이 마디(0 부터)만 연습. nil 이면 전체.
    func practiceSteps(staves: Set<Staff>, measures only: Set<Int>? = nil) -> [PracticeStep] {
        let notes = timeline(staves: staves).filter {
            !$0.pitches.isEmpty && (only?.contains($0.measureIndex) ?? true)
        }
        var groups: [Double: (pitches: Set<Int>, ids: Set<UUID>, measure: Int)] = [:]
        for n in notes {
            let key = (n.start * 1000).rounded() / 1000
            var g = groups[key] ?? ([], [], n.measureIndex)
            g.pitches.formUnion(n.pitches)
            g.ids.insert(n.id)
            groups[key] = g
        }
        return groups.keys.sorted().map { k in
            let g = groups[k]!
            return PracticeStep(start: k, pitches: g.pitches, eventIDs: g.ids, measureIndex: g.measure)
        }
    }
}

// MARK: - 음 이름

enum NoteName {
    static let sharpNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    static let flatNames  = ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"]
    static let solfege    = ["도", "도#", "레", "레#", "미", "파", "파#", "솔", "솔#", "라", "라#", "시"]

    static func name(_ midi: Int, preferFlats: Bool = false) -> String {
        let pc = ((midi % 12) + 12) % 12
        let octave = midi / 12 - 1
        return (preferFlats ? flatNames[pc] : sharpNames[pc]) + "\(octave)"
    }

    static func korean(_ midi: Int) -> String {
        solfege[((midi % 12) + 12) % 12]
    }

    /// "C#4", "Bb3", "E4" → MIDI
    static func midi(from text: String) -> Int? {
        let s = text.trimmingCharacters(in: .whitespaces)
        guard let first = s.first, let base = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11][String(first).uppercased()] else {
            return nil
        }
        var rest = s.dropFirst()
        var alter = 0
        while let c = rest.first, c == "#" || c == "b" || c == "♯" || c == "♭" || c == "x" {
            alter += (c == "#" || c == "♯") ? 1 : (c == "x" ? 2 : -1)
            rest = rest.dropFirst()
        }
        guard let octave = Int(rest) else { return nil }
        return (octave + 1) * 12 + base + alter
    }
}

// MARK: - 음가

enum NoteValue: Double, CaseIterable, Identifiable {
    case whole = 4, half = 2, quarter = 1, eighth = 0.5, sixteenth = 0.25

    var id: Double { rawValue }

    var label: String {
        switch self {
        case .whole: return "온음표"
        case .half: return "2분"
        case .quarter: return "4분"
        case .eighth: return "8분"
        case .sixteenth: return "16분"
        }
    }

    /// 길이를 (기본 음가, 점 여부)로 분해
    static func decompose(_ duration: Double) -> (NoteValue, Bool) {
        for v in NoteValue.allCases {
            if abs(v.rawValue * 1.5 - duration) < 0.001 { return (v, true) }
            if abs(v.rawValue - duration) < 0.001 { return (v, false) }
        }
        let nearest = NoteValue.allCases.min { abs($0.rawValue - duration) < abs($1.rawValue - duration) } ?? .quarter
        return (nearest, false)
    }
}

// MARK: - 예제 악보

extension Score {
    /// 작은 별 (전래 동요, 퍼블릭 도메인) — API 키 없이 기능을 시험해 볼 수 있는 예제
    static var twinkleExample: Score {
        func n(_ name: String, _ d: Double = 1, _ staff: Staff = .treble) -> NoteEvent {
            NoteEvent(pitches: [NoteName.midi(from: name)!], duration: d, staff: staff)
        }
        func chord(_ names: [String], _ d: Double = 2) -> NoteEvent {
            NoteEvent(pitches: names.compactMap(NoteName.midi(from:)), duration: d, staff: .bass)
        }
        let melody: [[NoteEvent]] = [
            [n("C4"), n("C4"), n("G4"), n("G4")],
            [n("A4"), n("A4"), n("G4", 2)],
            [n("F4"), n("F4"), n("E4"), n("E4")],
            [n("D4"), n("D4"), n("C4", 2)],
            [n("G4"), n("G4"), n("F4"), n("F4")],
            [n("E4"), n("E4"), n("D4", 2)],
            [n("G4"), n("G4"), n("F4"), n("F4")],
            [n("E4"), n("E4"), n("D4", 2)],
        ]
        let bass: [[NoteEvent]] = [
            [chord(["C3", "G3"]), chord(["C3", "G3"])],
            [chord(["F3", "C3"]), chord(["C3", "E3"])],
            [chord(["D3", "F3"]), chord(["C3", "G3"])],
            [chord(["G2", "G3"]), chord(["C3"])],
            [chord(["C3", "E3"]), chord(["D3", "F3"])],
            [chord(["C3", "G3"]), chord(["G2", "B2"])],
            [chord(["C3", "E3"]), chord(["D3", "F3"])],
            [chord(["C3", "G3"]), chord(["G2", "B2"])],
        ]
        let measures = zip(melody, bass).map { Measure(events: $0 + $1) }
        return Score(title: "작은 별 (예제)", composer: "전래 동요", tempo: 96, measures: measures)
    }
}
