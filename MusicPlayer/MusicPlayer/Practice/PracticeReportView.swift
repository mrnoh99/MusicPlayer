import SwiftUI

/// 연습이 끝난 뒤 보여 주는 결과 리포트
struct PracticeReportView: View {
    let report: PracticeReport
    let preferFlats: Bool
    /// 일부 마디만 연습한 결과인지
    let isPartial: Bool
    /// 지난번 같은 종류의 연습 기록 (비교용)
    var previous: PracticeRecord? = nil
    /// 이 악보의 모든 연습 기록 (다른 기기 기록 포함)
    var history: [PracticeRecord] = []
    let onRetryWeak: () -> Void
    let onRestart: () -> Void
    let onWholePiece: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    comparison
                    statGrid
                    measureStrip
                    if !report.confusions.isEmpty { confusionSection }
                    if let rhythm = report.rhythm { rhythmSection(rhythm) }
                    tipsSection
                    actions
                }
                .padding()
            }
            .navigationTitle("연주 결과")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("닫기") { dismiss() }
                }
            }
        }
    }

    // MARK: 머리말

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { i in
                    Image(systemName: i < report.stars ? "star.fill" : "star")
                        .font(.system(size: 34))
                        .foregroundStyle(i < report.stars ? Color.yellow : Color.gray.opacity(0.4))
                }
            }
            Text(report.headline)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            if isPartial {
                Text("선택한 마디만 연습한 결과입니다")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 지난번과 비교

    @ViewBuilder
    private var comparison: some View {
        let full = history.filter { !$0.partial }.sorted { $0.date < $1.date }
        if previous != nil || full.count > 1 {
            VStack(alignment: .leading, spacing: 8) {
                if let prev = previous {
                    let diff = report.accuracy - prev.accuracy
                    HStack {
                        Text("지난번 \(prev.accuracy)% → 이번 \(report.accuracy)%")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Text(diff > 0 ? "▲ \(diff)" : diff < 0 ? "▼ \(-diff)" : "그대로")
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .foregroundStyle(diff > 0 ? Color.green : diff < 0 ? Color.red : Color.secondary)
                    }
                    Text(prev.date.formatted(.relative(presentation: .named)) + (prev.device.isEmpty ? "" : " · \(prev.device)에서"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if full.count > 1 {
                    // 최근 연습 정확도 막대 (iCloud 로 다른 기기의 기록도 함께 보임)
                    HStack(alignment: .bottom, spacing: 4) {
                        ForEach(full.suffix(12)) { r in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(r.accuracy >= 90 ? Color.green : r.accuracy >= 70 ? Color.orange : Color.red)
                                .frame(height: max(4, CGFloat(r.accuracy) * 0.5))
                        }
                    }
                    .frame(height: 50, alignment: .bottom)
                    Text("최근 \(min(full.count, 12))번의 곡 전체 연습 · 최고 \(full.map(\.accuracy).max() ?? 0)%")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.08)))
        }
    }

    // MARK: 숫자 요약

    private var statGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 10) {
            StatTile(title: "한 번에 맞힘", value: "\(report.accuracy)%",
                     color: report.accuracy >= 90 ? .green : report.accuracy >= 70 ? .orange : .red)
            StatTile(title: "완주", value: "\(report.clean + report.recovered)/\(report.totalSteps)",
                     color: report.skipped == 0 ? .green : .orange)
            StatTile(title: "틀린 횟수", value: "\(report.totalMistakes)회",
                     color: report.totalMistakes == 0 ? .green : .red)
            StatTile(title: "최고 연속", value: "\(report.bestStreak)개", color: .blue)
            StatTile(title: "연습 시간", value: durationText, color: .secondary)
        }
    }

    private var durationText: String {
        let s = Int(report.elapsed.rounded())
        return s >= 60 ? "\(s / 60)분 \(s % 60)초" : "\(s)초"
    }

    // MARK: 마디별 결과

    private var measureStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("마디별 결과").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 38), spacing: 6)], spacing: 6) {
                ForEach(report.measureStats) { m in
                    VStack(spacing: 2) {
                        Text("\(m.measure + 1)").font(.caption.weight(.bold))
                        Text(m.mistakes + m.skipped == 0 ? "✓" : String(m.mistakes + m.skipped))
                            .font(.caption2)
                    }
                    .frame(maxWidth: .infinity, minHeight: 38)
                    .background(RoundedRectangle(cornerRadius: 6).fill(color(for: m.grade).opacity(0.25)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(color(for: m.grade), lineWidth: 1))
                }
            }
            HStack(spacing: 12) {
                legend(.green, "실수 없음")
                legend(.orange, "1~2번 실수")
                legend(.red, "3번 이상 / 건너뜀")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private func color(for grade: PracticeReport.MeasureStat.Grade) -> Color {
        switch grade {
        case .perfect: return .green
        case .minor: return .orange
        case .weak: return .red
        }
    }

    private func legend(_ c: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(c).frame(width: 8, height: 8)
            Text(text)
        }
    }

    // MARK: 자주 틀린 음

    private var confusionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("자주 틀린 음").font(.headline)
            ForEach(report.confusions) { c in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(c.count)회")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Capsule().fill(Color.red))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(NoteName.display(c.pair.expected, preferFlats: preferFlats)) 대신 \(NoteName.display(c.pair.played, preferFlats: preferFlats))")
                            .font(.subheadline.weight(.medium))
                        Text(MistakeHint.text(played: c.pair.played, expected: c.pair.expected))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: 박자

    private func rhythmSection(_ r: PracticeReport.Rhythm) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("박자 흐름").font(.headline)
            HStack {
                Text("내 빠르기 ♩≈\(r.userBPM)")
                Spacer()
                Text("악보 ♩=\(report.scoreTempo)").foregroundStyle(.secondary)
            }
            .font(.subheadline)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("박자 안정도").font(.subheadline)
                    Spacer()
                    Text("\(r.steadiness)%").font(.subheadline.weight(.bold).monospacedDigit())
                }
                ProgressView(value: Double(r.steadiness), total: 100)
                    .tint(r.steadiness >= 80 ? Color.green : r.steadiness >= 60 ? Color.orange : Color.red)
            }
            if !r.rushedMeasures.isEmpty {
                Text("서두른 곳: \(measureList(r.rushedMeasures))마디")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !r.draggedMeasures.isEmpty {
                Text("멈칫한 곳: \(measureList(r.draggedMeasures))마디")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("따라치기 모드는 맞을 때까지 기다리므로 박자는 참고용입니다. 실수 없이 이어 친 부분만 계산했어요.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func measureList(_ ms: [Int]) -> String {
        ms.prefix(6).map { "\($0 + 1)" }.joined(separator: ", ")
    }

    // MARK: 연습 팁

    private var tipsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("다음 연습 팁").font(.headline)
            ForEach(Array(report.tips(preferFlats: preferFlats).enumerated()), id: \.offset) { _, tip in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lightbulb.fill").foregroundStyle(.yellow)
                    Text(tip).font(.subheadline)
                }
            }
        }
    }

    // MARK: 버튼

    private var actions: some View {
        VStack(spacing: 10) {
            if !report.weakMeasures.isEmpty {
                Button(action: onRetryWeak) {
                    Label("틀린 마디만 다시 연습 (\(measureList(report.weakMeasures.map(\.measure).sorted()))마디)",
                          systemImage: "scope")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
            Button(action: onRestart) {
                Label("처음부터 다시", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            if isPartial {
                Button(action: onWholePiece) {
                    Label("곡 전체 연습으로", systemImage: "music.note.list")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .controlSize(.large)
    }
}

private struct StatTile: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(value).font(.title3.weight(.bold).monospacedDigit()).foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.1)))
    }
}
