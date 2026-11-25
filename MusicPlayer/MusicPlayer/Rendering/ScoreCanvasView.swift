import SwiftUI
import UIKit

/// 악보 전체를 세로로 스크롤해 보여 주는 뷰
struct ScoreCanvasView: View {
    let score: Score
    var highlights: [UUID: Color] = [:]
    /// 이 음표가 있는 줄로 자동 스크롤
    var focusEventID: UUID? = nil
    var onTap: ((NoteEvent?) -> Void)? = nil

    var body: some View {
        GeometryReader { geo in
            let layout = ScoreLayout(score: score, width: geo.size.width)
            ScrollViewReader { proxy in
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        Canvas { context, size in
                            let uiHighlights = highlights.mapValues { UIColor($0) }
                            context.withCGContext { cg in
                                UIGraphicsPushContext(cg)
                                let drawer = ScoreDrawer(layout: layout, highlights: uiHighlights)
                                for system in layout.systems {
                                    drawer.drawSystem(system, in: cg,
                                                      originY: CGFloat(system.index) * ScoreLayout.systemHeight)
                                }
                                UIGraphicsPopContext()
                            }
                        }
                        .frame(width: geo.size.width, height: layout.totalHeight)

                        VStack(spacing: 0) {
                            ForEach(layout.systems, id: \.index) { system in
                                Color.clear
                                    .frame(height: ScoreLayout.systemHeight)
                                    .id("system-\(system.index)")
                            }
                        }
                        .allowsHitTesting(false)
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        SpatialTapGesture().onEnded { value in
                            onTap?(layout.hitTest(value.location))
                        },
                        including: onTap == nil ? .none : .all
                    )
                }
                .background(Color.white)
                .onChange(of: focusEventID) { _, newValue in
                    guard let id = newValue, let si = layout.systemIndex(containing: id) else { return }
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo("system-\(si)", anchor: .center)
                    }
                }
            }
        }
        .environment(\.colorScheme, .light)
    }
}
