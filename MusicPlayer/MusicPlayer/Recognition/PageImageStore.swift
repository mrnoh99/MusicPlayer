import UIKit

/// 인식에 쓴 원본 악보 이미지를 Documents/PageImages 에 보관합니다.
/// 편집 화면에서 원본과 나란히 보며 잘못 인식된 음표·표식을 고칠 때 사용합니다.
enum PageImageStore {
    private static let cache = NSCache<NSString, UIImage>()

    /// iCloud Drive (또는 기기)의 PageImages 폴더
    private static var folder: URL { SyncFolder.folder("PageImages") }

    /// 저장하고 파일 이름을 돌려줌
    static func save(_ image: UIImage) -> String? {
        guard let data = image.resizedForUpload(maxSide: 2200).jpegData(compressionQuality: 0.8) else { return nil }
        let name = UUID().uuidString + ".jpg"
        SyncFolder.write(data, to: folder.appendingPathComponent(name))
        return name
    }

    static func load(_ name: String) -> UIImage? {
        if let cached = cache.object(forKey: name as NSString) { return cached }
        let url = folder.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            // 다른 기기에서 찍은 사진이면 iCloud 에서 내려받기 시작 (다음에 열 때 보임)
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            return nil
        }
        guard let data = SyncFolder.read(url), let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: name as NSString)
        return image
    }

    /// 어떤 악보에서도 쓰지 않는 이미지 지우기
    static func removeUnused(keeping used: Set<String>) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for f in files where !used.contains(f) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(f))
        }
    }
}
