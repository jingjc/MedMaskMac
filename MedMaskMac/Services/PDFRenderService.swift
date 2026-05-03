import Foundation

protocol PDFRenderService {
    func canvasTitle(for page: PageItem?) -> String
}

struct PlaceholderPDFRenderService: PDFRenderService {
    func canvasTitle(for page: PageItem?) -> String {
        if let page {
            return L10n.Services.canvasTitle(for: page.title)
        }

        return L10n.Services.emptyCanvasTitle
    }
}
