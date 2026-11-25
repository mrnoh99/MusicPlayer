import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// 첫 화면: 악보 목록과 가져오기 메뉴
struct LibraryView: View {
    @EnvironmentObject private var store: ScoreStore

    @State private var path: [UUID] = []
    @State private var showScanner = false
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var showSettings = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var importBatch: ImportBatch?
    @State private var alertMessage: String?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(store.scores) { score in
                    NavigationLink(value: score.id) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(score.title).font(.headline)
                            Text("\(score.measures.count)마디 · \(score.beatsPerMeasure)/\(score.beatUnit) · ♩=\(score.tempo)"
                                 + (score.composer.isEmpty ? "" : " · \(score.composer)"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .onDelete { store.delete(at: $0) }
            }
            .overlay {
                if store.scores.isEmpty {
                    ContentUnavailableView("악보가 없습니다", systemImage: "music.note.list",
                                           description: Text("오른쪽 위 + 버튼으로 악보를 촬영하거나 PDF·사진을 가져오세요."))
                }
            }
            .navigationTitle("악보")
            .navigationDestination(for: UUID.self) { id in
                ScoreDetailView(scoreID: id)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            if DocumentScannerView.isSupported {
                                showScanner = true
                            } else {
                                alertMessage = "이 기기에서는 카메라 스캔을 사용할 수 없습니다. (시뮬레이터에서는 사진이나 파일 가져오기를 사용하세요.)"
                            }
                        } label: { Label("카메라로 악보 촬영", systemImage: "camera") }
                        Button { showPhotos = true } label: { Label("사진에서 가져오기", systemImage: "photo.on.rectangle") }
                        Button { showFiles = true } label: { Label("PDF · 이미지 파일", systemImage: "doc") }
                        Divider()
                        Button {
                            let s = Score.blank()
                            store.add(s)
                            path.append(s.id)
                        } label: { Label("빈 악보 만들기", systemImage: "square.and.pencil") }
                        Button {
                            store.add(.twinkleExample)
                        } label: { Label("예제 악보 추가", systemImage: "star") }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .fullScreenCover(isPresented: $showScanner) {
                DocumentScannerView(onFinish: { images in
                    showScanner = false
                    if !images.isEmpty { importBatch = ImportBatch(images: images) }
                }, onCancel: {
                    showScanner = false
                })
                .ignoresSafeArea()
            }
            .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 20, matching: .images)
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                Task { await loadPhotos(items) }
            }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.pdf, .image], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    let images = urls.flatMap { ImageFileLoader.images(from: $0) }
                    if images.isEmpty {
                        alertMessage = "파일을 읽지 못했습니다."
                    } else {
                        importBatch = ImportBatch(images: images)
                    }
                case .failure(let error):
                    alertMessage = error.localizedDescription
                }
            }
            .sheet(item: $importBatch) { batch in
                ImportView(batch: batch) { score in
                    store.add(score)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        path.append(score.id)
                    }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .alert("알림", isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
                Button("확인", role: .cancel) {}
            } message: {
                Text(alertMessage ?? "")
            }
        }
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        var images: [UIImage] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                images.append(image)
            }
        }
        photoItems = []
        if images.isEmpty {
            alertMessage = "사진을 불러오지 못했습니다."
        } else {
            importBatch = ImportBatch(images: images)
        }
    }
}

/// 설정: API 키
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = APIKeyStore.current

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("sk-ant-…", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Anthropic API 키")
                } footer: {
                    Text("악보 사진·PDF 인식에 사용합니다. 키는 이 기기의 키체인에만 저장됩니다. console.anthropic.com 에서 발급받을 수 있으며 사용량만큼 요금이 부과됩니다. 재생·편집·연습 기능은 키 없이도 쓸 수 있습니다.")
                }
                Section("인식 모델") {
                    Text(OMRService.model)
                }
            }
            .navigationTitle("설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") {
                        Keychain.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: APIKeyStore.account)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
            }
        }
    }
}
