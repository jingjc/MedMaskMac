import PDFKit
import SwiftUI

struct DocumentPreviewView: View {
    let content: DocumentPreviewContent

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(nsColor: .underPageBackgroundColor))

            previewBody
                .padding(16)
        }
        .frame(maxWidth: .infinity, minHeight: 480)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    @ViewBuilder
    private var previewBody: some View {
        switch content {
        case .empty:
            PreviewFallbackView(
                systemImage: "doc.viewfinder",
                message: L10n.Review.canvasPreviewPlaceholder
            )
        case let .image(image):
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .pdf(document, pageIndex):
            PDFPagePreviewRepresentable(document: document, pageIndex: pageIndex)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failure(message):
            PreviewFallbackView(
                systemImage: "exclamationmark.triangle",
                message: message
            )
        }
    }
}

private struct PreviewFallbackView: View {
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 42))
                .foregroundStyle(.secondary)

            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PDFPagePreviewRepresentable: NSViewRepresentable {
    let document: PDFDocument
    let pageIndex: Int

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePage
        pdfView.displaysPageBreaks = false
        pdfView.backgroundColor = .clear
        pdfView.minScaleFactor = 0.1
        pdfView.maxScaleFactor = 6.0
        return pdfView
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document !== document {
            nsView.document = document
        }

        if let page = document.page(at: pageIndex), nsView.currentPage !== page {
            nsView.go(to: page)
        }
    }
}
