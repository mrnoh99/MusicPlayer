import Foundation

/// 악보 한 권(책) 안의 한 페이지. 마디 배열을 pageStart 표시로 나눈 구간입니다.
struct ScorePage: Identifiable, Hashable {
    /// 페이지 첫 마디의 id (페이지를 옮겨도 유지됨)
    let id: UUID
    let number: Int              // 1 부터
    let measureRange: Range<Int>
    let title: String?
    /// 원본 이미지 파일 이름 (PageImageStore)
    let image: String?

    var displayTitle: String {
        if let t = title, !t.isEmpty { return t }
        return "\(number)쪽"
    }
}

extension Score {
    /// 페이지 목록 (마디가 없으면 빈 배열)
    var pages: [ScorePage] {
        guard !measures.isEmpty else { return [] }
        var starts: [Int] = [0]
        for i in 1..<measures.count where measures[i].pageStart == true { starts.append(i) }
        return starts.enumerated().map { k, start in
            let end = k + 1 < starts.count ? starts[k + 1] : measures.count
            return ScorePage(id: measures[start].id, number: k + 1, measureRange: start..<end,
                             title: measures[start].pageTitle, image: measures[start].pageImage)
        }
    }

    var pageCount: Int { max(1, pages.count) }

    /// 마디가 몇 쪽에 있는지 (0 부터)
    func pageIndex(ofMeasure mi: Int) -> Int {
        pages.lastIndex { $0.measureRange.lowerBound <= mi } ?? 0
    }

    /// 한 페이지만 담은 악보 (미리보기용)
    func excerpt(page: ScorePage) -> Score {
        var s = self
        s.measures = Array(measures[page.measureRange])
        if !s.measures.isEmpty { s.measures[0].pageStart = nil }
        return s
    }

    // MARK: 페이지 편집

    private var pageChunks: [[Measure]] {
        pages.map { Array(measures[$0.measureRange]) }
    }

    private mutating func setPages(_ chunks: [[Measure]]) {
        var all: [Measure] = []
        for chunk in chunks where !chunk.isEmpty {
            var c = chunk
            c[0].pageStart = true
            for i in 1..<c.count { c[i].pageStart = nil }
            all += c
        }
        if all.isEmpty { all = [emptyMeasure()] }
        all[0].pageStart = nil   // 첫 페이지는 표시 없이 시작
        measures = all
    }

    mutating func movePages(fromOffsets source: IndexSet, toOffset destination: Int) {
        var chunks = pageChunks
        chunks.move(fromOffsets: source, toOffset: destination)
        setPages(chunks)
    }

    mutating func removePages(atOffsets offsets: IndexSet) {
        var chunks = pageChunks
        chunks.remove(atOffsets: offsets)
        setPages(chunks)
    }

    /// 다른 악보(인식 결과, 다른 곡)의 페이지들을 끼워 넣음. at = nil 이면 맨 뒤.
    mutating func insertPages(from other: Score, at index: Int? = nil, titlePrefix: String? = nil) {
        var chunks = pageChunks
        var incoming = other.pages.map { Array(other.measures[$0.measureRange]) }
        // 새 id 로 복사 (같은 악보를 두 번 넣어도 충돌하지 않게)
        incoming = incoming.map { chunk in
            chunk.map { m in
                var copy = m
                copy.id = UUID()
                copy.events = m.events.map { e in var ne = e; ne.id = UUID(); return ne }
                return copy
            }
        }
        if let prefix = titlePrefix, !prefix.isEmpty {
            for k in incoming.indices where !incoming[k].isEmpty {
                let own = incoming[k][0].pageTitle
                incoming[k][0].pageTitle = incoming.count == 1 ? prefix
                    : "\(prefix) \(k + 1)" + (own.map { " · \($0)" } ?? "")
            }
        }
        let at = min(max(0, index ?? chunks.count), chunks.count)
        chunks.insert(contentsOf: incoming, at: at)
        setPages(chunks)
    }

    mutating func appendBlankPage(measureCount: Int = 4) {
        var chunks = pageChunks
        chunks.append((0..<max(1, measureCount)).map { _ in emptyMeasure() })
        setPages(chunks)
    }

    /// 앞 페이지와 합치기
    mutating func mergePageWithPrevious(_ pageIndex: Int) {
        var chunks = pageChunks
        guard pageIndex > 0, chunks.indices.contains(pageIndex) else { return }
        let page = chunks.remove(at: pageIndex)
        chunks[pageIndex - 1] += page
        setPages(chunks)
    }

    /// 이 마디부터 새 페이지 시작 / 해제
    mutating func togglePageBreak(atMeasure mi: Int) {
        guard measures.indices.contains(mi), mi > 0 else { return }
        if measures[mi].pageStart == true {
            measures[mi].pageStart = nil
            measures[mi].pageTitle = nil
        } else {
            measures[mi].pageStart = true
        }
    }

    mutating func renamePage(_ pageIndex: Int, to title: String) {
        let ps = pages
        guard ps.indices.contains(pageIndex) else { return }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        measures[ps[pageIndex].measureRange.lowerBound].pageTitle = t.isEmpty ? nil : t
    }

    /// 마디 삭제 (페이지 시작 마디를 지우면 다음 마디가 페이지 시작을 이어받음)
    mutating func removeMeasure(at mi: Int) {
        guard measures.indices.contains(mi) else { return }
        let removed = measures.remove(at: mi)
        if removed.pageStart == true, measures.indices.contains(mi), measures[mi].pageStart != true {
            measures[mi].pageStart = true
            measures[mi].pageTitle = removed.pageTitle
            measures[mi].pageImage = removed.pageImage
        }
        if mi == 0, !measures.isEmpty, removed.pageTitle != nil, measures[0].pageTitle == nil {
            measures[0].pageTitle = removed.pageTitle
        }
        if mi == 0, !measures.isEmpty, measures[0].pageImage == nil {
            measures[0].pageImage = removed.pageImage
        }
        if !measures.isEmpty { measures[0].pageStart = nil }
    }
}

// MARK: - 도돌이표를 펼친 재생 순서

extension Score {
    /// 도돌이표(시작/끝)를 한 번씩 반복한 마디 순서
    func playbackOrder() -> [Int] {
        var order: [Int] = []
        var repeatFrom = 0
        var repeated = Set<Int>()
        var i = 0
        while i < measures.count {
            if measures[i].repeatStart == true { repeatFrom = i }
            order.append(i)
            if measures[i].repeatEnd == true && !repeated.contains(i) {
                repeated.insert(i)
                i = repeatFrom
                continue
            }
            if measures[i].repeatEnd == true { repeatFrom = i + 1 }
            i += 1
        }
        return order
    }
}
