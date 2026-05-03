import SwiftUI

struct DocumentPreviewView: View {
    let content: DocumentPreviewContent
    let regions: [SensitiveRegion]
    let selectedRegionID: SensitiveRegion.ID?
    let onSelectRegion: (SensitiveRegion.ID?) -> Void
    let onCreateRegion: (NormalizedRect) -> Void
    let onUpdateRegion: (SensitiveRegion.ID, NormalizedRect) -> Void

    private let previewCornerRadius: CGFloat = 24
    private let previewPadding: CGFloat = 16

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: previewCornerRadius, style: .continuous)
                .fill(Color(nsColor: .underPageBackgroundColor))

            previewBody
                .padding(previewPadding)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 480, idealHeight: 560, maxHeight: 640)
        .clipShape(RoundedRectangle(cornerRadius: previewCornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: previewCornerRadius, style: .continuous))
    }

    @ViewBuilder
    private var previewBody: some View {
        switch content {
        case .empty:
            PreviewFallbackView(
                systemImage: "doc.viewfinder",
                message: L10n.Review.canvasPreviewPlaceholder
            )
        case let .raster(rasterContent):
            GeometryReader { proxy in
                previewCanvas(for: rasterContent, in: proxy.size)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        case let .failure(message):
            PreviewFallbackView(
                systemImage: "exclamationmark.triangle",
                message: message
            )
        }
    }

    private func aspectFitSize(for contentSize: CGSize, in availableSize: CGSize) -> CGSize {
        guard contentSize.width > 0,
              contentSize.height > 0,
              availableSize.width > 0,
              availableSize.height > 0 else {
            return .zero
        }

        let widthScale = availableSize.width / contentSize.width
        let heightScale = availableSize.height / contentSize.height
        let scale = min(widthScale, heightScale)

        return CGSize(
            width: contentSize.width * scale,
            height: contentSize.height * scale
        )
    }

    @ViewBuilder
    private func previewCanvas(
        for rasterContent: DocumentPreviewRasterContent,
        in availableSize: CGSize
    ) -> some View {
        let fittedSize = aspectFitSize(for: rasterContent.canvasSize, in: availableSize)

        if fittedSize.width > 0, fittedSize.height > 0 {
            ZStack {
                Image(nsImage: rasterContent.image)
                    .resizable()
                    .interpolation(.high)
                    .allowsHitTesting(false)

                RegionEditorOverlayView(
                    contentSize: fittedSize,
                    regions: regions,
                    selectedRegionID: selectedRegionID,
                    onSelectRegion: onSelectRegion,
                    onCreateRegion: onCreateRegion,
                    onUpdateRegion: onUpdateRegion
                )
            }
            .frame(width: fittedSize.width, height: fittedSize.height)
            .clipped()
            .contentShape(Rectangle())
        } else {
            PreviewFallbackView(
                systemImage: "exclamationmark.triangle",
                message: L10n.Review.previewUnavailable
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
