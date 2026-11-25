import Foundation

/// 데이터 저장 위치.
/// iCloud 를 쓸 수 있으면 iCloud Drive 의 "악보 플레이어" 폴더(파일 앱에서 보임)에 저장해
/// 같은 Apple ID 로 로그인한 iPhone · iPad 끼리 악보와 연습 기록이 자동으로 맞춰집니다.
/// iCloud 가 꺼져 있으면 기기 안(Documents)에 저장합니다.
///
/// 폴더 구성
///   Scores/<악보 id>.json      악보 (페이지·표식 포함)
///   Progress/<악보 id>.json    연습 기록과 이어서 할 위치
///   PageImages/<이름>.jpg      원본 악보 사진
///   PDF/<제목>.pdf             내보낸 PDF
enum SyncFolder {
    static let containerID = "iCloud.com.mrnoh99.MusicPlayer"
    /// 다른 기기에서 파일이 바뀌었을 때 (메인 스레드에서 알림)
    static let didChange = Notification.Name("SyncFolderDidChange")

    private(set) static var root: URL = localRoot
    private(set) static var isCloud = false
    private static var prepareTask: Task<Void, Never>?
    private static var query: NSMetadataQuery?
    private static var observers: [NSObjectProtocol] = []
    private static var pendingNotify: DispatchWorkItem?

    static var localRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func folder(_ name: String) -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: 준비

    /// 앱 시작 시 한 번. iCloud 컨테이너 확인은 오래 걸릴 수 있어 백그라운드에서 합니다.
    @MainActor
    static func prepare() async {
        // 여러 저장소가 동시에 불러도 한 번만 준비하고, 모두 준비가 끝날 때까지 기다림
        if let task = prepareTask { return await task.value }
        let task = Task { @MainActor in await resolveRoot() }
        prepareTask = task
        await task.value
    }

    @MainActor
    private static func resolveRoot() async {
        let cloud: URL? = await Task.detached(priority: .userInitiated) {
            guard FileManager.default.ubiquityIdentityToken != nil,
                  let container = FileManager.default.url(forUbiquityContainerIdentifier: containerID) else { return nil }
            let docs = container.appendingPathComponent("Documents", isDirectory: true)
            try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
            return docs
        }.value

        if let cloud {
            root = cloud
            isCloud = true
            await Task.detached(priority: .userInitiated) { moveLocalDataToCloud(cloud) }.value
            startWatching()
        } else {
            root = localRoot
            isCloud = false
        }
    }

    /// 기기 안에만 있던 데이터(이전 버전, iCloud 를 나중에 켠 경우)를 iCloud 폴더로 옮김
    private static func moveLocalDataToCloud(_ cloud: URL) {
        let fm = FileManager.default
        for name in ["Scores", "Progress", "PageImages", "PDF"] {
            let src = localRoot.appendingPathComponent(name, isDirectory: true)
            guard let files = try? fm.contentsOfDirectory(atPath: src.path), !files.isEmpty else { continue }
            let dst = cloud.appendingPathComponent(name, isDirectory: true)
            try? fm.createDirectory(at: dst, withIntermediateDirectories: true)
            for f in files {
                let from = src.appendingPathComponent(f), to = dst.appendingPathComponent(f)
                if fm.fileExists(atPath: to.path) {
                    try? fm.removeItem(at: from)
                } else {
                    try? fm.setUbiquitous(true, itemAt: from, destinationURL: to)
                }
            }
        }
    }

    // MARK: 다른 기기의 변경 감지

    @MainActor
    private static func startWatching() {
        let q = NSMetadataQuery()
        q.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        q.predicate = NSPredicate(format: "%K LIKE '*'", NSMetadataItemFSNameKey)
        let center = NotificationCenter.default
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(center.addObserver(forName: name, object: q, queue: .main) { _ in
                MainActor.assumeIsolated { handleQueryResults() }
            })
        }
        query = q
        q.start()
    }

    @MainActor
    private static func handleQueryResults() {
        guard let q = query else { return }
        q.disableUpdates()
        defer { q.enableUpdates() }
        for case let item as NSMetadataItem in q.results {
            guard let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL else { continue }
            let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
            if status != NSMetadataUbiquitousItemDownloadingStatusCurrent {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            }
        }
        // 한꺼번에 여러 파일이 바뀌므로 잠깐 모았다가 한 번만 알림
        pendingNotify?.cancel()
        let work = DispatchWorkItem { NotificationCenter.default.post(name: didChange, object: nil) }
        pendingNotify = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    // MARK: 파일 읽기 · 쓰기 (iCloud 와 충돌하지 않도록 조정)

    static func read(_ url: URL) -> Data? {
        var result: Data?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { u in
            result = try? Data(contentsOf: u)
        }
        return result
    }

    static func write(_ data: Data, to url: URL) {
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &error) { u in
            do { try data.write(to: u, options: .atomic) } catch { print("저장 실패 \(u.lastPathComponent): \(error)") }
        }
    }

    static func delete(_ url: URL) {
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &error) { u in
            try? FileManager.default.removeItem(at: u)
        }
    }

    /// 폴더 안의 파일 이름. 아직 내려받지 않은 iCloud 파일(.이름.icloud)은 내려받기를 시작하고 원래 이름으로 돌려줌.
    static func files(in folder: URL, ext: String) -> (ready: [URL], downloading: Int) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var ready: [URL] = []
        var downloading = 0
        for n in names {
            if n.hasPrefix("."), n.hasSuffix(".icloud") {
                let real = String(n.dropFirst().dropLast(".icloud".count))
                if real.hasSuffix("." + ext) {
                    downloading += 1
                    try? FileManager.default.startDownloadingUbiquitousItem(at: folder.appendingPathComponent(real))
                }
            } else if n.hasSuffix("." + ext) {
                ready.append(folder.appendingPathComponent(n))
            }
        }
        return (ready, downloading)
    }
}
