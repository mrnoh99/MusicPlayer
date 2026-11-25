import SwiftUI

/// 선택한 음표를 고치는 편집 도구 모음
struct ScoreEditorPanel: View {
    @Binding var score: Score
    @Binding var selectedID: UUID?

    private var selected: NoteEvent? {
        guard let id = selectedID, let loc = score.locate(id) else { return nil }
        return score.measures[loc.measure].events[loc.event]
    }

    var body: some View {
        VStack(spacing: 8) {
            if let e = selected {
                HStack {
                    Text(description(e))
                        .font(.headline)
                    Spacer()
                    Text(e.staff.label + " · \(score.locate(e.id).map { $0.measure + 1 } ?? 0)마디")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        tool("반음↑", "arrow.up") { transpose(1) }
                        tool("반음↓", "arrow.down") { transpose(-1) }
                        tool("옥타브↑", "arrow.up.to.line") { transpose(12) }
                        tool("옥타브↓", "arrow.down.to.line") { transpose(-12) }
                        Divider().frame(height: 30)
                        tool("화음+", "plus.circle") { addChordTone() }
                        tool("화음−", "minus.circle") { removeChordTone() }
                        tool(e.isRest ? "음표로" : "쉼표로", e.isRest ? "music.note" : "pause") { toggleRest() }
                        Divider().frame(height: 30)
                        tool("뒤에 추가", "text.insert") { insertAfter() }
                        tool("삭제", "trash", role: .destructive) { deleteSelected() }
                    }
                }

                HStack(spacing: 6) {
                    let parts = NoteValue.decompose(e.duration)
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
            } else {
                Text("악보에서 음표나 쉼표를 눌러 선택하세요.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button {
                    addMeasure()
                } label: {
                    Label("마디 추가", systemImage: "plus.square")
                }
                Spacer()
                if selected != nil {
                    Button(role: .destructive) {
                        deleteMeasure()
                    } label: {
                        Label("이 마디 삭제", systemImage: "minus.square")
                    }
                }
            }
            .font(.subheadline)
        }
        .padding(12)
        .background(.regularMaterial)
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

    private func transpose(_ semitones: Int) {
        mutate { e in
            e.pitches = e.pitches.map { min(108, max(21, $0 + semitones)) }
        }
    }

    private func addChordTone() {
        mutate { e in
            guard let top = e.pitches.max() else { return }
            let tone = min(108, top + 4)
            if !e.pitches.contains(tone) { e.pitches.append(tone) }
        }
    }

    private func removeChordTone() {
        mutate { e in
            guard e.pitches.count > 1, let top = e.pitches.max() else { return }
            e.pitches.removeAll { $0 == top }
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
        score.measures.remove(at: loc.measure)
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
