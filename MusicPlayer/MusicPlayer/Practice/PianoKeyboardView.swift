import SwiftUI

/// 화면 건반. 색으로 칠 음 / 맞은 음 / 틀린 음을 보여 주고, 눌러서 소리를 낼 수 있습니다.
struct PianoKeyboardView: View {
    let lowest: Int
    let highest: Int
    var colors: [Int: Color] = [:]
    var onPress: ((Int) -> Void)? = nil

    static func isBlack(_ midi: Int) -> Bool {
        [1, 3, 6, 8, 10].contains(((midi % 12) + 12) % 12)
    }

    /// 악보 음역에 맞춘 건반 범위 (C 에서 시작, B 에서 끝, 최소 2옥타브)
    static func range(for pitches: [Int]) -> ClosedRange<Int> {
        var low = pitches.min() ?? 60
        var high = pitches.max() ?? 72
        if high - low < 24 {
            let mid = (low + high) / 2
            low = mid - 12
            high = mid + 12
        }
        low = max(21, low - ((low % 12) + 12) % 12)
        high = min(108, high + (11 - ((high % 12) + 12) % 12))
        return low...high
    }

    var body: some View {
        GeometryReader { geo in
            let whites = (lowest...highest).filter { !Self.isBlack($0) }
            let ww = geo.size.width / CGFloat(max(whites.count, 1))
            let bw = ww * 0.62
            let bh = geo.size.height * 0.62

            ZStack(alignment: .topLeading) {
                ForEach(Array(whites.enumerated()), id: \.element) { i, midi in
                    Rectangle()
                        .fill(colors[midi] ?? .white)
                        .overlay(Rectangle().stroke(Color.black.opacity(0.45), lineWidth: 0.5))
                        .overlay(alignment: .bottom) {
                            if midi % 12 == 0 {
                                Text(NoteName.name(midi))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.gray)
                                    .padding(.bottom, 3)
                            }
                        }
                        .frame(width: ww, height: geo.size.height)
                        .offset(x: CGFloat(i) * ww)
                        .onTapGesture { onPress?(midi) }
                }
                ForEach((lowest...highest).filter { Self.isBlack($0) }, id: \.self) { midi in
                    let whiteIndex = whites.firstIndex(of: midi - 1) ?? 0
                    RoundedRectangle(cornerRadius: 2)
                        .fill(colors[midi] ?? Color(white: 0.12))
                        .frame(width: bw, height: bh)
                        .offset(x: CGFloat(whiteIndex + 1) * ww - bw / 2)
                        .onTapGesture { onPress?(midi) }
                }
            }
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
