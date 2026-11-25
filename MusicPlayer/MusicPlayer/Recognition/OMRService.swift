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

    func recognize(images: [UIImage], titleHint: String?) async throws -> Score {
        guard !apiKey.isEmpty else { throw OMRError.missingAPIKey }
        guard !images.isEmpty else { throw OMRError.noImages }

        var content: [[String: Any]] = []
        for (i, image) in images.enumerated() {
            guard let jpeg = image.resizedForUpload().jpegData(compressionQuality: 0.85) else { continue }
            content.append(["type": "text", "text": "Page \(i + 1):"])
            content.append([
                "type": "image",
                "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()],
            ])
        }
        var instruction = "Transcribe all \(images.count) page(s) above, in order, into the JSON format."
        if let hint = titleHint, !hint.isEmpty { instruction += " The user calls this piece \"\(hint)\"." }
        content.append(["type": "text", "text": instruction])

        let body: [String: Any] = [
            "model": Self.model,
            "max_tokens": 32000,
            "system": Self.systemPrompt,
            "messages": [["role": "user", "content": content]],
            "output_config": [
                "effort": "high",
                "format": ["type": "json_schema", "schema": Self.schema],
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
        guard let textData = text.data(using: .utf8) else { throw OMRError.badResponse("빈 응답") }

        do {
            let result = try JSONDecoder().decode(OMRResult.self, from: textData)
            return result.toScore(fallbackTitle: titleHint)
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
    """

    static var schema: [String: Any] {
        let event: [String: Any] = [
            "type": "object",
            "properties": [
                "notes": ["type": "array", "items": ["type": "string"]],
                "duration": ["type": "string", "enum": ["whole", "half", "quarter", "eighth", "16th"]],
                "dotted": ["type": "boolean"],
            ],
            "required": ["notes", "duration", "dotted"],
            "additionalProperties": false,
        ]
        let measure: [String: Any] = [
            "type": "object",
            "properties": [
                "treble": ["type": "array", "items": event],
                "bass": ["type": "array", "items": event],
            ],
            "required": ["treble", "bass"],
            "additionalProperties": false,
        ]
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
    let title: String
    let composer: String
    let tempo: Int
    let beatsPerMeasure: Int
    let beatUnit: Int
    let keyFifths: Int
    let measures: [OMRMeasure]

    func toScore(fallbackTitle: String?) -> Score {
        var score = Score(title: title.isEmpty ? (fallbackTitle?.isEmpty == false ? fallbackTitle! : "인식한 악보") : title,
                          composer: composer,
                          tempo: min(240, max(30, tempo)),
                          beatsPerMeasure: min(12, max(1, beatsPerMeasure)),
                          beatUnit: [2, 4, 8].contains(beatUnit) ? beatUnit : 4,
                          keyFifths: min(7, max(-7, keyFifths)),
                          measures: [])
        let length = score.measureLength
        score.measures = measures.map { m in
            var events: [NoteEvent] = []
            for (staff, list) in [(Staff.treble, m.treble), (Staff.bass, m.bass)] {
                let converted = list.map { $0.toEvent(staff: staff) }
                events += converted.isEmpty ? [NoteEvent.rest(length, staff: staff)] : converted
            }
            return Measure(events: events)
        }
        if score.measures.isEmpty { score.measures = [score.emptyMeasure()] }
        return score
    }
}

private struct OMRMeasure: Decodable {
    let treble: [OMREvent]
    let bass: [OMREvent]
}

private struct OMREvent: Decodable {
    let notes: [String]
    let duration: String
    let dotted: Bool

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
        return NoteEvent(pitches: pitches, duration: base * (dotted ? 1.5 : 1), staff: staff)
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
