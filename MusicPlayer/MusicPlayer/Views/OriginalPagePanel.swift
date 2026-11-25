import SwiftUI

/// 편집 중 원본 악보 사진을 위에 띄워 인식 결과와 비교하는 패널 (두 손가락으로 확대)
struct OriginalPagePanel: View {
    let pages: [ScorePage]
    @Binding var selection: Int

    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    private var page: ScorePage? { pages.indices.contains(selection) ? pages[selection] : pages.first }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "photo")
                Text("원본 · \(page?.displayTitle ?? "")").font(.subheadline.weight(.medium))
                Spacer()
                if pages.count > 1 {
                    Button { selection = max(0, selection - 1) } label: { Image(systemName: "chevron.left") }
                        .disabled(selection == 0)
                    Text("\(selection + 1)/\(pages.count)").font(.caption.monospacedDigit())
                    Button { selection = min(pages.count - 1, selection + 1) } label: { Image(systemName: "chevron.right") }
                        .disabled(selection >= pages.count - 1)
                }
                Button { zoom = 1 } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
                    .accessibilityLabel("확대 초기화")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)

            GeometryReader { geo in
                ScrollView([.horizontal, .vertical]) {
                    if let name = page?.image, let image = PageImageStore.load(name) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: geo.size.width * min(6, max(1, zoom * pinch)))
                    } else {
                        Text("원본 이미지가 없습니다").foregroundStyle(.secondary)
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                }
                .gesture(
                    MagnifyGesture()
                        .updating($pinch) { value, state, _ in state = value.magnification }
                        .onEnded { value in zoom = min(6, max(1, zoom * value.magnification)) }
                )
            }
            .background(Color(white: 0.95))
        }
        .onChange(of: selection) { _, _ in zoom = 1 }
    }
}
