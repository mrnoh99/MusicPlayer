import SwiftUI

struct ImportBatch: Identifiable {
    let id = UUID()
    var images: [UIImage]
}

/// 가져온 페이지를 확인하고 인식을 실행하는 화면
struct ImportView: View {
    @State var batch: ImportBatch
    /// "악보 가져오기" 또는 "페이지 추가"
    var screenTitle = "악보 가져오기"
    var onCreated: (Score) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var isWorking = false
    @State private var startedAt = Date()
    @State private var errorMessage: String?
    @State private var showSettings = false
    @State private var task: Task<Void, Never>?
    @State private var verify = true
    @State private var stage: OMRService.Stage = .preparing

    var body: some View {
        NavigationStack {
            Form {
                Section {
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
                                        if i > 0 && !isWorking {
                                            Button {
                                                batch.images.swapAt(i, i - 1)
                                            } label: { Image(systemName: "chevron.left.circle") }
                                            .buttonStyle(.borderless)
                                            .accessibilityLabel("앞으로")
                                        }
                                        Text("\(i + 1)쪽").font(.caption)
                                        if i < batch.images.count - 1 && !isWorking {
                                            Button {
                                                batch.images.swapAt(i, i + 1)
                                            } label: { Image(systemName: "chevron.right.circle") }
                                            .buttonStyle(.borderless)
                                            .accessibilityLabel("뒤로")
                                        }
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
                } header: {
                    Text("페이지 (\(batch.images.count))")
                } footer: {
                    Text("‹ › 로 페이지 순서를 바꾸고, ⓧ 로 뺄 수 있습니다. 인식한 뒤에도 페이지 관리에서 순서를 바꿀 수 있어요.")
                }

                Section {
                    TextField("곡 제목 (선택)", text: $title)
                    Toggle(isOn: $verify) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("AI 2차 검토")
                            Text("AI가 처음 읽은 결과를 원본과 마디마다 다시 대조해 고칩니다. 더 정확하지만 시간·비용이 약 2배입니다.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(isWorking)
                } footer: {
                    Text("인식은 Claude(\(OMRService.model))가 이미지를 읽어 악보 데이터로 바꿉니다. 사진은 기울기를 펴고 흑백으로 다듬은 뒤 보냅니다. 인쇄된 악보에서 가장 정확하며, 틀린 곳은 편집 화면에서 원본과 비교하며 고치거나 'AI로 이 마디 다시 읽기'로 고칠 수 있습니다.")
                }

                Section {
                    if isWorking {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            HStack {
                                ProgressView()
                                Text("\(stage.rawValue)… \(Int(context.date.timeIntervalSince(startedAt)))초")
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
            .navigationTitle(screenTitle)
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
                    .recognize(images: images, titleHint: hint, verify: verify) { newStage in
                        Task { @MainActor in stage = newStage }
                    }
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
