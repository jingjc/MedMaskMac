import AppKit
import Foundation
import PDFKit

enum DocumentPreviewContent {
    case empty
    case image(NSImage)
    case pdf(document: PDFDocument, pageIndex: Int)
    case failure(message: String)
}

@MainActor
protocol PDFRenderService {
    func canvasTitle(for page: PageItem?) -> String
    func previewContent(for file: FileItem?, page: PageItem?) -> DocumentPreviewContent
}

@MainActor
final class DefaultPDFRenderService: PDFRenderService {
    private var imageCache: [URL: NSImage] = [:]
    private var pdfCache: [URL: PDFDocument] = [:]

    func canvasTitle(for page: PageItem?) -> String {
        if let page {
            return L10n.Services.canvasTitle(for: page.title)
        }

        return L10n.Services.emptyCanvasTitle
    }

    func previewContent(for file: FileItem?, page: PageItem?) -> DocumentPreviewContent {
        guard let file else {
            return .empty
        }

        guard let sourceURL = file.sourceURL else {
            return .failure(message: L10n.Review.previewUnavailable)
        }

        switch file.kind {
        case .image:
            return loadImagePreview(fileName: file.displayName, sourceURL: sourceURL)
        case .pdf:
            return loadPDFPreview(
                fileName: file.displayName,
                sourceURL: sourceURL,
                preferredPageIndex: page?.sourcePageIndex ?? 0
            )
        }
    }

    private func loadImagePreview(fileName: String, sourceURL: URL) -> DocumentPreviewContent {
        if let cachedImage = imageCache[sourceURL] {
            return .image(cachedImage)
        }

        return withSecurityScopedAccess(to: sourceURL) {
            guard let image = NSImage(contentsOf: sourceURL) else {
                return .failure(message: L10n.Review.previewLoadFailed(fileName))
            }

            imageCache[sourceURL] = image
            return .image(image)
        }
    }

    private func loadPDFPreview(
        fileName: String,
        sourceURL: URL,
        preferredPageIndex: Int
    ) -> DocumentPreviewContent {
        let document: PDFDocument?

        if let cachedDocument = pdfCache[sourceURL] {
            document = cachedDocument
        } else {
            document = withSecurityScopedAccess(to: sourceURL) {
                PDFDocument(url: sourceURL)
            }

            if let document {
                pdfCache[sourceURL] = document
            }
        }

        guard let document else {
            return .failure(message: L10n.Review.previewLoadFailed(fileName))
        }

        guard document.pageCount > 0 else {
            return .failure(message: L10n.Review.previewUnavailable)
        }

        let resolvedPageIndex = max(0, min(preferredPageIndex, document.pageCount - 1))
        guard document.page(at: resolvedPageIndex) != nil else {
            return .failure(message: L10n.Review.previewUnavailable)
        }

        return .pdf(document: document, pageIndex: resolvedPageIndex)
    }

    private func withSecurityScopedAccess<T>(to url: URL, operation: () -> T) -> T {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        return operation()
    }
}
