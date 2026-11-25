import Foundation
import UIKit

/// 악보 이미지 → Score 변환 (Claude 비전 API 사용, 구조화 출력으로 JSON 보장)
enum OMRError: LocalizedError {
    case missingAPIKey
    case noImages
    case http(Int, String)
    case refused(String)
    case truncated
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "설정에서 Anthropic API 키를 먼저 입력하세요."
        case .noImages: return "인식할 이미지가 없습니다."
        case .http(let code, let msg): return "서버 오류 (\(code)): \(msg)"
        case .refused(let msg): return "요청이 거절되었습니다. \(msg)"
        case .truncated: return "한 페이지의 악보가 너무 길어 응답이 잘렸습니다. 그 페이지를 위·아래 반씩 잘라 찍어서 다시 시도해 보세요."
        case .badResponse(let msg): return "응답을 해석하지 못했습니다: \(msg)"
        }
    }
}

struct OMRService {
    static let model = "claude-opus-5-5"
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    var apiKey: String

    /// 인식 진행 상황 (화면 표시용)
    struct Progress: Sendable {
        enum Stage: String, Sendable {
            case preparing = "사진을 다듬는 중"
            case reading = "AI가 악보를 읽는 중"
            case verifying = "AI가 원본과 대조해 검토하는 중"
        }
        var stage: Stage
        var done = 0
        var total = 0
    }

    /// 속도와 정확도 사이의 선택
    enum Mode: String, CaseIterable, Identifiable, Sendable {
        case fast, balanced, precise
        var id: String { rawValue }
        var label: String {
            switch self {
            case .fast: return "빠르게"
            case .balanced: return "보통"
            case .precise: return "정밀하게"
            }
        }
        var detail: String {
            switch self {
            case .fast: return "가장 빠릅니다. 단순한 악보에 알맞고, 복잡한 악보는 틀린 곳이 늘 수 있어요."
            case .balanced: return "속도와 정확도의 균형. 대부분의 악보에 알맞습니다."
            case .precise: return "AI가 한 번 더 원본과 대조해 고칩니다. 가장 정확하지만 시간·비용이 약 2배입니다."
            }
        }
        var effort: String {
            switch self {
            case .fast: return "low"
            case .balanced: return "medium"
            case .precise: return "high"
            }
        }
        var verify: Bool { self == .precise }
    }

    /// 한 번에 동시에 보낼 페이지 수
    private static let maxParallelPages = 4

    /// 악보 이미지 → Score.
    /// 페이지마다 따로, 동시에 요청해서 여러 쪽짜리 악보도 한 쪽을 읽는 시간 정도에 끝납니다.
    /// fastSpeed: Claude 고속 처리(fast mode) — 출력이 최대 2.5배 빠르지만 요금이 2배.
    func recognize(images: [UIImage], titleHint: String?, mode: Mode = .balanced, fastSpeed: Bool = false,
                   progress: @escaping @Sendable (Progress) -> Void = { _ in }) async throws -> Score {
        guard !apiKey.isEmpty else { throw OMRError.missingAPIKey }
        guard !images.isEmpty else { throw OMRError.noImages }

        progress(Progress(stage: .preparing))
        // 기울어진 사진은 펴고, 그림자·색을 줄여 대비를 높임 (여러 장을 동시에)
        let pages = await withTaskGroup(of: (Int, UIImage).self) { group in
            for (i, image) in images.enumerated() {
                group.addTask { (i, ImagePreprocessor.prepare(image)) }
            }
            var result = [UIImage?](repeating: nil, count: images.count)
            for await (i, img) in group { result[i] = img }
            return result.enumerated().map { $0.element ?? images[$0.offset] }
        }

        let total = pages.count * (mode.verify ? 2 : 1)
        let counter = ProgressCounter(total: total, report: progress)
        counter.start(.reading)

        // 페이지별로 동시에 읽기 (+ 정밀 모드면 그 페이지를 바로 검토)
        let work: @Sendable (Int) async throws -> (Int, OMRResult) = { index in
            try await self.readPage(pages[index], number: index + 1, of: pages.count,
                                    titleHint: titleHint, mode: mode, fastSpeed: fastSpeed, counter: counter)
        }
        let results: [OMRResult] = try await withThrowingTaskGroup(of: (Int, OMRResult).self) { group in
            var next = 0
            while next < min(Self.maxParallelPages, pages.count) {
                let index = next
                group.addTask { try await work(index) }
                next += 1
            }
            var out = [OMRResult?](repeating: nil, count: pages.count)
            while let item = try await group.next() {
                out[item.0] = item.1
                if next < pages.count {
                    let index = next
                    group.addTask { try await work(index) }
                    next += 1
                }
            }
            return out.compactMap { $0 }
        }

        // 페이지 결과 이어 붙이기 (제목·박자·조표는 첫 페이지 기준)
        guard var merged = results.first else { throw OMRError.badResponse("결과가 없습니다") }
        merged.measures = []
        for (k, r) in results.enumerated() {
            if merged.title.isEmpty { merged.title = r.title }
            if merged.composer.isEmpty { merged.composer = r.composer }
            merged.measures += r.measures.map { m in var c = m; c.page = k + 1; return c }
        }

        // 원본 이미지를 보관해 두면 편집할 때 나란히 보며 고칠 수 있음
        let names: [String?] = pages.map { PageImageStore.save($0) }
        return merged.toScore(fallbackTitle: titleHint, pageImages: names)
    }

    /// 한 페이지 읽기 (+ 정밀 모드면 검토)
    private func readPage(_ page: UIImage, number: Int, of count: Int, titleHint: String?,
                          mode: Mode, fastSpeed: Bool, counter: ProgressCounter) async throws -> (Int, OMRResult) {
        let image = Self.imageContent([page])
        var instruction = "Transcribe this page into the JSON format. Use page 1 for every measure."
        if count > 1 {
            instruction += " It is page \(number) of \(count) of the piece"
            instruction += number > 1 ? "; if the title, tempo, time or key signature are not printed on this page, give your best guess from the music and use an empty title." : "."
        }
        if let hint = titleHint, !hint.isEmpty { instruction += " The user calls this piece \"\(hint)\"." }

        let firstData = try await send(system: Self.systemPrompt, schema: Self.schema,
                                       content: image + [["type": "text", "text": instruction]],
                                       effort: mode.effort, fastSpeed: fastSpeed)
        var result = try decode(OMRResult.self, from: firstData)
        counter.step(mode.verify ? .verifying : .reading)

        if mode.verify {
            try Task.checkCancellation()
            var review = """
            Below is a first-pass transcription of the page above. Proofread it against the image, \
            measure by measure and staff by staff: wrong pitches (check clefs, ledger lines, key signature and \
            accidentals), wrong durations or dots, missing or extra notes, rests, chords, ties, articulations, \
            dynamics, repeat barlines, and missing or extra measures. \
            Return the complete corrected transcription in the same JSON format.
            """
            let problems = result.rhythmProblems()
            if !problems.isEmpty {
                review += "\nThese measures do not add up to the time signature and need a closer look: "
                    + problems.joined(separator: "; ") + "."
            }
            review += "\n\nFirst-pass transcription:\n" + (String(data: firstData, encoding: .utf8) ?? "")
            if let checked = try? await send(system: Self.systemPrompt, schema: Self.schema,
                                             content: image + [["type": "text", "text": review]],
                                             effort: "high", fastSpeed: fastSpeed),
               let corrected = try? decode(OMRResult.self, from: checked),
               !corrected.measures.isEmpty {
                result = corrected
            }
            counter.step(.verifying)
        }
        return (number - 1, result)
    }

    /// 편집 중 한 마디만 AI 로 다시 읽기. 원본 페이지 이미지와 앞뒤 마디를 단서로 줍니다.
    func rereadMeasure(score: Score, measureIndex mi: Int, pageImage: UIImage) async throws -> Measure {
        guard !apiKey.isEmpty else { throw OMRError.missingAPIKey }
        let page = score.pages[score.pageIndex(ofMeasure: mi)]
        let localNumber = mi - page.measureRange.lowerBound + 1

        func describe(_ index: Int) -> String {
            guard score.measures.indices.contains(index) else { return "(none)" }
            return OMRMeasure.json(from: score.measures[index])
        }
        let keyText = score.keyFifths == 0 ? "no sharps or flats"
            : "\(abs(score.keyFifths)) \(score.keyFifths > 0 ? "sharp(s)" : "flat(s)")"
        let prompt = """
        This page of sheet music is in \(score.beatsPerMeasure)/\(score.beatUnit) time with \(keyText) in the key signature.
        Re-read measure number \(localNumber) counted from the first measure at the top-left of this page \
        (count every measure, including a pickup measure). Use the neighbouring measures to make sure you have \
        the right one.
        Previous measure as currently transcribed: \(describe(mi - 1))
        This measure as currently transcribed (it probably contains mistakes): \(describe(mi))
        Next measure as currently transcribed: \(describe(mi + 1))
        Return only that one measure, transcribed carefully, in the JSON format. Use page 1.
        """
        let data = try await send(system: Self.systemPrompt, schema: Self.measureSchema,
                                  content: Self.imageContent([ImagePreprocessor.prepare(pageImage)])
                                      + [["type": "text", "text": prompt]],
                                  maxTokens: 8000, effort: "high")
        let m = try decode(OMRMeasure.self, from: data)
        var measure = score.measures[mi]
        measure.events = m.events(measureLength: score.measureLength)
        measure.repeatStart = m.repeatStart == true ? true : nil
        measure.repeatEnd = m.repeatEnd == true ? true : nil
        return measure
    }

    // MARK: 요청

    private static func imageContent(_ images: [UIImage]) -> [[String: Any]] {
        var content: [[String: Any]] = []
        for (i, image) in images.enumerated() {
            guard let jpeg = image.resizedForUpload().jpegData(compressionQuality: 0.85) else { continue }
            content.append(["type": "text", "text": "Page \(i + 1):"])
            content.append([
                "type": "image",
                "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()],
            ])
        }
        return content
    }

    /// Messages API 호출 → 구조화 출력(JSON) 텍스트
    private func send(system: String, schema: [String: Any], content: [[String: Any]],
                      maxTokens: Int = 64000, effort: String = "medium", fastSpeed: Bool = false) async throws -> Data {
        do {
            return try await sendOnce(system: system, schema: schema, content: content,
                                      maxTokens: maxTokens, effort: effort, fastSpeed: fastSpeed)
        } catch OMRError.http(let code, _) where fastSpeed && code == 429 {
            // 고속 처리 한도에 걸리면 보통 속도로 다시
            return try await sendOnce(system: system, schema: schema, content: content,
                                      maxTokens: maxTokens, effort: effort, fastSpeed: false)
        }
    }

    private func sendOnce(system: String, schema: [String: Any], content: [[String: Any]],
                          maxTokens: Int, effort: String, fastSpeed: Bool) async throws -> Data {
        var body: [String: Any] = [
            "model": Self.model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": content]],
            "output_config": [
                "effort": effort,
                "format": ["type": "json_schema", "schema": schema],
            ],
            // 안전 분류기로 거절될 경우 서버가 자동으로 다른 모델로 재시도
            "fallbacks": "default",
        ]
        if fastSpeed { body["speed"] = "fast" }

        // 긴 응답도 끊기지 않도록 스트리밍으로 받음
        body["stream"] = true

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300   // 데이터가 이만큼 오지 않으면 실패 (스트리밍이라 전체 시간 제한은 아님)
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            var data = Data()
            for try await b in bytes { data.append(b) }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let message = (json["error"] as? [String: Any])?["message"] as? String
                ?? String(data: data, encoding: .utf8) ?? ""
            throw OMRError.http(status, message)
        }

        // SSE: "data: {...}" 줄마다 이벤트 하나. 글자(text_delta)만 모으고 생각(thinking) 등은 건너뜀.
        var text = ""
        var stopReason: String?
        var stopDetails: [String: Any]?
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                  let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            switch event["type"] as? String {
            case "content_block_delta":
                if let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                   let t = delta["text"] as? String {
                    text += t
                }
            case "message_delta":
                if let delta = event["delta"] as? [String: Any] {
                    if let r = delta["stop_reason"] as? String { stopReason = r }
                    if let d = delta["stop_details"] as? [String: Any] { stopDetails = d }
                }
            case "error":
                let message = (event["error"] as? [String: Any])?["message"] as? String ?? "알 수 없는 오류"
                throw OMRError.http(529, message)
            default:
                break
            }
        }

        if stopReason == "refusal" {
            throw OMRError.refused(stopDetails?["explanation"] as? String ?? "")
        }
        if stopReason == "max_tokens" { throw OMRError.truncated }
        guard !text.isEmpty, let textData = text.data(using: .utf8) else { throw OMRError.badResponse("빈 응답") }
        return textData
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw OMRError.badResponse(error.localizedDescription)
        }
    }

    // MARK: 프롬프트 / 스키마

    static let systemPrompt = """
    You are an expert music engraver doing optical music recognition (OMR). You receive photos or scans \
    of sheet music (usually piano, possibly a single melody line) and return the music as JSON.

    Rules:
    - Output one entry in "measures" per measure, in playing order across all pages and systems. \
    Do not expand repeats; transcribe measures as written.
    - "treble" holds the upper staff (right hand), "bass" the lower staff (left hand). For a single-staff \
    melody put it in "treble" (or "bass" if it uses a bass clef) and give the other staff one whole-measure rest.
    - Each event is a note, a chord (several simultaneous notes) or a rest (empty "notes" array).
    - Write every pitch as the actual sounding pitch in scientific notation with the key signature and \
    accidentals already applied, e.g. "C4" (middle C), "F#4", "Bb3". Accidentals last until the barline.
    - Read clefs carefully, including clef changes and ledger lines. Octave marks (8va) must be applied.
    - "duration" is the written value: whole, half, quarter, eighth or 16th, with "dotted" for a dot. \
    Tied notes: keep the first note's value and continue with the next measure normally.
    - The durations on each staff of a measure must add up to the time signature. When a staff has \
    several voices, merge notes that start together into one chord and keep the main rhythm. \
    Approximate tuplets so the measure still adds up. A pickup (anacrusis) measure may be shorter.
    - keyFifths: number of sharps (positive) or flats (negative) in the key signature.
    - tempo: quarter-note BPM if marked, otherwise a sensible value for the tempo word, or 90.
    - title / composer: as printed, or empty strings.
    - "page": the number of the image (1, 2, …) on which the measure is printed.
    - "marks" per event: staccato, accent, tenuto, fermata, and "tie" when the note is tied to the next     note on the same staff. Use an empty array when there are none.
    - "dynamic" per event: the dynamic marking (pp, p, mp, mf, f, ff) that starts at this event, otherwise "".
    - "repeatStart" / "repeatEnd": true when the measure begins / ends with a repeat barline.
    """

    static var measureSchema: [String: Any] {
        let event: [String: Any] = [
            "type": "object",
            "properties": [
                "notes": ["type": "array", "items": ["type": "string"]],
                "duration": ["type": "string", "enum": ["whole", "half", "quarter", "eighth", "16th"]],
                "dotted": ["type": "boolean"],
                "marks": ["type": "array", "items": ["type": "string",
                          "enum": ["staccato", "accent", "tenuto", "fermata", "tie"]]],
                "dynamic": ["type": "string", "enum": ["", "pp", "p", "mp", "mf", "f", "ff"]],
            ],
            "required": ["notes", "duration", "dotted", "marks", "dynamic"],
            "additionalProperties": false,
        ]
        let measure: [String: Any] = [
            "type": "object",
            "properties": [
                "treble": ["type": "array", "items": event],
                "bass": ["type": "array", "items": event],
                "page": ["type": "integer"],
                "repeatStart": ["type": "boolean"],
                "repeatEnd": ["type": "boolean"],
            ],
            "required": ["treble", "bass", "page", "repeatStart", "repeatEnd"],
            "additionalProperties": false,
        ]
        return measure
    }

    static var schema: [String: Any] {
        let measure = measureSchema
        return [
            "type": "object",
            "properties": [
                "title": ["type": "string"],
                "composer": ["type": "string"],
                "tempo": ["type": "integer"],
                "beatsPerMeasure": ["type": "integer"],
                "beatUnit": ["type": "integer"],
                "keyFifths": ["type": "integer"],
                "measures": ["type": "array", "items": measure],
            ],
            "required": ["title", "composer", "tempo", "beatsPerMeasure", "beatUnit", "keyFifths", "measures"],
            "additionalProperties": false,
        ]
    }
}

// MARK: - 응답 형식

/// 여러 페이지를 동시에 처리할 때 진행 상황 세기
private final class ProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var done = 0
    private let total: Int
    private let report: @Sendable (OMRService.Progress) -> Void

    init(total: Int, report: @escaping @Sendable (OMRService.Progress) -> Void) {
        self.total = total
        self.report = report
    }

    func start(_ stage: OMRService.Progress.Stage) {
        report(OMRService.Progress(stage: stage, done: 0, total: total))
    }

    func step(_ stage: OMRService.Progress.Stage) {
        lock.lock()
        done += 1
        let d = done
        lock.unlock()
        report(OMRService.Progress(stage: stage, done: d, total: total))
    }
}

private struct OMRResult: Decodable {
    var title: String
    var composer: String
    var measures: [OMRMeasure]
    /// 박자 합이 맞지 않는 마디 (검토 단계에 단서로 전달). 첫 마디는 못갖춘마디일 수 있어 제외.
    func rhythmProblems() -> [String] {
        let unit = 4.0 / Double([2, 4, 8].contains(beatUnit) ? beatUnit : 4)
        let expected = Double(min(12, max(1, beatsPerMeasure))) * unit
        var problems: [String] = []
        for (i, m) in measures.enumerated() where i > 0 {
            for (name, list) in [("treble", m.treble), ("bass", m.bass)] where !list.isEmpty {
                let total = list.reduce(0.0) { $0 + $1.beats }
                if abs(total - expected) > 0.01 {
                    problems.append("measure \(i + 1) \(name) has \(total) beats")
                }
            }
        }
        return Array(problems.prefix(30))
    }

    let tempo: Int
    let beatsPerMeasure: Int
    let beatUnit: Int
    let keyFifths: Int

    /// pageImages: 페이지(이미지) 순서대로 저장한 원본 이미지 파일 이름
    func toScore(fallbackTitle: String?, pageImages: [String?] = []) -> Score {
        var score = Score(title: title.isEmpty ? (fallbackTitle?.isEmpty == false ? fallbackTitle! : "인식한 악보") : title,
                          composer: composer,
                          tempo: min(240, max(30, tempo)),
                          beatsPerMeasure: min(12, max(1, beatsPerMeasure)),
                          beatUnit: [2, 4, 8].contains(beatUnit) ? beatUnit : 4,
                          keyFifths: min(7, max(-7, keyFifths)),
                          measures: [])
        let length = score.measureLength
        var lastPage = 0
        score.measures = measures.enumerated().map { i, m in
            var measure = Measure(events: m.events(measureLength: length))
            measure.repeatStart = m.repeatStart == true ? true : nil
            measure.repeatEnd = m.repeatEnd == true ? true : nil
            // 이미지(페이지)가 바뀌는 마디에서 새 페이지 시작
            let page = max(1, m.page ?? max(lastPage, 1))
            if i == 0 || page > lastPage {
                if i > 0 { measure.pageStart = true }
                if pageImages.indices.contains(page - 1) { measure.pageImage = pageImages[page - 1] }
                lastPage = max(page, 1)
            }
            return measure
        }
        if score.measures.isEmpty { score.measures = [score.emptyMeasure()] }
        if score.measures[0].pageImage == nil, let first = pageImages.first ?? nil { score.measures[0].pageImage = first }
        return score
    }
}

private struct OMRMeasure: Decodable {
    let treble: [OMREvent]
    let bass: [OMREvent]
    var page: Int?
    let repeatStart: Bool?
    let repeatEnd: Bool?

    func events(measureLength: Double) -> [NoteEvent] {
        var events: [NoteEvent] = []
        for (staff, list) in [(Staff.treble, treble), (Staff.bass, bass)] {
            let converted = list.map { $0.toEvent(staff: staff) }
            events += converted.isEmpty ? [NoteEvent.rest(measureLength, staff: staff)] : converted
        }
        return events
    }

    /// 앱의 마디를 AI 에게 보여 줄 JSON 으로
    static func json(from m: Measure) -> String {
        func staff(_ s: Staff) -> [[String: Any]] {
            m.events(on: s).map { e in
                let (v, dotted) = NoteValue.decompose(e.duration)
                let name: String
                switch v {
                case .whole: name = "whole"
                case .half: name = "half"
                case .quarter: name = "quarter"
                case .eighth: name = "eighth"
                case .sixteenth: name = "16th"
                }
                return ["notes": e.pitches.sorted().map { NoteName.name($0) }, "duration": name, "dotted": dotted,
                        "marks": (e.marks ?? []).map(\.rawValue), "dynamic": e.dynamic?.rawValue ?? ""]
            }
        }
        let obj: [String: Any] = ["treble": staff(.treble), "bass": staff(.bass)]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

private struct OMREvent: Decodable {
    let notes: [String]
    let duration: String
    let dotted: Bool
    let marks: [String]?
    let dynamic: String?

    /// 4분음표 = 1 박 기준 길이
    var beats: Double {
        let base: Double
        switch duration {
        case "whole": base = 4
        case "half": base = 2
        case "eighth": base = 0.5
        case "16th": base = 0.25
        default: base = 1
        }
        return base * (dotted ? 1.5 : 1)
    }

    func toEvent(staff: Staff) -> NoteEvent {
        let base: Double
        switch duration {
        case "whole": base = 4
        case "half": base = 2
        case "eighth": base = 0.5
        case "16th": base = 0.25
        default: base = 1
        }
        let pitches = Array(Set(notes.compactMap(NoteName.midi(from:)).filter { (21...108).contains($0) })).sorted()
        var event = NoteEvent(pitches: pitches, duration: base * (dotted ? 1.5 : 1), staff: staff)
        let parsed = Array(Set((marks ?? []).compactMap(NoteMark.init(rawValue:))))
        event.marks = parsed.isEmpty ? nil : parsed.sorted { $0.rawValue < $1.rawValue }
        event.dynamic = dynamic.flatMap(Dynamic.init(rawValue:))
        return event
    }
}

// MARK: - 이미지 크기 조정

extension UIImage {
    /// 긴 변 2000px 이하로 축소
    func resizedForUpload(maxSide: CGFloat = 2000) -> UIImage {
        let w = size.width * scale, h = size.height * scale
        let longest = max(w, h)
        guard longest > maxSide else { return self }
        let ratio = maxSide / longest
        let target = CGSize(width: (w * ratio).rounded(), height: (h * ratio).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
