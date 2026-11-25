import Foundation

/// 한 번의 연습 결과
struct PracticeRecord: Codable, Identifiable, Hashable {
    var id = UUID()
    var date = Date()
    var accuracy: Int          // 한 번에 맞힌 비율 %
    var completion: Int        // 건너뛰지 않은 비율 %
    var mistakes: Int
    var stars: Int
    var elapsed: TimeInterval
    var hands: String          // "양손" / "오른손" / "왼손"
    var partial: Bool          // 일부 마디만 연습
    var weakMeasures: [Int]    // 0 부터
    var device: String = ""    // 연습한 기기 (iPhone / iPad)
}

/// 악보 하나의 진도: 연습 기록과 이어서 할 위치
struct ScoreProgress: Codable, Hashable {
    var records: [PracticeRecord] = []
    /// 멈춘 마디 (0 부터). 끝까지 치면 nil
    var resumeMeasure: Int?
    var resumeHands: String?
    var updatedAt = Date()

    var last: PracticeRecord? { records.max { $0.date < $1.date } }
    var best: PracticeRecord? { records.filter { !$0.partial }.max { $0.accuracy < $1.accuracy } }

    /// 두 기기의 진도 합치기: 기록은 모두 모으고, 이어서 할 위치는 더 최근 것
    func merged(with other: ScoreProgress) -> ScoreProgress {
        var result = updatedAt >= other.updatedAt ? self : other
        var byID: [UUID: PracticeRecord] = [:]
        for r in records + other.records { byID[r.id] = r }
        result.records = byID.values.sorted { $0.date < $1.date }
        return result
    }
}

/// 연습 진도 저장소. 악보마다 Progress/<악보 id>.json 으로 SyncFolder(iCloud)에 저장되어 기기끼리 맞춰집니다.
@MainActor
final class ProgressStore: ObservableObject {
    @Published private(set) var progress: [UUID: ScoreProgress] = [:]

    private var written: [UUID: Data] = [:]
    private var observer: NSObjectProtocol?

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private var folder: URL { SyncFolder.folder("Progress") }

    init() {
        Task {
            await SyncFolder.prepare()
            reload()
            observer = NotificationCenter.default.addObserver(forName: SyncFolder.didChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            }
        }
    }

    func progress(for id: UUID) -> ScoreProgress { progress[id] ?? ScoreProgress() }

    func add(_ record: PracticeRecord, for scoreID: UUID, clearResume: Bool) {
        var p = progress(for: scoreID)
        p.records.append(record)
        if p.records.count > 200 { p.records.removeFirst(p.records.count - 200) }
        if clearResume {
            p.resumeMeasure = nil
            p.resumeHands = nil
        }
        p.updatedAt = Date()
        save(p, for: scoreID)
    }

    func setResume(measure: Int?, hands: String?, for scoreID: UUID) {
        var p = progress(for: scoreID)
        guard p.resumeMeasure != measure || p.resumeHands != hands else { return }
        p.resumeMeasure = measure
        p.resumeHands = measure == nil ? nil : hands
        p.updatedAt = Date()
        save(p, for: scoreID)
    }

    private func save(_ p: ScoreProgress, for id: UUID) {
        progress[id] = p
        guard let data = try? Self.encoder.encode(p) else { return }
        written[id] = data
        let url = folder.appendingPathComponent("\(id.uuidString).json")
        DispatchQueue.global(qos: .utility).async { SyncFolder.write(data, to: url) }
    }

    func reload() {
        let (files, _) = SyncFolder.files(in: folder, ext: "json")
        for url in files {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  let data = SyncFolder.read(url), written[id] != data,
                  let remote = try? Self.decoder.decode(ScoreProgress.self, from: data) else { continue }
            written[id] = data
            if let local = progress[id] {
                let merged = local.merged(with: remote)
                if merged != remote {
                    save(merged, for: id)     // 이 기기에만 있던 기록을 다시 올림
                } else {
                    progress[id] = merged
                }
            } else {
                progress[id] = remote
            }
        }
    }
}
