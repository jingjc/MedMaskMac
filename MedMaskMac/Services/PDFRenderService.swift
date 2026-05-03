import Foundation

protocol PDFRenderService {
    func canvasTitle(for page: PageItem?) -> String
}

struct PlaceholderPDFRenderService: PDFRenderService {
    func canvasTitle(for page: PageItem?) -> String {
        if let page {
            return "\(page.title) Canvas Placeholder"
        }

        return "Canvas Placeholder"
    }
}
