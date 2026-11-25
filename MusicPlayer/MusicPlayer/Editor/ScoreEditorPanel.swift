import SwiftUI

/// 선택한 음표를 고치는 편집 도구 모음
struct ScoreEditorPanel: View {
    @Binding var score: Score
    @Binding var selectedID: UUID?

    private var selected: NoteEvent? {
        guard let id = selectedID, let loc = score.locate(id) else { return nil }
        return score.measures[loc.measure].events[loc.event]
    }

    enum Tab: String, CaseIterable, Identifiable {
        case pitch = "음높이", rhythm = "길이", marks = "표식", measure = "마디"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .pitch
    @State private var chordMode = false
    @State private var isRereading = false
    @State private var rereadMessage: String?

    var body: some View {
        VStack(spacing: 8) {
            if let e = selected {
                header(e)
                Picker("편집", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                switch tab {
                case .pitch: pitchTools(e)
                case .rhythm: rhythmTools(e)
                case .marks: markTools(e)
                case .measure: measureTools(e)
                }
            } else {
                Text("악보에서 음표나 쉼표를 눌러 선택하세요. 원본과 다른 음·표식을 고칠 수 있습니다.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Button {
                        addMeasure()
                    } label: {
                        Label("마디 추가", systemImage: "plus.square")
                    }
                    Spacer()
                }
                .font(.subheadline)
            }
        }
        .padding(12)
        .background(.regularMaterial)
    }

    // MARK: 탭별 도구

    private func header(_ e: NoteEvent) -> some View {
        HStack(spacing: 8) {
            Button { select(offset: -1) } label: { Image(systemName: "chevron.left.circle.fill").font(.title2) }
                .accessibilityLabel("이전 음표")
            VStack(alignment: .leading, spacing: 1) {
                Text(description(e)).font(.headline).lineLimit(1).minimumScaleFactor(0.7)
                Text(e.staff.label + " · \(score.locate(e.id).map { $0.measure + 1 } ?? 0)마디")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { select(offset: 1) } label: { Image(systemName: "chevron.right.circle.fill").font(.title2) }
                .accessibilityLabel("다음 음표")
        }
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    private func pitchTools(_ e: NoteEvent) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                tool("반음↑", "arrow.up") { transpose(1) }
                tool("반음↓", "arrow.down") { transpose(-1) }
                tool("옥타브↑", "arrow.up.to.line") { transpose(12) }
                tool("옥타브↓", "arrow.down.to.line") { transpose(-12) }
                Divider().frame(height: 30)
                tool(e.isRest ? "음표로" : "쉼표로", e.isRest ? "music.note" : "pause") { toggleRest() }
                tool(e.staff == .treble ? "왼손으로" : "오른손으로", "arrow.left.arrow.right") { switchStaff() }
                tool("뒤에 추가", "text.insert") { insertAfter() }
                tool("삭제", "trash", role: .destructive) { deleteSelected() }
            }
        }
        HStack {
            Text(chordMode ? "건반을 눌러 화음에 넣거나 빼세요" : "건반을 눌러 음을 바꾸세요")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Toggle("화음", isOn: $chordMode).toggleStyle(.button).font(.caption)
        }
        PianoKeyboardView(lowest: keyboardRange(e).lowerBound, highest: keyboardRange(e).upperBound,
                          colors: Dictionary(e.pitches.map { ($0, Color.accentColor) }, uniquingKeysWith: { a, _ in a })) { midi in
            setPitch(midi)
        }
        .frame(height: 70)
    }

    @ViewBuilder
    private func rhythmTools(_ e: NoteEvent) -> some View {
        let parts = NoteValue.decompose(e.duration)
        HStack(spacing: 6) {
            ForEach(NoteValue.allCases) { v in
                Button(v.label) { setDuration(v, dotted: parts.1) }
                    .buttonStyle(.bordered)
                    .tint(v == parts.0 ? Color.accentColor : Color.gray)
                    .font(.caption)
            }
            Toggle("점", isOn: Binding(get: { parts.1 }, set: { setDuration(parts.0, dotted: $0) }))
                .toggleStyle(.button)
                .font(.caption)
        }
        measureCheck(for: e)
    }

    @ViewBuilder
    private func markTools(_ e: NoteEvent) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(NoteMark.allCases) { mark in
                    Button {
                        mutate { $0.toggle(mark) }
                    } label: {
                        VStack(spacing: 2) {
                            Text(mark.symbol).font(.body.weight(.bold))
                            Text(mark.label).font(.caption2)
                        }
                        .frame(minWidth: 52)
                    }
                    .buttonStyle(.bordered)
                    .tint(e.has(mark) ? Color.accentColor : Color.gray)
                    .disabled(e.isRest && mark != .fermata)
                }
            }
        }
        HStack {
            Menu {
                Button("없음") { mutate { $0.dynamic = nil } }
                ForEach(Dynamic.allCases) { d in
                    Button(d.rawValue) { mutate { $0.dynamic = d } }
                }
            } label: {
                Label("셈여림: \(e.dynamic?.rawValue ?? "없음")", systemImage: "speaker.wave.2")
            }
            Spacer()
            Menu {
                Button("없음") { mutate { $0.fingering = nil } }
                ForEach(1...5, id: \.self) { f in
                    Button("\(f)번 손가락") { mutate { $0.fingering = f } }
                }
            } label: {
                Label("손가락: \(e.fingering.map { "\($0)" } ?? "없음")", systemImage: "hand.point.up")
            }
            .disabled(e.isRest)
        }
        .font(.subheadline)
        if e.marks != nil || e.dynamic != nil || e.fingering != nil {
            Button(role: .destructive) {
                mutate { $0.marks = nil; $0.dynamic = nil; $0.fingering = nil }
            } label: {
                Label("이 음표의 표식 모두 지우기", systemImage: "eraser")
            }
            .font(.caption)
        }
    }

    @ViewBuilder
    private func measureTools(_ e: NoteEvent) -> some View {
        if let loc = score.locate(e.id) {
            let m = score.measures[loc.measure]
            HStack(spacing: 6) {
                Toggle(isOn: Binding(get: { m.repeatStart == true },
                                     set: { score.measures[loc.measure].repeatStart = $0 ? true : nil })) {
                    Label("도돌이 시작 𝄆", systemImage: "repeat")
                }
                Toggle(isOn: Binding(get: { m.repeatEnd == true },
                                     set: { score.measures[loc.measure].repeatEnd = $0 ? true : nil })) {
                    Label("도돌이 끝 𝄇", systemImage: "repeat")
                }
            }
            .toggleStyle(.button)
            .font(.caption)

            aiRereadRow(measureIndex: loc.measure)

            HStack {
                Button { addMeasure() } label: { Label("마디 추가", systemImage: "plus.square") }
                Spacer()
                if loc.measure > 0 {
                    Button {
                        score.togglePageBreak(atMeasure: loc.measure)
                    } label: {
                        Label(m.pageStart == true ? "페이지 나누기 해제" : "여기서 새 페이지",
                              systemImage: "doc.badge.plus")
                    }
                    Spacer()
                }
                Button(role: .destructive) { deleteMeasure() } label: {
                    Label("마디 삭제", systemImage: "minus.square")
                }
            }
            .font(.subheadline)
        }
    }

    // MARK: 보조 뷰

    private func tool(_ title: String, _ icon: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                Text(title).font(.caption2)
            }
            .frame(minWidth: 52)
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder
    private func measureCheck(for e: NoteEvent) -> some View {
        if let loc = score.locate(e.id) {
            let total = score.measures[loc.measure].events(on: e.staff).reduce(0) { $0 + $1.duration }
            if abs(total - score.measureLength) > 0.001 {
                Label(String(format: "이 마디(%@)의 박자 합이 %.2g박입니다. 박자표는 %.2g박입니다.",
                             e.staff.label, total, score.measureLength),
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func description(_ e: NoteEvent) -> String {
        let (v, dotted) = NoteValue.decompose(e.duration)
        let len = (dotted ? "점" : "") + v.label + (v == .whole ? "" : "음표")
        if e.isRest { return "쉼표 · \(len)" }
        let names = e.pitches.sorted().map { "\(NoteName.name($0, preferFlats: score.keyFifths < 0))(\(NoteName.korean($0)))" }
        return names.joined(separator: " + ") + " · " + len
    }

    // MARK: 편집 동작

    private func mutate(_ change: (inout NoteEvent) -> Void) {
        guard let id = selectedID, let loc = score.locate(id) else { return }
        change(&score.measures[loc.measure].events[loc.event])
        if let e = selected, !e.isRest {
            PianoSynth.shared.preview(e.pitches)
        }
    }

    // MARK: AI 다시 읽기

    @ViewBuilder
    private func aiRereadRow(measureIndex mi: Int) -> some View {
        let page = score.pages[score.pageIndex(ofMeasure: mi)]
        HStack {
            Button {
                reread(measureIndex: mi, imageName: page.image)
            } label: {
                if isRereading {
                    HStack(spacing: 6) {
                        ProgressView()
                        Text("AI가 원본에서 다시 읽는 중…")
                    }
                } else {
                    Label("AI로 이 마디 다시 읽기", systemImage: "sparkles")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isRereading || page.image == nil)
            Spacer()
        }
        .font(.subheadline)
        if page.image == nil {
            Text("원본 사진이 있는 페이지에서만 쓸 수 있어요.").font(.caption).foregroundStyle(.secondary)
        } else if let msg = rereadMessage {
            Text(msg).font(.caption).foregroundStyle(msg.hasPrefix("✓") ? Color.green : Color.red)
        }
    }

    private func reread(measureIndex mi: Int, imageName: String?) {
        guard let name = imageName, let image = PageImageStore.load(name) else { return }
        isRereading = true
        rereadMessage = nil
        let snapshot = score
        Task {
            do {
                let measure = try await OMRService(apiKey: APIKeyStore.current)
                    .rereadMeasure(score: snapshot, measureIndex: mi, pageImage: image)
                // 그사이 마디가 바뀌지 않았을 때만 적용 (되돌리기로 원래대로 돌릴 수 있음)
                if score.measures.indices.contains(mi), score.measures[mi].id == measure.id {
                    score.measures[mi] = measure
                    selectedID = measure.events.first { $0.staff == .treble }?.id ?? measure.events.first?.id
                    rereadMessage = "✓ \(mi + 1)마디를 다시 읽었습니다. 마음에 들지 않으면 되돌리기(↶)를 누르세요."
                }
            } catch {
                rereadMessage = error.localizedDescription
            }
            isRereading = false
        }
    }

    /// 같은 손의 이전/다음 음표 선택
    private func select(offset: Int) {
        guard let e = selected else { return }
        let all = score.measures.flatMap { $0.events(on: e.staff) }
        guard let i = all.firstIndex(where: { $0.id == e.id }) else { return }
        let j = i + offset
        guard all.indices.contains(j) else { return }
        selectedID = all[j].id
        if !all[j].isRest { PianoSynth.shared.preview(all[j].pitches) }
    }

    private func keyboardRange(_ e: NoteEvent) -> ClosedRange<Int> {
        let center = e.pitches.isEmpty ? (e.staff == .treble ? 67 : 50)
                                       : (e.pitches.min()! + e.pitches.max()!) / 2
        let low = max(21, center - 14 - ((center - 14) % 12 + 12) % 12)
        return low...min(108, low + 35)
    }

    /// 화면 건반으로 음 바꾸기
    private func setPitch(_ midi: Int) {
        mutate { e in
            if chordMode {
                if let i = e.pitches.firstIndex(of: midi) {
                    if e.pitches.count > 1 { e.pitches.remove(at: i) }
                } else {
                    e.pitches.append(midi)
                    e.pitches.sort()
                }
            } else if e.pitches.count > 1 {
                // 화음이면 가장 가까운 음을 바꿈
                let nearest = e.pitches.min { abs($0 - midi) < abs($1 - midi) }!
                e.pitches = Array(Set(e.pitches.map { $0 == nearest ? midi : $0 })).sorted()
            } else {
                e.pitches = [midi]
            }
        }
    }

    /// 다른 손(보표)으로 옮김: 같은 박 위치에 들어가도록 순서를 맞춤
    private func switchStaff() {
        guard let id = selectedID, let loc = score.locate(id) else { return }
        var measure = score.measures[loc.measure]
        var e = measure.events.remove(at: loc.event)
        let startBeat = score.measures[loc.measure].events(on: e.staff)
            .prefix { $0.id != e.id }.reduce(0) { $0 + $1.duration }
        e.staff = e.staff == .treble ? .bass : .treble
        // 옮겨 갈 보표에서 startBeat 이후 첫 이벤트 앞에 넣기
        var beat = 0.0
        var insertAt = measure.events.count
        for (i, other) in measure.events.enumerated() where other.staff == e.staff {
            if beat >= startBeat - 0.001 { insertAt = i; break }
            beat += other.duration
        }
        measure.events.insert(e, at: insertAt)
        score.measures[loc.measure] = measure
    }

    private func transpose(_ semitones: Int) {
        mutate { e in
            e.pitches = e.pitches.map { min(108, max(21, $0 + semitones)) }
        }
    }

    private func toggleRest() {
        mutate { e in
            e.pitches = e.isRest ? [e.staff == .treble ? 72 : 48] : []
        }
    }

    private func setDuration(_ v: NoteValue, dotted: Bool) {
        mutate { e in
            e.duration = v.rawValue * (dotted ? 1.5 : 1)
        }
    }

    private func insertAfter() {
        guard let id = selectedID, let loc = score.locate(id) else { return }
        let src = score.measures[loc.measure].events[loc.event]
        let new = NoteEvent(pitches: src.isRest ? [src.staff == .treble ? 72 : 48] : src.pitches,
                            duration: 1, staff: src.staff)
        score.measures[loc.measure].events.insert(new, at: loc.event + 1)
        selectedID = new.id
    }

    private func deleteSelected() {
        guard let id = selectedID, let loc = score.locate(id) else { return }
        score.measures[loc.measure].events.remove(at: loc.event)
        selectedID = nil
    }

    private func addMeasure() {
        let index: Int
        if let id = selectedID, let loc = score.locate(id) {
            index = loc.measure + 1
        } else {
            index = score.measures.count
        }
        score.measures.insert(score.emptyMeasure(), at: index)
    }

    private func deleteMeasure() {
        guard let id = selectedID, let loc = score.locate(id) else { return }
        score.removeMeasure(at: loc.measure)
        selectedID = nil
    }
}

/// 제목·빠르기·박자·조표 편집
struct ScoreInfoSheet: View {
    @Binding var score: Score
    @Environment(\.dismiss) private var dismiss

    private let keyNames: [Int: String] = [
        -7: "C♭장조", -6: "G♭장조", -5: "D♭장조", -4: "A♭장조", -3: "E♭장조", -2: "B♭장조", -1: "F장조",
        0: "C장조 / a단조", 1: "G장조", 2: "D장조", 3: "A장조", 4: "E장조", 5: "B장조", 6: "F♯장조", 7: "C♯장조",
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("곡 정보") {
                    TextField("제목", text: $score.title)
                    TextField("작곡가", text: $score.composer)
                }
                Section("연주 설정") {
                    Stepper("빠르기 ♩ = \(score.tempo)", value: $score.tempo, in: 30...240, step: 2)
                    Stepper("박자 \(score.beatsPerMeasure)/\(score.beatUnit)", value: $score.beatsPerMeasure, in: 1...12)
                    Picker("박자 단위", selection: $score.beatUnit) {
                        Text("4분음표 (/4)").tag(4)
                        Text("8분음표 (/8)").tag(8)
                        Text("2분음표 (/2)").tag(2)
                    }
                    Picker("조표", selection: $score.keyFifths) {
                        ForEach(-7...7, id: \.self) { k in
                            Text(keyNames[k] ?? "\(k)").tag(k)
                        }
                    }
                }
            }
            .navigationTitle("악보 정보")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
        }
    }
}
