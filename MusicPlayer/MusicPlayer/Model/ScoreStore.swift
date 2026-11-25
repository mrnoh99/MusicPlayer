import Foundation
import SwiftUI

/// 악보 목록. 악보마다 Scores/<id>.json 파일 하나로 SyncFolder(iCloud Drive 또는 기기)에 저장합니다.
/// 다른 기기에서 바뀐 파일은 자동으로 다시 읽어 합칩니다 (더 최근에 고친 쪽이 남음).
@MainActor
final class ScoreStore: ObservableObject {
    @Published var scores: [Score] = [] {
        didSet { scheduleSave() }
    }
    @Published private(set) var isLoaded = false
    @Published private(set) var isCloud = false
    /// iCloud 에서 아직 내려받는 중인 악보 수
    @Published private(set) var downloading = 0

    /// 마지막으로 디스크와 맞춘 내용 (바뀐 악보만 저장하기 위해)
    private var written: [UUID: Data] = [:]
    /// 이 기기에서 지운 악보 (파일 삭제가 끝나기 전에 다시 읽혀 되살아나지 않도록)
    private var deletedHere: Set<UUID> = []
    private var saveWork: DispatchWorkItem?
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

    private var folder: URL { SyncFolder.folder("Scores") }

    init() {
        Task { await start() }
    }

    private func start() async {
        await SyncFolder.prepare()
        isCloud = SyncFolder.isCloud
        migrateLegacyFile()
        reload()
        if scores.isEmpty && downloading == 0 {
            scores = [.twinkleExample]
        }
        isLoaded = true
        observer = NotificationCenter.default.addObserver(forName: SyncFolder.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        cleanUpImages()
    }

    // MARK: 조작

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
        var s = score
        if let i = scores.firstIndex(where: { $0.id == score.id }) {
            guard scores[i] != s else { return }
            s.modifiedAt = Date()
            scores[i] = s
        } else {
            s.modifiedAt = Date()
            scores.insert(s, at: 0)
        }
    }

    func add(_ score: Score) {
        var s = score
        s.modifiedAt = Date()
        scores.insert(s, at: 0)
    }

    func delete(at offsets: IndexSet) {
        scores.remove(atOffsets: offsets)
    }

    // MARK: 저장

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func saveNow() {
        guard isLoaded else { return }
        let folder = self.folder
        var toWrite: [(URL, Data)] = []
        var toDelete: [URL] = []
        let ids = Set(scores.map(\.id))

        for s in scores {
            guard let data = try? Self.encoder.encode(s), written[s.id] != data else { continue }
            written[s.id] = data
            toWrite.append((folder.appendingPathComponent("\(s.id.uuidString).json"), data))
        }
        for id in written.keys where !ids.contains(id) {
            written[id] = nil
            deletedHere.insert(id)
            toDelete.append(folder.appendingPathComponent("\(id.uuidString).json"))
        }
        guard !toWrite.isEmpty || !toDelete.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            for (url, data) in toWrite { SyncFolder.write(data, to: url) }
            for url in toDelete { SyncFolder.delete(url) }
        }
    }

    // MARK: 읽기 · 다른 기기와 합치기

    func reload() {
        let (files, downloading) = SyncFolder.files(in: folder, ext: "json")
        self.downloading = downloading

        var disk: [UUID: (Score, Data)] = [:]
        for url in files {
            guard let data = SyncFolder.read(url),
                  let s = try? Self.decoder.decode(Score.self, from: data) else { continue }
            disk[s.id] = (s, data)
        }

        var merged = scores
        var changed = false
        // 디스크(다른 기기)에서 새로 생기거나 바뀐 악보
        for (id, (remote, data)) in disk where written[id] != data && !deletedHere.contains(id) {
            if let i = merged.firstIndex(where: { $0.id == id }) {
                let localDate = merged[i].modifiedAt ?? .distantPast
                let remoteDate = remote.modifiedAt ?? .distantPast
                if remoteDate > localDate {
                    merged[i] = remote
                    changed = true
                }
            } else if written[id] == nil || isLoaded == false {
                merged.append(remote)
                changed = true
            }
            written[id] = data
        }
        // 다른 기기에서 지운 악보 (전에 디스크에 있었는데 지금은 없음)
        let goneIDs = Set(written.keys).subtracting(disk.keys)
        if isLoaded, !goneIDs.isEmpty, downloading == 0 {
            merged.removeAll { goneIDs.contains($0.id) }
            for id in goneIDs { written[id] = nil }
            changed = true
        }

        if changed {
            merged.sort { ($0.modifiedAt ?? $0.createdAt) > ($1.modifiedAt ?? $1.createdAt) }
            scores = merged
        }
    }

    // MARK: 이전 버전 데이터

    /// 예전 scores.json (한 파일에 모든 악보) → 악보별 파일
    private func migrateLegacyFile() {
        let legacy = SyncFolder.localRoot.appendingPathComponent("scores.json")
        guard let data = try? Data(contentsOf: legacy) else { return }
        do {
            let old = try JSONDecoder().decode([Score].self, from: data)
            for s in old {
                guard let encoded = try? Self.encoder.encode(s) else { continue }
                let url = folder.appendingPathComponent("\(s.id.uuidString).json")
                if !FileManager.default.fileExists(atPath: url.path) { SyncFolder.write(encoded, to: url) }
            }
            try? FileManager.default.moveItem(at: legacy, to: legacy.appendingPathExtension("migrated"))
        } catch {
            print("예전 악보 파일을 읽지 못했습니다: \(error)")
        }
    }

    /// 어떤 악보에서도 쓰지 않는 원본 이미지 정리.
    /// iCloud 에서는 다른 기기의 악보가 아직 안 보일 수 있어 지우지 않음 (지우면 모든 기기에서 사라짐).
    private func cleanUpImages() {
        guard !SyncFolder.isCloud, !scores.isEmpty else { return }
        let used = Set(scores.flatMap { $0.measures.compactMap(\.pageImage) })
        DispatchQueue.global(qos: .utility).async {
            PageImageStore.removeUnused(keeping: used)
        }
    }
}
