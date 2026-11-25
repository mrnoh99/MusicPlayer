import SwiftUI

/// 악보 한 권(책)의 페이지 관리: 추가 · 삭제 · 순서 바꾸기 · 이름 · 합치기
struct PageManagerView: View {
    @Binding var score: Score

    @EnvironmentObject private var store: ScoreStore
    @Environment(\.dismiss) private var dismiss

    @State private var source: ImageSourceKind?
    @State private var importBatch: ImportBatch?
    @State private var showScorePicker = false
    @State private var renaming: Int?
    @State private var renameText = ""
    @State private var alertMessage: String?

    private var pages: [ScorePage] { score.pages }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { i, page in
                        row(page, index: i)
                    }
                    .onMove { score.movePages(fromOffsets: $0, toOffset: $1) }
                    .onDelete { offsets in
                        withAnimation { score.removePages(atOffsets: offsets) }
                    }
                } header: {
                    Text("\(pages.count)쪽 · \(score.measures.count)마디")
                } footer: {
                    Text("오른쪽 ≡ 를 끌어 순서를 바꾸고, 빨간 ⊖ 로 페이지를 뺍니다. ⋯ 에서 이름 바꾸기·앞 페이지와 합치기를 할 수 있어요. 편집 화면에서 마디를 고른 뒤 '이 마디부터 새 페이지'로 페이지를 나눌 수도 있습니다.")
                }

                Section("페이지 추가") {
                    ImageSourceButtons(source: $source) {
                        alertMessage = "이 기기에서는 카메라 스캔을 사용할 수 없습니다."
                    }
                    Button { showScorePicker = true } label: {
                        Label("다른 악보를 페이지로 넣기", systemImage: "books.vertical")
                    }
                    .disabled(store.scores.count < 2)
                    Button {
                        withAnimation { score.appendBlankPage() }
                    } label: {
                        Label("빈 페이지", systemImage: "doc.badge.plus")
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("페이지 관리")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
            .imageImporter(source: $source, onImages: { importBatch = ImportBatch(images: $0) },
                           onError: { alertMessage = $0 })
            .sheet(item: $importBatch) { batch in
                ImportView(batch: batch, screenTitle: "페이지 추가") { recognized in
                    withAnimation { score.insertPages(from: recognized) }
                }
            }
            .sheet(isPresented: $showScorePicker) {
                ScorePickerView(current: score) { other in
                    withAnimation { score.insertPages(from: other, titlePrefix: other.title) }
                }
            }
            .alert("페이지 이름", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("예: 1악장, 2절", text: $renameText)
                Button("저장") {
                    if let i = renaming { score.renamePage(i, to: renameText) }
                    renaming = nil
                }
                Button("취소", role: .cancel) { renaming = nil }
            }
            .alert("알림", isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
                Button("확인", role: .cancel) {}
            } message: {
                Text(alertMessage ?? "")
            }
        }
    }

    private func row(_ page: ScorePage, index: Int) -> some View {
        HStack(spacing: 12) {
            thumbnail(page)
            VStack(alignment: .leading, spacing: 3) {
                Text(page.displayTitle).font(.headline)
                Text("\(page.measureRange.lowerBound + 1)–\(page.measureRange.upperBound)마디 · \(page.measureRange.count)마디")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button {
                    renameText = page.title ?? ""
                    renaming = index
                } label: { Label("이름 바꾸기", systemImage: "pencil") }
                if index > 0 {
                    Button {
                        withAnimation { score.movePages(fromOffsets: [index], toOffset: index - 1) }
                    } label: { Label("앞으로", systemImage: "arrow.up") }
                    Button {
                        withAnimation { score.mergePageWithPrevious(index) }
                    } label: { Label("앞 페이지와 합치기", systemImage: "arrow.up.and.down.square") }
                }
                if index < pages.count - 1 {
                    Button {
                        withAnimation { score.movePages(fromOffsets: [index], toOffset: index + 2) }
                    } label: { Label("뒤로", systemImage: "arrow.down") }
                }
                Divider()
                Button(role: .destructive) {
                    withAnimation { score.removePages(atOffsets: [index]) }
                } label: { Label("페이지 빼기", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func thumbnail(_ page: ScorePage) -> some View {
        Group {
            if let name = page.image, let image = PageImageStore.load(name) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Color.white
                    Image(systemName: "music.note.list").foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 44, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.4)))
    }
}

/// 다른 악보 고르기 (책에 페이지로 넣기)
private struct ScorePickerView: View {
    let current: Score
    var onPick: (Score) -> Void

    @EnvironmentObject private var store: ScoreStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(store.scores.filter { $0.id != current.id }) { s in
                Button {
                    onPick(s)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(s.title).font(.headline)
                        Text("\(s.pageCount)쪽 · \(s.measures.count)마디 · \(s.beatsPerMeasure)/\(s.beatUnit)")
                            .font(.caption).foregroundStyle(.secondary)
                        if s.beatsPerMeasure != current.beatsPerMeasure || s.beatUnit != current.beatUnit
                            || s.keyFifths != current.keyFifths {
                            Label("박자표·조표가 달라요. 넣은 뒤에는 이 책의 박자표·조표로 표시됩니다.",
                                  systemImage: "exclamationmark.triangle")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
            .navigationTitle("넣을 악보 선택")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
            }
        }
    }
}
