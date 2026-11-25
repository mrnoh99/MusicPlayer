import UIKit

/// 악보를 A4 PDF 로 내보냅니다.
enum PDFExporter {
    static func export(_ score: Score) throws -> URL {
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)   // A4 (pt)
        let margin: CGFloat = 36
        let contentWidth = page.width - margin * 2
        let layout = ScoreLayout(score: score, width: contentWidth)
        let drawer = ScoreDrawer(layout: layout)

        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: score.title,
            kCGPDFContextCreator as String: "악보 플레이어",
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: page, format: format)

        let safeName = score.title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent((safeName.isEmpty ? "score" : safeName) + ".pdf")

        try renderer.writePDF(to: url) { ctx in
            let cg = ctx.cgContext
            var y = CGFloat.greatestFiniteMagnitude
            var pageNumber = 0

            func newPage() {
                ctx.beginPage()
                pageNumber += 1
                y = margin
                if pageNumber == 1 {
                    cg.saveGState()
                    cg.translateBy(x: margin, y: margin)
                    drawer.drawHeader(in: cg, width: contentWidth)
                    cg.restoreGState()
                    y += ScoreDrawer.headerHeight
                }
                let footer = NSAttributedString(string: "\(pageNumber)", attributes: [
                    .font: UIFont.systemFont(ofSize: 10), .foregroundColor: UIColor.gray])
                footer.draw(at: CGPoint(x: (page.width - footer.size().width) / 2, y: page.height - margin + 10))
            }

            for system in layout.systems {
                // 책의 새 페이지는 PDF 에서도 새 쪽에서 시작
                let bookPageBreak = system.index > 0 && system.startsPage != nil
                if bookPageBreak || y + ScoreLayout.systemHeight > page.height - margin {
                    newPage()
                }
                cg.saveGState()
                cg.translateBy(x: margin, y: 0)
                drawer.drawSystem(system, in: cg, originY: y)
                cg.restoreGState()
                y += ScoreLayout.systemHeight
            }
        }
        return url
    }
}
