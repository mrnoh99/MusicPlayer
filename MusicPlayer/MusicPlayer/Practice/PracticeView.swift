import SwiftUI

/// 마이크 연습 화면
struct PracticeView: View {
    let score: Score

    @Environment(\.dismiss) private var dismiss
    @StateObject private var session: PracticeSession
    private let keyRange: ClosedRange<Int>

    init(score: Score) {
        self.score = score
        _session = StateObject(wrappedValue: PracticeSession(score: score))
        keyRange = PianoKeyboardView.range(for: score.allPitches)
    }

    private var preferFlats: Bool { score.keyFifths < 0 }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScoreCanvasView(score: score, highlights: scoreHighlights,
                                focusEventID: session.current?.eventIDs.first)

                VStack(spacing: 10) {
                    feedbackCard
                    PianoKeyboardView(lowest: keyRange.lowerBound, highest: keyRange.upperBound,
                                      colors: keyColors) { midi in
                        PianoSynth.shared.preview([midi], seconds: 0.5)
                    }
                    .frame(height: 110)
                    controls
                }
                .padding(12)
                .background(.regularMaterial)
            }
            .navigationTitle("연습 · \(score.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") {
                        session.stop()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("손", selection: $session.staves) {
                            Text("양손").tag(Set(Staff.allCases))
                            Text("오른손만").tag(Set([Staff.treble]))
                            Text("왼손만").tag(Set([Staff.bass]))
                        }
                        Section("마이크 민감도") {
                            Picker("민감도", selection: $session.sensitivity) {
                                Text("낮음 (시끄러운 곳)").tag(0.6)
                                Text("보통").tag(1.0)
                                Text("높음 (조용한 곳)").tag(1.6)
                            }
                        }
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                }
            }
            .alert("마이크", isPresented: Binding(get: { session.errorMessage != nil },
                                                set: { if !$0 { session.errorMessage = nil } })) {
                Button("확인", role: .cancel) {}
            } message: {
                Text(session.errorMessage ?? "")
            }
            .onDisappear { session.stop() }
        }
    }

    // MARK: 색 표시

    private var scoreHighlights: [UUID: Color] {
        var h: [UUID: Color] = [:]
        for id in session.lastCorrectIDs { h[id] = .green }
        if let step = session.current {
            let color: Color
            if case .wrong = session.feedback { color = .red } else { color = .blue }
            for id in step.eventIDs { h[id] = color }
        }
        return h
    }

    private var keyColors: [Int: Color] {
        var c: [Int: Color] = [:]
        if let step = session.current {
            for p in step.pitches { c[p] = Color.blue.opacity(0.55) }
            for p in session.heard where step.pitches.contains(p) { c[p] = .green }
        }
        for p in session.wrongHeard { c[p] = .red }
        return c
    }

    // MARK: 안내 카드

    private var feedbackCard: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: feedbackIcon)
                .font(.system(size: 34))
                .foregroundStyle(feedbackColor)
                .frame(width: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text(feedbackTitle).font(.headline)
                Text(feedbackDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                ProgressView(value: session.progress)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 4) {
                Label("\(session.correctCount)", systemImage: "checkmark").foregroundStyle(.green)
                Label("\(session.mistakeCount)", systemImage: "xmark").foregroundStyle(.red)
                LevelMeter(level: session.level).frame(width: 60, height: 6)
            }
            .font(.caption.monospacedDigit())
        }
    }

    private func names(_ pitches: [Int]) -> String {
        pitches.map { "\(NoteName.name($0, preferFlats: preferFlats))(\(NoteName.korean($0)))" }
            .joined(separator: ", ")
    }

    private var targetText: String {
        guard let step = session.current else { return "" }
        return names(step.pitches.sorted())
    }

    private var feedbackTitle: String {
        switch session.feedback {
        case .idle: return session.steps.isEmpty ? "연습할 음표가 없습니다" : "시작을 누르고 피아노를 쳐 보세요"
        case .waiting: return "칠 음: \(targetText)"
        case .correct: return "좋아요! 다음: \(targetText)"
        case .partial(let missing): return "빠진 음이 있어요: \(names(missing))"
        case .wrong(let played, _): return "틀린 음: \(names(played))"
        case .finished: return "끝까지 연주했습니다 🎉"
        }
    }

    private var feedbackDetail: String {
        switch session.feedback {
        case .idle:
            return "파란색으로 표시된 음을 치면 마이크로 듣고 맞았는지 알려 줍니다."
        case .waiting, .correct:
            return session.isListening ? "듣고 있습니다… (\(session.index + 1)/\(session.steps.count))" : ""
        case .partial:
            return "칠 음: \(targetText)"
        case .wrong(_, let expected):
            return "눌러야 할 음: \(names(expected))"
        case .finished:
            let total = session.correctCount + session.mistakeCount
            let rate = total == 0 ? 100 : Int(Double(session.correctCount) / Double(total) * 100)
            return "맞은 음 \(session.correctCount)개 · 틀린 횟수 \(session.mistakeCount)회 · 정확도 \(rate)%"
        }
    }

    private var feedbackIcon: String {
        switch session.feedback {
        case .idle: return "music.note"
        case .waiting: return "ear"
        case .correct: return "checkmark.circle.fill"
        case .partial: return "exclamationmark.circle.fill"
        case .wrong: return "xmark.circle.fill"
        case .finished: return "star.circle.fill"
        }
    }

    private var feedbackColor: Color {
        switch session.feedback {
        case .idle, .waiting: return .blue
        case .correct, .finished: return .green
        case .partial: return .orange
        case .wrong: return .red
        }
    }

    // MARK: 조작 버튼

    private var controls: some View {
        HStack(spacing: 14) {
            Button { session.previous() } label: { Image(systemName: "backward.end.fill") }
            Button { session.playCurrent() } label: { Label("들어보기", systemImage: "speaker.wave.2.fill") }
                .disabled(session.current == nil)

            Button {
                session.isListening ? session.stop() : session.start()
            } label: {
                Label(session.isListening ? "멈춤" : "시작",
                      systemImage: session.isListening ? "stop.fill" : "mic.fill")
                    .frame(minWidth: 90)
            }
            .buttonStyle(.borderedProminent)
            .tint(session.isListening ? Color.red : Color.accentColor)
            .disabled(session.steps.isEmpty)

            Button { session.next() } label: { Image(systemName: "forward.end.fill") }
            Button { session.restart() } label: { Image(systemName: "arrow.counterclockwise") }
        }
        .buttonStyle(.bordered)
    }
}

private struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.gray.opacity(0.25))
                Capsule().fill(level > 0.8 ? Color.orange : Color.green)
                    .frame(width: geo.size.width * CGFloat(level))
            }
        }
    }
}
