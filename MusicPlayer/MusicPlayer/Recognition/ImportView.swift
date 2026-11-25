import SwiftUI

struct ImportBatch: Identifiable {
    let id = UUID()
    var images: [UIImage]
}

/// 가져온 페이지를 확인하고 인식을 실행하는 화면
struct ImportView: View {
    @State var batch: ImportBatch
    var onCreated: (Score) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var isWorking = false
    @State private var startedAt = Date()
    @State private var errorMessage: String?
    @State private var showSettings = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section("페이지 (\(batch.images.count))") {
                    ScrollView(.horizontal) {
                        HStack(spacing: 10) {
                            ForEach(Array(batch.images.enumerated()), id: \.offset) { i, image in
                                VStack {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(height: 180)
                                        .border(.gray.opacity(0.4))
                                    HStack {
                                        Text("\(i + 1)").font(.caption)
                                        if batch.images.count > 1 && !isWorking {
                                            Button(role: .destructive) {
                                                batch.images.remove(at: i)
                                            } label: {
                                                Image(systemName: "xmark.circle.fill")
                                            }
                                            .buttonStyle(.borderless)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section {
                    TextField("곡 제목 (선택)", text: $title)
                } footer: {
                    Text("인식은 Claude(\(OMRService.model))가 이미지를 읽어 악보 데이터로 바꿉니다. 인쇄된 악보에서 가장 정확하며, 결과는 편집 화면에서 고칠 수 있습니다.")
                }

                Section {
                    if isWorking {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            HStack {
                                ProgressView()
                                Text("악보를 읽는 중… \(Int(context.date.timeIntervalSince(startedAt)))초")
                                    .padding(.leading, 8)
                            }
                        }
                        Button("취소", role: .cancel) {
                            task?.cancel()
                            isWorking = false
                        }
                    } else {
                        Button {
                            recognize()
                        } label: {
                            Label("악보 인식 시작", systemImage: "text.viewfinder")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(batch.images.isEmpty)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                        if APIKeyStore.current.isEmpty {
                            Button("API 키 설정하기") { showSettings = true }
                        }
                    }
                }
            }
            .navigationTitle("악보 가져오기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") {
                        task?.cancel()
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .interactiveDismissDisabled(isWorking)
        }
    }

    private func recognize() {
        errorMessage = nil
        isWorking = true
        startedAt = Date()
        let images = batch.images
        let hint = title
        task = Task {
            do {
                let score = try await OMRService(apiKey: APIKeyStore.current)
                    .recognize(images: images, titleHint: hint)
                if Task.isCancelled { return }
                isWorking = false
                onCreated(score)
                dismiss()
            } catch {
                if Task.isCancelled { return }
                isWorking = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
