import SwiftUI

struct ReviewEditPageView: View {
    @ObservedObject var viewModel: AppViewModel
    private let sidebarWidth: CGFloat = 290
    private let inspectorWidth: CGFloat = 320

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: sidebarWidth)
                .frame(maxHeight: .infinity, alignment: .top)

            Divider()

            canvas
                .frame(minWidth: 520, maxWidth: .infinity)
                .frame(maxHeight: .infinity, alignment: .top)

            Divider()

            inspector
                .frame(width: inspectorWidth)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .onDeleteCommand {
            viewModel.deleteSelectedRegion()
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PanelCard(
                    title: L10n.Review.filesTitle,
                    subtitle: L10n.Review.filesSubtitle
                ) {
                    if viewModel.files.isEmpty {
                        Text(L10n.Review.noImportedFiles)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(viewModel.files) { file in
                                Button {
                                    viewModel.selectFile(file.id)
                                } label: {
                                    HStack(alignment: .top) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(file.displayName)
                                                .font(.headline)
                                                .multilineTextAlignment(.leading)
                                            Text(viewModel.fileSummary(for: file))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }

                                        Spacer()
                                        StatusBadge(text: file.status.displayTitle)
                                    }
                                    .padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(file.id == viewModel.selectedFileID ? Color.accentColor.opacity(0.10) : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                PanelCard(
                    title: L10n.Review.pagesTitle,
                    subtitle: L10n.Review.pagesSubtitle
                ) {
                    if let pages = viewModel.selectedFile?.pages, !pages.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(pages) { page in
                                Button {
                                    viewModel.selectPage(page.id)
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(page.title)
                                                .font(.headline)
                                            Text(viewModel.pageSummary(for: page))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }

                                        Spacer()
                                        StatusBadge(text: page.status.displayTitle)
                                    }
                                    .padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(page.id == viewModel.selectedPageID ? Color.accentColor.opacity(0.10) : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } else {
                        Text(L10n.Review.noPagesAvailable)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)
        }
    }

    private var canvas: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(L10n.Review.canvasSectionTitle)
                    .font(.title2.weight(.semibold))

                PanelCard(
                    title: viewModel.canvasTitle,
                    subtitle: L10n.Review.canvasSubtitle
                ) {
                    VStack(spacing: 18) {
                        DocumentPreviewView(
                            content: viewModel.previewContent,
                            regions: viewModel.selectedPageRegions,
                            selectedRegionID: viewModel.selectedRegionID,
                            onSelectRegion: viewModel.selectRegion,
                            onCreateRegion: viewModel.createRegion(with:),
                            onUpdateRegion: viewModel.updateRegion
                        )

                        HStack {
                            Label(viewModel.selectedFileDisplayLabel, systemImage: "doc.text")
                            Spacer()
                            Label(viewModel.selectedPageDisplayLabel, systemImage: "doc.plaintext")
                        }
                        .foregroundStyle(.secondary)

                        HStack {
                            if let selectedPreviewMetadataSummary = viewModel.selectedPreviewMetadataSummary,
                               let selectedPageStatusSummary = viewModel.selectedPageStatusSummary {
                                Text(selectedPreviewMetadataSummary)
                                Spacer()
                                Text(selectedPageStatusSummary)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        HStack {
                            Text(L10n.Review.manualEditHint)
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Spacer()

                            Button(role: .destructive) {
                                viewModel.deleteSelectedRegion()
                            } label: {
                                Label(L10n.Review.deleteRegion, systemImage: "trash")
                            }
                            .keyboardShortcut(.delete, modifiers: [])
                            .disabled(!viewModel.hasSelectedRegion)
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PanelCard(
                    title: L10n.Review.inspectorTitle,
                    subtitle: L10n.Review.inspectorSubtitle
                ) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(L10n.Review.maskPreset)
                            .font(.headline)

                        Picker(L10n.Review.maskPreset, selection: $viewModel.selectedPreset) {
                            ForEach(MaskPreset.allCases) { preset in
                                Text(preset.title).tag(preset)
                            }
                        }

                        Text(viewModel.selectedPreset.summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Divider()

                        Label(viewModel.selectedFileRegionsSummary, systemImage: "square.dashed")
                        Label(viewModel.totalSessionRegionsSummary, systemImage: "square.stack.3d.down.right")
                        Label(viewModel.maskPreviewSummary, systemImage: "rectangle.and.pencil.and.ellipsis")
                    }
                }

                PanelCard(
                    title: L10n.Review.detectionTitle,
                    subtitle: L10n.Review.detectionSubtitle
                ) {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(viewModel.ocrSummary, systemImage: "text.viewfinder")
                        Label(viewModel.barcodeSummary, systemImage: "barcode.viewfinder")
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
    }
}
