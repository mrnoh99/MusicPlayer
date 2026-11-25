import SwiftUI

/// 악보 보기 · 편집 · 재생 화면
struct ScoreDetailView: View {
    let scoreID: UUID

    @EnvironmentObject private var store: ScoreStore
    @StateObject private var player = ScorePlayer()

    @State private var isEditing = false
    @State private var selectedID: UUID?
    @State private var showInfo = false
    @State private var showPractice = false
    @State private var shareURL: URL?
    @State private var exportError: String?

    private var score: Binding<Score> { store.binding(for: scoreID) }

    var body: some View {
        VStack(spacing: 0) {
            ScoreCanvasView(
                score: score.wrappedValue,
                highlights: highlights,
                focusEventID: player.isPlaying ? player.focusEventID : nil,
                onTap: { event in
                    if isEditing {
                        selectedID = event?.id
                        if let e = event, !e.isRest { PianoSynth.shared.preview(e.pitches) }
                    } else if let e = event, !e.isRest {
                        PianoSynth.shared.preview(e.pitches)
                    }
                }
            )

            if isEditing {
                ScoreEditorPanel(score: score, selectedID: $selectedID)
            }

            playbackBar
        }
        .navigationTitle(score.wrappedValue.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    isEditing.toggle()
                    if !isEditing { selectedID = nil }
                } label: {
                    Image(systemName: isEditing ? "checkmark.circle.fill" : "pencil.circle")
                }
                .accessibilityLabel(isEditing ? "편집 완료" : "편집")

                Menu {
                    Button { showInfo = true } label: { Label("제목·빠르기·박자·조표", systemImage: "info.circle") }
                    Button { exportPDF() } label: { Label("PDF로 내보내기", systemImage: "square.and.arrow.up") }
                    Button { showPractice = true } label: { Label("연습 모드 (마이크)", systemImage: "mic") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showInfo) { ScoreInfoSheet(score: score) }
        .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) {
            if let url = shareURL { ActivityView(items: [url]) }
        }
        .fullScreenCover(isPresented: $showPractice) {
            PracticeView(score: score.wrappedValue)
        }
        .alert("PDF 내보내기 실패", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
        .onDisappear { player.stop() }
    }

    private var highlights: [UUID: Color] {
        var h: [UUID: Color] = [:]
        for id in player.activeEventIDs { h[id] = .green }
        if let id = selectedID { h[id] = .blue }
        return h
    }

    private var playbackBar: some View {
        HStack(spacing: 16) {
            Button {
                player.toggle(score.wrappedValue, fromMeasure: startMeasure)
            } label: {
                Image(systemName: player.isPlaying ? "stop.fill" : "play.fill")
                    .font(.title2)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.borderedProminent)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text("빠르기 ♩=\(Int(Double(score.wrappedValue.tempo) * player.tempoScale))")
                    .font(.caption)
                Slider(value: $player.tempoScale, in: 0.4...1.5, step: 0.05)
            }

            Menu {
                Button("양손") { player.staves = Set(Staff.allCases) }
                Button("오른손만") { player.staves = [.treble] }
                Button("왼손만") { player.staves = [.bass] }
            } label: {
                Label(handLabel, systemImage: "hand.raised")
                    .font(.caption)
            }
            .disabled(player.isPlaying)

            Button {
                showPractice = true
            } label: {
                Image(systemName: "mic.circle.fill").font(.title)
            }
            .accessibilityLabel("연습 모드")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var handLabel: String {
        if player.staves.count == 2 { return "양손" }
        return player.staves.contains(.treble) ? "오른손" : "왼손"
    }

    /// 편집 중 음표를 선택했으면 그 마디부터 재생
    private var startMeasure: Int {
        guard let id = selectedID, let loc = score.wrappedValue.locate(id) else { return 0 }
        return loc.measure
    }

    private func exportPDF() {
        do {
            shareURL = try PDFExporter.export(score.wrappedValue)
        } catch {
            exportError = error.localizedDescription
        }
    }
}
