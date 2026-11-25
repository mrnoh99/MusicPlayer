import UIKit

/// CoreGraphics 로 악보를 그립니다. 화면(Canvas)과 PDF 가 모두 이 코드를 사용합니다.
/// 호출 전 UIGraphicsPushContext(ctx) 가 되어 있어야 텍스트가 그려집니다.
struct ScoreDrawer {
    let layout: ScoreLayout
    var highlights: [UUID: UIColor] = [:]
    var ink: UIColor = .black

    private var s: CGFloat { ScoreLayout.space }
    private var score: Score { layout.score }
    private var preferFlats: Bool { score.keyFifths < 0 }

    // MARK: 줄 단위

    func drawSystem(_ system: ScoreLayout.System, in ctx: CGContext, originY: CGFloat) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: originY)
        defer { ctx.restoreGState() }

        let left = ScoreLayout.leftMargin
        let right = system.barXs.last ?? (layout.width - ScoreLayout.rightMargin)

        // 오선
        ctx.setStrokeColor(ink.cgColor)
        ctx.setLineWidth(0.8)
        for staff in Staff.allCases {
            for line in 0..<5 {
                let y = ScoreLayout.y(position: line * 2, staff: staff)
                ctx.move(to: CGPoint(x: left, y: y))
                ctx.addLine(to: CGPoint(x: right, y: y))
            }
        }
        ctx.strokePath()

        // 큰보표 왼쪽 세로줄과 괄호
        let topY = ScoreLayout.trebleTop
        let bottomY = ScoreLayout.bassTop + 4 * s
        ctx.setLineWidth(1.2)
        ctx.move(to: CGPoint(x: left, y: topY))
        ctx.addLine(to: CGPoint(x: left, y: bottomY))
        ctx.strokePath()
        drawBrace(in: ctx, x: left - 2, top: topY, bottom: bottomY)

        // 음자리표
        drawText("𝄞", size: s * 5.2, center: CGPoint(x: left + 14, y: ScoreLayout.y(position: 3, staff: .treble)))
        drawText("𝄢", size: s * 4.0, center: CGPoint(x: left + 14, y: ScoreLayout.y(position: 5, staff: .bass)))

        // 조표
        drawKeySignature(in: ctx, x: left + 32)

        // 박자표 (첫 줄)
        if system.index == 0 {
            let tx = left + system.headerWidth - 14
            for staff in Staff.allCases {
                drawText("\(score.beatsPerMeasure)", size: s * 2.4, bold: true,
                         center: CGPoint(x: tx, y: ScoreLayout.y(position: 6, staff: staff)))
                drawText("\(score.beatUnit)", size: s * 2.4, bold: true,
                         center: CGPoint(x: tx, y: ScoreLayout.y(position: 2, staff: staff)))
            }
        }

        // 하이라이트 배경
        for p in system.events {
            if let color = highlights[p.event.id] {
                let top = p.event.staff == .treble ? ScoreLayout.trebleTop - 3 * s : ScoreLayout.bassTop - 3 * s
                let rect = CGRect(x: p.x - s * 1.6, y: top, width: s * 3.2, height: 10 * s)
                ctx.setFillColor(color.withAlphaComponent(0.18).cgColor)
                ctx.addPath(UIBezierPath(roundedRect: rect, cornerRadius: 4).cgPath)
                ctx.fillPath()
            }
        }

        // 마디선
        ctx.setStrokeColor(ink.cgColor)
        ctx.setLineWidth(1)
        for (i, x) in system.barXs.enumerated() where i > 0 {
            ctx.move(to: CGPoint(x: x, y: topY))
            ctx.addLine(to: CGPoint(x: x, y: bottomY))
        }
        ctx.strokePath()
        if system.measureRange.upperBound == score.measures.count, let last = system.barXs.last {
            ctx.setFillColor(ink.cgColor)
            ctx.fill(CGRect(x: last - 3, y: topY, width: 3, height: bottomY - topY))
            ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: last - 6, y: topY))
            ctx.addLine(to: CGPoint(x: last - 6, y: bottomY))
            ctx.strokePath()
        }

        // 마디 번호
        if let first = system.measureRange.first, let x = system.barXs.first {
            drawText("\(first + 1)", size: 10, color: .gray,
                     center: CGPoint(x: x + 6, y: topY - 2.6 * s))
        }

        // 음표
        for p in system.events {
            let color = highlights[p.event.id] ?? ink
            if p.event.isRest {
                drawRest(p.event, x: p.x, in: ctx, color: color)
            } else {
                drawNote(p.event, x: p.x, in: ctx, color: color)
            }
        }
    }

    // MARK: 음표

    private func drawNote(_ e: NoteEvent, x: CGFloat, in ctx: CGContext, color: UIColor) {
        let (value, dotted) = NoteValue.decompose(e.duration)
        let info = e.pitches.sorted().map { ScoreLayout.staffPosition(midi: $0, staff: e.staff, preferFlats: preferFlats) }
        guard let low = info.first?.position, let high = info.last?.position else { return }
        let hw = s * 1.32, hh = s * 0.95

        ctx.setStrokeColor(color.cgColor)
        ctx.setFillColor(color.cgColor)

        // 덧줄
        ctx.setLineWidth(0.9)
        if low <= -2 {
            for lp in stride(from: -2, through: low, by: -2) { ledger(at: lp, x: x, hw: hw, staff: e.staff, ctx: ctx) }
        }
        if high >= 10 {
            for lp in stride(from: 10, through: high, by: 2) { ledger(at: lp, x: x, hw: hw, staff: e.staff, ctx: ctx) }
        }
        ctx.strokePath()

        // 머리 + 임시표 + 점
        for (i, n) in info.enumerated() {
            // 2도 간격 화음은 옆으로 비킴
            var nx = x
            if i > 0, n.position - info[i - 1].position == 1 { nx += hw * 0.95 }
            let y = ScoreLayout.y(position: n.position, staff: e.staff)
            let rect = CGRect(x: nx - hw / 2, y: y - hh / 2, width: hw, height: hh)
            if value.rawValue <= 1 {
                ctx.fillEllipse(in: rect)
            } else {
                ctx.setLineWidth(1.6)
                ctx.strokeEllipse(in: rect.insetBy(dx: 0.8, dy: 0.8))
            }
            if n.alter != ScoreLayout.keyAlter(step: n.step, fifths: score.keyFifths) {
                let sym = n.alter > 0 ? "♯" : (n.alter < 0 ? "♭" : "♮")
                drawText(sym, size: s * 2.0, color: color, center: CGPoint(x: x - hw * 1.3, y: y - (n.alter < 0 ? s * 0.3 : 0)))
            }
            if dotted {
                let dy: CGFloat = n.position % 2 == 0 ? -s / 2 : 0
                ctx.fillEllipse(in: CGRect(x: nx + hw / 2 + 3, y: y + dy - 1.6, width: 3.2, height: 3.2))
            }
        }

        // 기둥 + 꼬리
        guard value != .whole else { return }
        let avg = Double(low + high) / 2
        let up = avg < 4
        let stemX = up ? x + hw / 2 - 0.6 : x - hw / 2 + 0.6
        let startY = ScoreLayout.y(position: up ? low : high, staff: e.staff)
        let endY = up ? ScoreLayout.y(position: high, staff: e.staff) - 3.5 * s
                      : ScoreLayout.y(position: low, staff: e.staff) + 3.5 * s
        ctx.setLineWidth(1.1)
        ctx.move(to: CGPoint(x: stemX, y: startY))
        ctx.addLine(to: CGPoint(x: stemX, y: endY))
        ctx.strokePath()

        let flags = value == .eighth ? 1 : (value == .sixteenth ? 2 : 0)
        ctx.setLineWidth(1.8)
        for f in 0..<flags {
            let dir: CGFloat = up ? 1 : -1
            let fy = endY + dir * CGFloat(f) * s * 0.9
            ctx.move(to: CGPoint(x: stemX, y: fy))
            ctx.addQuadCurve(to: CGPoint(x: stemX + s * 1.1, y: fy + dir * s * 2.4),
                             control: CGPoint(x: stemX + s * 1.3, y: fy + dir * s * 0.9))
        }
        ctx.strokePath()
    }

    private func ledger(at position: Int, x: CGFloat, hw: CGFloat, staff: Staff, ctx: CGContext) {
        let y = ScoreLayout.y(position: position, staff: staff)
        ctx.move(to: CGPoint(x: x - hw * 0.9, y: y))
        ctx.addLine(to: CGPoint(x: x + hw * 0.9, y: y))
    }

    // MARK: 쉼표

    private func drawRest(_ e: NoteEvent, x: CGFloat, in ctx: CGContext, color: UIColor) {
        let (value, dotted) = NoteValue.decompose(e.duration)
        let st = e.staff
        let y = { (p: Double) -> CGFloat in ScoreLayout.y(position: p, staff: st) }
        ctx.setFillColor(color.cgColor)
        ctx.setStrokeColor(color.cgColor)
        switch value {
        case .whole:
            ctx.fill(CGRect(x: x - s * 0.7, y: y(6), width: s * 1.4, height: s * 0.55))
        case .half:
            ctx.fill(CGRect(x: x - s * 0.7, y: y(4) - s * 0.55, width: s * 1.4, height: s * 0.55))
        case .quarter:
            ctx.setLineWidth(2)
            ctx.setLineJoin(.round)
            ctx.move(to: CGPoint(x: x - s * 0.3, y: y(7)))
            ctx.addLine(to: CGPoint(x: x + s * 0.4, y: y(5.5)))
            ctx.addLine(to: CGPoint(x: x - s * 0.4, y: y(4)))
            ctx.addLine(to: CGPoint(x: x + s * 0.4, y: y(2.5)))
            ctx.addQuadCurve(to: CGPoint(x: x, y: y(1)), control: CGPoint(x: x - s * 0.7, y: y(2)))
            ctx.strokePath()
        case .eighth, .sixteenth:
            let count = value == .eighth ? 1 : 2
            ctx.setLineWidth(1.3)
            ctx.move(to: CGPoint(x: x + s * 0.5, y: y(5)))
            ctx.addLine(to: CGPoint(x: x - s * 0.2, y: y(count == 1 ? 1 : 0)))
            ctx.strokePath()
            for i in 0..<count {
                let cy = y(5) + CGFloat(i) * s
                ctx.fillEllipse(in: CGRect(x: x - s * 0.55, y: cy - s * 0.35, width: s * 0.7, height: s * 0.7))
            }
        }
        if dotted {
            ctx.fillEllipse(in: CGRect(x: x + s, y: y(5) - 1.6, width: 3.2, height: 3.2))
        }
    }

    // MARK: 조표 / 괄호

    private func drawKeySignature(in ctx: CGContext, x: CGFloat) {
        let count = min(abs(score.keyFifths), 7)
        guard count > 0 else { return }
        let sharpPos = [8, 5, 9, 6, 3, 7, 4]
        let flatPos  = [4, 7, 3, 6, 2, 5, 1]
        let sharp = score.keyFifths > 0
        for staff in Staff.allCases {
            for i in 0..<count {
                let p = (sharp ? sharpPos[i] : flatPos[i]) - (staff == .bass ? 2 : 0)
                let y = ScoreLayout.y(position: p, staff: staff)
                drawText(sharp ? "♯" : "♭", size: s * 2.0,
                         center: CGPoint(x: x + CGFloat(i) * 8, y: y - (sharp ? 0 : s * 0.3)))
            }
        }
    }

    private func drawBrace(in ctx: CGContext, x: CGFloat, top: CGFloat, bottom: CGFloat) {
        let mid = (top + bottom) / 2
        let w: CGFloat = 6
        let path = UIBezierPath()
        path.move(to: CGPoint(x: x, y: top))
        path.addCurve(to: CGPoint(x: x - w, y: mid), controlPoint1: CGPoint(x: x - w * 1.4, y: top + 10),
                      controlPoint2: CGPoint(x: x + 1, y: mid - 12))
        path.addCurve(to: CGPoint(x: x, y: bottom), controlPoint1: CGPoint(x: x + 1, y: mid + 12),
                      controlPoint2: CGPoint(x: x - w * 1.4, y: bottom - 10))
        ctx.setLineWidth(1.6)
        ctx.addPath(path.cgPath)
        ctx.strokePath()
    }

    // MARK: 텍스트

    func drawText(_ text: String, size: CGFloat, bold: Bool = false, color: UIColor? = nil, center: CGPoint) {
        let font = bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color ?? ink]
        let str = NSAttributedString(string: text, attributes: attrs)
        let sz = str.size()
        str.draw(at: CGPoint(x: center.x - sz.width / 2, y: center.y - sz.height / 2))
    }

    func drawHeader(in ctx: CGContext, width: CGFloat) {
        let title = NSAttributedString(string: score.title, attributes: [
            .font: UIFont.boldSystemFont(ofSize: 22), .foregroundColor: ink])
        let ts = title.size()
        title.draw(at: CGPoint(x: (width - ts.width) / 2, y: 0))
        if !score.composer.isEmpty {
            let c = NSAttributedString(string: score.composer, attributes: [
                .font: UIFont.systemFont(ofSize: 12), .foregroundColor: ink])
            c.draw(at: CGPoint(x: width - c.size().width - ScoreLayout.rightMargin, y: ts.height + 4))
        }
        let tempo = NSAttributedString(string: "♩ = \(score.tempo)", attributes: [
            .font: UIFont.systemFont(ofSize: 12), .foregroundColor: ink])
        tempo.draw(at: CGPoint(x: ScoreLayout.leftMargin, y: ts.height + 4))
    }

    static let headerHeight: CGFloat = 56
}

private extension ScoreLayout {
    static func y(position: Double, staff: Staff) -> CGFloat {
        let top = staff == .treble ? trebleTop : bassTop
        return top + 4 * space - CGFloat(position) * space / 2
    }
}
