import CoreGraphics
import Foundation

/// 악보를 줄(시스템) 단위로 배치합니다. 화면 표시와 PDF 출력이 같은 배치를 사용합니다.
struct ScoreLayout {
    // 세로 치수 (한 줄 = 높은음 + 낮은음 큰보표)
    static let space: CGFloat = 8                         // 오선 간격
    static let trebleTop: CGFloat = 46                    // 높은음자리표 맨 윗줄 y
    static let bassTop: CGFloat = trebleTop + 4 * space + 64
    static let systemHeight: CGFloat = bassTop + 4 * space + 46
    static let leftMargin: CGFloat = 12
    static let rightMargin: CGFloat = 12

    struct PlacedEvent {
        let event: NoteEvent
        let measureIndex: Int
        let x: CGFloat
    }

    struct System {
        let index: Int
        let measureRange: Range<Int>
        let headerWidth: CGFloat
        /// 마디 경계 x (measureRange.count + 1 개)
        let barXs: [CGFloat]
        let events: [PlacedEvent]
        /// 이 줄에서 새 페이지가 시작되면 그 페이지 (여러 페이지인 악보에서만)
        var startsPage: ScorePage? = nil
    }

    let score: Score
    let width: CGFloat
    let systems: [System]

    var totalHeight: CGFloat { CGFloat(systems.count) * Self.systemHeight }

    init(score: Score, width: CGFloat) {
        self.score = score
        self.width = width

        let usable = max(width - Self.leftMargin - Self.rightMargin, 120)
        let keyCount = CGFloat(min(abs(score.keyFifths), 7))
        let baseHeader: CGFloat = 34 + keyCount * 8 + 6
        let perSystem = max(1, Int((usable - baseHeader) / 170))

        let pages = score.pages
        let showPages = pages.count > 1 || pages.first?.title != nil
        let pageStarts = pages.map(\.measureRange.lowerBound)

        var systems: [System] = []
        var start = 0
        var index = 0
        while start < score.measures.count {
            // 페이지가 바뀌는 마디에서는 줄을 바꿈
            let nextPage = pageStarts.first { $0 > start } ?? score.measures.count
            let end = min(start + perSystem, score.measures.count, nextPage)
            let header = baseHeader + (index == 0 ? 26 : 0)
            let x0 = Self.leftMargin + header
            let measureWidth = (Self.leftMargin + usable - x0) / CGFloat(perSystem)
            var bars: [CGFloat] = []
            var placed: [PlacedEvent] = []
            for (k, mi) in (start..<end).enumerated() {
                let mx = x0 + CGFloat(k) * measureWidth
                bars.append(mx)
                let inner = measureWidth - 28
                let length = score.measureLength
                for staff in Staff.allCases {
                    var beat = 0.0
                    for e in score.measures[mi].events(on: staff) {
                        let x = mx + 16 + CGFloat(beat / length) * inner
                        placed.append(PlacedEvent(event: e, measureIndex: mi, x: x))
                        beat += e.duration
                    }
                }
            }
            bars.append(x0 + CGFloat(end - start) * measureWidth)
            var system = System(index: index, measureRange: start..<end, headerWidth: header,
                                barXs: bars, events: placed)
            if showPages { system.startsPage = pages.first { $0.measureRange.lowerBound == start } }
            systems.append(system)
            start = end
            index += 1
        }
        if systems.isEmpty {
            systems.append(System(index: 0, measureRange: 0..<0, headerWidth: baseHeader + 26,
                                  barXs: [Self.leftMargin + baseHeader + 26, width - Self.rightMargin], events: []))
        }
        self.systems = systems
    }

    // MARK: 음높이 → 오선 위치

    /// 오선 맨 아랫줄 = 0, 한 칸(선↔칸) 올라갈 때마다 +1
    static func staffPosition(midi: Int, staff: Staff, preferFlats: Bool) -> (position: Int, alter: Int, step: Int) {
        let pc = ((midi % 12) + 12) % 12
        let octave = midi / 12 - 1
        // (음이름 0=C..6=B, 변화)
        let sharpMap: [(Int, Int)] = [(0,0),(0,1),(1,0),(1,1),(2,0),(3,0),(3,1),(4,0),(4,1),(5,0),(5,1),(6,0)]
        let flatSpelling: [(Int, Int)] = [(0,0),(1,-1),(1,0),(2,-1),(2,0),(3,0),(4,-1),(4,0),(5,-1),(5,0),(6,-1),(6,0)]
        let (step, alter) = preferFlats ? flatSpelling[pc] : sharpMap[pc]
        let diatonic = octave * 7 + step
        let bottom = staff == .treble ? 30 : 18   // E4 / G2
        return (diatonic - bottom, alter, step)
    }

    static func y(position: Int, staff: Staff) -> CGFloat {
        let top = staff == .treble ? trebleTop : bassTop
        let bottom = top + 4 * space
        return bottom - CGFloat(position) * space / 2
    }

    /// 조표가 음이름(step)에 주는 변화
    static func keyAlter(step: Int, fifths: Int) -> Int {
        let sharpOrder = [3, 0, 4, 1, 5, 2, 6]   // F C G D A E B
        let flatOrder  = [6, 2, 5, 1, 4, 0, 3]   // B E A D G C F
        if fifths > 0, sharpOrder.prefix(min(fifths, 7)).contains(step) { return 1 }
        if fifths < 0, flatOrder.prefix(min(-fifths, 7)).contains(step) { return -1 }
        return 0
    }

    // MARK: 터치 판정

    /// 화면 좌표(전체 악보 기준)에서 가장 가까운 음표 찾기
    func hitTest(_ point: CGPoint) -> NoteEvent? {
        let si = Int(point.y / Self.systemHeight)
        guard systems.indices.contains(si) else { return nil }
        let localY = point.y - CGFloat(si) * Self.systemHeight
        let midStaff: CGFloat = (Self.trebleTop + 4 * Self.space + Self.bassTop) / 2
        let staff: Staff = localY < midStaff ? .treble : .bass
        let candidates = systems[si].events.filter { $0.event.staff == staff }
        guard let best = candidates.min(by: { abs($0.x - point.x) < abs($1.x - point.x) }),
              abs(best.x - point.x) < 30 else { return nil }
        return best.event
    }

    /// 특정 음표가 있는 줄의 y (자동 스크롤용)
    func systemIndex(containing eventID: UUID) -> Int? {
        systems.first { $0.events.contains { $0.event.id == eventID } }?.index
    }
}
