import SwiftUI

/// 악보 보기 · 편집 · 재생 화면
struct ScoreDetailView: View {
    let scoreID: UUID

    @EnvironmentObject private var store: ScoreStore
    @EnvironmentObject private var progress: ProgressStore
    @StateObject private var player = ScorePlayer()

    @State private var isEditing = false
    @State private var selectedID: UUID?
    @State private var showInfo = false
    @State private var showPractice = false
    @State private var shareURL: URL?
    @State private var exportError: String?
    @State private var showPages = false
    @State private var showOriginal = false
    @State private var originalPage = 0
    @State private var undoStack: [Score] = []
    @State private var redoStack: [Score] = []

    private var score: Binding<Score> { store.binding(for: scoreID) }

    /// 편집용 바인딩: 바뀔 때마다 이전 상태를 되돌리기 목록에 저장
    private var editableScore: Binding<Score> {
        Binding(
            get: { score.wrappedValue },
            set: { new in
                let old = score.wrappedValue
                guard old != new else { return }
                undoStack.append(old)
                if undoStack.count > 100 { undoStack.removeFirst() }
                redoStack.removeAll()
                score.wrappedValue = new
            }
        )
    }

    private var pagesWithImages: [ScorePage] { score.wrappedValue.pages.filter { $0.image != nil } }

    var body: some View {
        VStack(spacing: 0) {
            if isEditing && showOriginal {
                OriginalPagePanel(pages: pagesWithImages, selection: $originalPage)
                    .frame(maxHeight: 260)
                Divider()
            }
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
                ScoreEditorPanel(score: editableScore, selectedID: $selectedID)
            }

            playbackBar
        }
        .navigationTitle(score.wrappedValue.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if isEditing {
                    Button { undo() } label: { Image(systemName: "arrow.uturn.backward") }
                        .disabled(undoStack.isEmpty)
                        .accessibilityLabel("되돌리기")
                    Button { redo() } label: { Image(systemName: "arrow.uturn.forward") }
                        .disabled(redoStack.isEmpty)
                        .accessibilityLabel("다시 하기")
                    if !pagesWithImages.isEmpty {
                        Button {
                            showOriginal.toggle()
                            syncOriginalPage()
                        } label: {
                            Image(systemName: showOriginal ? "photo.fill" : "photo")
                        }
                        .accessibilityLabel("원본 악보 보기")
                    }
                }
                Button {
                    isEditing.toggle()
                    if !isEditing { selectedID = nil }
                } label: {
                    Image(systemName: isEditing ? "checkmark.circle.fill" : "pencil.circle")
                }
                .accessibilityLabel(isEditing ? "편집 완료" : "편집")

                Menu {
                    Button { showInfo = true } label: { Label("제목·빠르기·박자·조표", systemImage: "info.circle") }
                    Button { showPages = true } label: {
                        Label("페이지 관리 (\(score.wrappedValue.pageCount)쪽)", systemImage: "book.pages")
                    }
                    Button { exportPDF() } label: { Label("PDF로 내보내기", systemImage: "square.and.arrow.up") }
                    Button { showPractice = true } label: { Label("연습 모드 (마이크)", systemImage: "mic") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showInfo) { ScoreInfoSheet(score: editableScore) }
        .sheet(isPresented: $showPages) {
            PageManagerView(score: editableScore)
                .environmentObject(store)
        }
        .onChange(of: selectedID) { _, _ in syncOriginalPage() }
        .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) {
            if let url = shareURL { ActivityView(items: [url]) }
        }
        .fullScreenCover(isPresented: $showPractice) {
            PracticeView(score: score.wrappedValue)
                .environmentObject(progress)
        }
        .alert("PDF 내보내기 실패", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
        .onDisappear { player.stop() }
    }

    // MARK: 되돌리기

    private func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(score.wrappedValue)
        score.wrappedValue = previous
        if let id = selectedID, previous.locate(id) == nil { selectedID = nil }
    }

    private func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(score.wrappedValue)
        score.wrappedValue = next
        if let id = selectedID, next.locate(id) == nil { selectedID = nil }
    }

    /// 고른 음표가 있는 페이지의 원본을 보여 줌
    private func syncOriginalPage() {
        guard let id = selectedID, let loc = score.wrappedValue.locate(id) else { return }
        let page = score.wrappedValue.pages[score.wrappedValue.pageIndex(ofMeasure: loc.measure)]
        if let i = pagesWithImages.firstIndex(where: { $0.id == page.id }) { originalPage = i }
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
            let url = try PDFExporter.export(score.wrappedValue)
            // iCloud Drive (또는 기기)의 PDF 폴더에도 보관
            let saved = SyncFolder.folder("PDF").appendingPathComponent(url.lastPathComponent)
            if let data = try? Data(contentsOf: url) {
                DispatchQueue.global(qos: .utility).async { SyncFolder.write(data, to: saved) }
            }
            shareURL = url
        } catch {
            exportError = error.localizedDescription
        }
    }
}
