import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// 악보 이미지를 가져오는 경로
enum ImageSourceKind: Identifiable {
    case camera, photos, files
    var id: Self { self }
}

extension View {
    /// 카메라 스캔 · 사진 · PDF/이미지 파일에서 악보 이미지를 가져옴 (목록 화면과 페이지 관리 화면이 함께 사용)
    func imageImporter(source: Binding<ImageSourceKind?>,
                       onImages: @escaping ([UIImage]) -> Void,
                       onError: @escaping (String) -> Void) -> some View {
        modifier(ImageImportModifier(source: source, onImages: onImages, onError: onError))
    }
}

private struct ImageImportModifier: ViewModifier {
    @Binding var source: ImageSourceKind?
    let onImages: ([UIImage]) -> Void
    let onError: (String) -> Void

    @State private var photoItems: [PhotosPickerItem] = []

    private func isPresented(_ kind: ImageSourceKind) -> Binding<Bool> {
        Binding(get: { source == kind }, set: { if !$0, source == kind { source = nil } })
    }

    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: isPresented(.camera)) {
                DocumentScannerView(onFinish: { images in
                    source = nil
                    if !images.isEmpty { onImages(images) }
                }, onCancel: {
                    source = nil
                })
                .ignoresSafeArea()
            }
            .photosPicker(isPresented: isPresented(.photos), selection: $photoItems,
                          maxSelectionCount: 20, matching: .images)
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                Task { await loadPhotos(items) }
            }
            .fileImporter(isPresented: isPresented(.files), allowedContentTypes: [.pdf, .image],
                          allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    let images = urls.flatMap { ImageFileLoader.images(from: $0) }
                    if images.isEmpty { onError("파일을 읽지 못했습니다.") } else { onImages(images) }
                case .failure(let error):
                    onError(error.localizedDescription)
                }
            }
    }

    @MainActor
    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        var images: [UIImage] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                images.append(image)
            }
        }
        photoItems = []
        if images.isEmpty { onError("사진을 불러오지 못했습니다.") } else { onImages(images) }
    }
}

/// 가져오기 메뉴 항목 (카메라 · 사진 · 파일)
struct ImageSourceButtons: View {
    @Binding var source: ImageSourceKind?
    var onCameraUnavailable: () -> Void

    var body: some View {
        Button {
            if DocumentScannerView.isSupported { source = .camera } else { onCameraUnavailable() }
        } label: { Label("카메라로 악보 촬영", systemImage: "camera") }
        Button { source = .photos } label: { Label("사진에서 가져오기", systemImage: "photo.on.rectangle") }
        Button { source = .files } label: { Label("PDF · 이미지 파일", systemImage: "doc") }
    }
}
