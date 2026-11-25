import Foundation
import SwiftUI

/// 악보 목록을 앱 Documents 폴더의 JSON 파일로 저장합니다.
final class ScoreStore: ObservableObject {
    @Published var scores: [Score] = [] {
        didSet { save() }
    }

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("scores.json")
    }()

    init() {
        load()
        if scores.isEmpty {
            scores = [.twinkleExample]
        }
    }

    func score(_ id: UUID) -> Score? {
        scores.first { $0.id == id }
    }

    func binding(for id: UUID) -> Binding<Score> {
        Binding(
            get: { self.score(id) ?? Score.blank() },
            set: { self.update($0) }
        )
    }

    func update(_ score: Score) {
        if let i = scores.firstIndex(where: { $0.id == score.id }) {
            scores[i] = score
        } else {
            scores.insert(score, at: 0)
        }
    }

    func add(_ score: Score) {
        scores.insert(score, at: 0)
    }

    func delete(at offsets: IndexSet) {
        scores.remove(atOffsets: offsets)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            scores = try JSONDecoder().decode([Score].self, from: data)
        } catch {
            print("악보 불러오기 실패: \(error)")
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(scores)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("악보 저장 실패: \(error)")
        }
    }
}
