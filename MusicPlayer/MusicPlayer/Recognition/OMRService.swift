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
        case .truncated: return "악보가 너무 길어 응답이 잘렸습니다. 페이지를 나눠서 인식해 보세요."
        case .badResponse(let msg): return "응답을 해석하지 못했습니다: \(msg)"
        }
    }
}

struct OMRService {
    static let model = "claude-opus-5-5"
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    var apiKey: String

    /// 인식 진행 단계 (화면 표시용)
    enum Stage: String {
        case preparing = "사진을 다듬는 중"
        case reading = "AI가 악보를 읽는 중"
        case verifying = "AI가 원본과 대조해 검토하는 중"
    }

    /// 악보 이미지 → Score.
    /// verify 가 true 면 AI 가 첫 결과를 원본과 마디마다 다시 대조해 고칩니다 (더 정확, 시간·비용 약 2배).
    func recognize(images: [UIImage], titleHint: String?, verify: Bool = true,
                   progress: @escaping @Sendable (Stage) -> Void = { _ in }) async throws -> Score {
        guard !apiKey.isEmpty else { throw OMRError.missingAPIKey }
        guard !images.isEmpty else { throw OMRError.noImages }

        progress(.preparing)
        // 기울어진 사진은 펴고, 그림자·색을 줄여 대비를 높임
        let pages = images.map { ImagePreprocessor.prepare($0) }
        let imageBlocks = Self.imageContent(pages)

        progress(.reading)
        var instruction = "Transcribe all \(pages.count) page(s) above, in order, into the JSON format."
        if let hint = titleHint, !hint.isEmpty { instruction += " The user calls this piece \"\(hint)\"." }
        let firstData = try await send(system: Self.systemPrompt, schema: Self.schema,
                                       content: imageBlocks + [["type": "text", "text": instruction]])
        var result = try decode(OMRResult.self, from: firstData)

        if verify {
            try Task.checkCancellation()
            progress(.verifying)
            let draft = String(data: firstData, encoding: .utf8) ?? ""
            var review = """
            Below is a first-pass transcription of the pages above. Proofread it against the images, \
            measure by measure and staff by staff: wrong pitches (check clefs, ledger lines, key signature and \
            accidentals), wrong durations or dots, missing or extra notes, rests, chords, ties, articulations, \
            dynamics, repeat barlines, page numbers, and missing or extra measures. \
            Return the complete corrected transcription in the same JSON format.
            """
            let problems = result.rhythmProblems()
            if !problems.isEmpty {
                review += "\nThese measures do not add up to the time signature and need a closer look: "
                    + problems.joined(separator: "; ") + "."
            }
            review += "\n\nFirst-pass transcription:\n" + draft
            if let checked = try? await send(system: Self.systemPrompt, schema: Self.schema,
                                             content: imageBlocks + [["type": "text", "text": review]]),
               let corrected = try? decode(OMRResult.self, from: checked),
               !corrected.measures.isEmpty {
                result = corrected
            }
        }

        // 원본 이미지를 보관해 두면 편집할 때 나란히 보며 고칠 수 있음
        let names: [String?] = pages.map { PageImageStore.save($0) }
        return result.toScore(fallbackTitle: titleHint, pageImages: names)
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
                                  maxTokens: 8000)
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
                      maxTokens: Int = 32000) async throws -> Data {
        let body: [String: Any] = [
            "model": Self.model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": content]],
            "output_config": [
                "effort": "high",
                "format": ["type": "json_schema", "schema": schema],
            ],
            // 안전 분류기로 거절될 경우 서버가 자동으로 다른 모델로 재시도
            "fallbacks": "default",
        ]

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 900
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

        guard (200..<300).contains(status) else {
            let message = (json["error"] as? [String: Any])?["message"] as? String
                ?? String(data: data, encoding: .utf8) ?? ""
            throw OMRError.http(status, message)
        }

        let stopReason = json["stop_reason"] as? String
        if stopReason == "refusal" {
            let detail = (json["stop_details"] as? [String: Any])?["explanation"] as? String ?? ""
            throw OMRError.refused(detail)
        }
        if stopReason == "max_tokens" { throw OMRError.truncated }

        let blocks = json["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
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

private struct OMRResult: Decodable {
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

    let title: String
    let composer: String
    let tempo: Int
    let beatsPerMeasure: Int
    let beatUnit: Int
    let keyFifths: Int
    let measures: [OMRMeasure]

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
    let page: Int?
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
