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
                if let focus = session.focusMeasures {
                    focusBanner(focus)
                }
                ScoreCanvasView(score: score, highlights: scoreHighlights,
                                focusEventID: session.current?.eventIDs.first)

                VStack(spacing: 10) {
                    feedbackCard
                    PianoKeyboardView(lowest: keyRange.lowerBound, highest: keyRange.upperBound,
                                      colors: keyColors) { midi in
                        session.ignoreMic(for: 0.9)
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
                        if session.report != nil {
                            Button { session.showReport = true } label: {
                                Label("지난 결과 보기", systemImage: "chart.bar")
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
            .sheet(isPresented: $session.showReport) {
                if let report = session.report {
                    PracticeReportView(report: report, preferFlats: preferFlats,
                                       isPartial: session.focusMeasures != nil,
                                       onRetryWeak: { session.practice(measures: Set(report.weakMeasures.map(\.measure))) },
                                       onRestart: {
                                           session.showReport = false
                                           session.restart()
                                       },
                                       onWholePiece: { session.practiceWholePiece() })
                    .presentationDetents([.medium, .large])
                }
            }
            .sensoryFeedback(.success, trigger: session.successTick)
            .sensoryFeedback(.error, trigger: session.errorTick)
            .onDisappear { session.stop() }
        }
    }

    private func focusBanner(_ focus: Set<Int>) -> some View {
        HStack {
            Image(systemName: "scope")
            Text("\(focus.sorted().map { "\($0 + 1)" }.joined(separator: ", "))마디만 연습 중")
                .font(.subheadline.weight(.medium))
            Spacer()
            Button("곡 전체로") { session.practiceWholePiece() }
                .font(.subheadline)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.15))
    }

    // MARK: 색 표시

    /// 이미 친 음은 결과대로(초록=한 번에, 주황=틀린 뒤 맞힘, 회색=건너뜀), 지금 칠 음은 파랑/빨강
    private var scoreHighlights: [UUID: Color] {
        var h: [UUID: Color] = [:]
        for (step, r) in zip(session.steps, session.results) {
            let color: Color?
            switch r.status {
            case .clean: color = .green
            case .recovered: color = .orange
            case .skipped: color = .gray
            case .pending: color = nil
            }
            if let color { for id in step.eventIDs { h[id] = color } }
        }
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
                .contentTransition(.symbolEffect(.replace))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(feedbackTitle).font(.headline).lineLimit(1).minimumScaleFactor(0.7)
                    if session.streak >= 3 {
                        Text("🔥 \(session.streak)연속")
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange.opacity(0.2)))
                    }
                }
                Text(feedbackDetail)
                    .font(.subheadline)
                    .foregroundStyle(detailColor)
                    .lineLimit(2)
                ProgressView(value: session.progress)
                    .tint(feedbackColor)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 4) {
                if let acc = session.liveAccuracy {
                    Text("\(acc)%").font(.title3.weight(.bold).monospacedDigit())
                        .foregroundStyle(acc >= 90 ? Color.green : acc >= 70 ? Color.orange : Color.red)
                }
                HStack(spacing: 8) {
                    Label("\(session.cleanCount)", systemImage: "checkmark").foregroundStyle(.green)
                    Label("\(session.mistakeCount)", systemImage: "xmark").foregroundStyle(.red)
                }
                LevelMeter(level: session.level).frame(width: 60, height: 6)
            }
            .font(.caption.monospacedDigit())
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(feedbackColor.opacity(0.08)))
        .animation(.easeOut(duration: 0.2), value: session.feedback)
    }

    private func names(_ pitches: [Int]) -> String {
        NoteName.display(pitches, preferFlats: preferFlats)
    }

    private var targetText: String {
        guard let step = session.current else { return "" }
        return names(step.pitches.sorted())
    }

    private var positionText: String {
        guard let step = session.current else { return "" }
        return "\(step.measureIndex + 1)마디 · \(session.index + 1)/\(session.steps.count)"
    }

    private var feedbackTitle: String {
        switch session.feedback {
        case .idle:
            if session.steps.isEmpty { return "연습할 음표가 없습니다" }
            return session.index > 0 ? "멈춤 · 칠 음: \(targetText)" : "시작을 누르고 피아노를 쳐 보세요"
        case .waiting: return "칠 음: \(targetText)"
        case .correct(let clean):
            let praise = clean ? (session.streak >= 5 ? "멋져요!" : "좋아요!") : "맞았어요!"
            return "\(praise) 다음: \(targetText)"
        case .partial(let missing): return "빠진 음: \(names(missing))"
        case .wrong(let played, _): return "틀린 음: \(names(played))"
        case .finished: return "끝까지 연주했습니다 🎉"
        }
    }

    private var feedbackDetail: String {
        if session.isStuck, session.isListening, session.feedback != .finished {
            return "어렵다면 🔊 들어보기로 소리를 듣거나, 화면 건반의 파란 건반을 확인하세요."
        }
        switch session.feedback {
        case .idle:
            return session.steps.isEmpty ? "" : "파란색으로 표시된 음을 치면 마이크로 듣고 맞았는지 알려 줍니다."
        case .waiting, .correct:
            return session.isListening ? "듣고 있어요… \(positionText)" : positionText
        case .partial:
            return "화음의 모든 음을 동시에 눌러 주세요 · 칠 음: \(targetText)"
        case .wrong(let played, let expected):
            let hint = MistakeHint.text(played: played, expected: Set(expected))
            return hint.isEmpty ? "눌러야 할 음: \(names(expected))" : hint
        case .finished:
            guard let r = session.report else { return "" }
            return "한 번에 맞힘 \(r.accuracy)% · 틀린 횟수 \(r.totalMistakes)회 · 결과 보기는 오른쪽 위 메뉴"
        }
    }

    private var detailColor: Color {
        if case .wrong = session.feedback { return .red }
        return .secondary
    }

    private var feedbackIcon: String {
        switch session.feedback {
        case .idle: return "music.note"
        case .waiting: return session.isStuck ? "questionmark.circle" : "ear"
        case .correct(let clean): return clean ? "checkmark.circle.fill" : "checkmark.circle"
        case .partial: return "exclamationmark.circle.fill"
        case .wrong: return "xmark.circle.fill"
        case .finished: return "star.circle.fill"
        }
    }

    private var feedbackColor: Color {
        switch session.feedback {
        case .idle, .waiting: return .blue
        case .correct(let clean): return clean ? .green : .orange
        case .finished: return .green
        case .partial: return .orange
        case .wrong: return .red
        }
    }

    // MARK: 조작 버튼

    private var controls: some View {
        HStack(spacing: 14) {
            Button { session.previous() } label: { Image(systemName: "backward.end.fill") }
                .accessibilityLabel("이전 음 다시")
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
                .accessibilityLabel("건너뛰기")
            Button { session.restart() } label: { Image(systemName: "arrow.counterclockwise") }
                .accessibilityLabel("처음부터")
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
