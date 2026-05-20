import SwiftUI

struct ReviewEditPageView: View {
    @ObservedObject var viewModel: AppViewModel
    @FocusState private var isPreviewFocused: Bool
    @State private var canvasViewportSize: CGSize = .zero

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
        .onMoveCommand { direction in
            switch direction {
            case .left:
                viewModel.goToPreviousPage()
            case .right:
                viewModel.goToNextPage()
            default:
                break
            }
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
                                            if file.id == viewModel.selectedFileID,
                                               let metadata = viewModel.selectedSinglePageSidebarMetadata {
                                                Text(metadata)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
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

                if viewModel.shouldShowPagesCard {
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
                    let previewContent = viewModel.previewContent
                    let previewCanvasSize = rasterCanvasSize(for: previewContent)

                    VStack(spacing: 18) {
                        VStack(spacing: 10) {
                            HStack(spacing: 12) {
                                Picker(L10n.Review.previewMode, selection: $viewModel.previewDisplayMode) {
                                    ForEach(ReviewPreviewMode.allCases) { mode in
                                        Text(mode.title).tag(mode)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 280)
                                .disabled(!viewModel.hasImportedFiles)

                                Spacer()

                                Button(L10n.Review.undo) {
                                    viewModel.undoCurrentPageEdit()
                                }
                                .disabled(!viewModel.isEditingEnabled || !viewModel.canUndoCurrentPageEdit)

                                Button(L10n.Review.redo) {
                                    viewModel.redoCurrentPageEdit()
                                }
                                .disabled(!viewModel.isEditingEnabled || !viewModel.canRedoCurrentPageEdit)

                                Button(L10n.Export.exportButton) {
                                    viewModel.beginExportFlow()
                                }
                                .disabled(!viewModel.canBeginExportFlow)
                            }

                            zoomControls(contentSize: previewCanvasSize)
                        }

                        DocumentPreviewView(
                            content: previewContent,
                            regions: viewModel.displayedPreviewRegions,
                            selectedRegionID: viewModel.selectedRegionID,
                            isEditingEnabled: viewModel.isEditingEnabled,
                            zoomScale: viewModel.resolvedCanvasZoomScale(
                                contentSize: previewCanvasSize,
                                viewportSize: canvasViewportSize
                            ),
                            scrollOffset: Binding(
                                get: { viewModel.selectedCanvasScrollOffset },
                                set: { viewModel.updateSelectedCanvasScrollOffset($0) }
                            ),
                            onViewportSizeChanged: { canvasViewportSize = $0 },
                            onSelectRegion: selectPreviewRegion,
                            onCreateRegion: createPreviewRegion,
                            onUpdateRegion: updatePreviewRegion,
                            onEditTransactionBegan: viewModel.beginPageEditTransaction,
                            onEditTransactionEnded: viewModel.endPageEditTransaction
                        )
                        .focusable()
                        .focusEffectDisabled()
                        .focused($isPreviewFocused)
                        .onDeleteCommand {
                            viewModel.deleteSelectedRegion()
                        }

                        HStack {
                            Label(viewModel.selectedFileDisplayLabel, systemImage: "doc.text")
                            Spacer()
                            Label(viewModel.selectedPageDisplayLabel, systemImage: "doc.plaintext")
                            Spacer()
                            HStack(spacing: 8) {
                                Button(L10n.Review.previousPage) {
                                    viewModel.goToPreviousPage()
                                }
                                .disabled(!viewModel.canGoToPreviousPage)

                                Button(L10n.Review.nextPage) {
                                    viewModel.goToNextPage()
                                }
                                .disabled(!viewModel.canGoToNextPage)
                            }
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
                            Text(viewModel.isEditingEnabled ? L10n.Review.manualEditHint : L10n.Review.maskedPreviewHint)
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Spacer()

                            Button(role: .destructive) {
                                viewModel.deleteSelectedRegion()
                            } label: {
                                Label(L10n.Review.deleteRegion, systemImage: "trash")
                            }
                            .disabled(!viewModel.canDeleteSelectedRegion)
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private func zoomControls(contentSize: CGSize?) -> some View {
        HStack(spacing: 8) {
            Button("-") {
                viewModel.zoomCanvasOut(
                    contentSize: contentSize,
                    viewportSize: canvasViewportSize
                )
            }
            .disabled(contentSize == nil)

            Text(viewModel.canvasZoomPercentageText(
                contentSize: contentSize,
                viewportSize: canvasViewportSize
            ))
            .font(.caption.monospacedDigit())
            .frame(width: 52)

            Button("+") {
                viewModel.zoomCanvasIn(
                    contentSize: contentSize,
                    viewportSize: canvasViewportSize
                )
            }
            .disabled(contentSize == nil)

            Divider()
                .frame(height: 18)

            Button(L10n.Review.fitToWindow) {
                viewModel.fitCanvasToWindow()
            }
            .disabled(contentSize == nil)

            Button(L10n.Review.fitToWidth) {
                viewModel.fitCanvasToWidth()
            }
            .disabled(contentSize == nil)

            Button(L10n.Review.actualSize) {
                viewModel.resetCanvasZoomToActualSize()
            }
            .disabled(contentSize == nil)

            Spacer()
        }
        .controlSize(.small)
    }

    private func rasterCanvasSize(for content: DocumentPreviewContent) -> CGSize? {
        guard case let .raster(rasterContent) = content else {
            return nil
        }

        return rasterContent.canvasSize
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

                        if viewModel.selectedPreset == .custom {
                            customPresetChecklist
                        }

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
                        Button {
                            viewModel.detectCurrentPageOCR()
                        } label: {
                            Label(L10n.Review.detectCurrentPage, systemImage: "text.viewfinder")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!viewModel.canDetectCurrentPageOCR)

                        HStack(spacing: 8) {
                            if viewModel.currentPageOCRState.isRunning {
                                ProgressView()
                                    .controlSize(.small)
                            }

                            Text(viewModel.currentPageOCRStateSummary)
                        }
                        .font(.subheadline)

                        Text(L10n.Review.ocrSuggestionHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Divider()

                        Label(viewModel.ocrSummary, systemImage: "text.viewfinder")
                            .foregroundStyle(.secondary)
                        Label(viewModel.barcodeSummary, systemImage: "barcode.viewfinder")
                            .foregroundStyle(.secondary)

                        Divider()

                        VStack(alignment: .leading, spacing: 10) {
                            Text(L10n.Review.ocrDetectedItemsTitle)
                                .font(.headline)

                            if viewModel.hasVisibleSelectedPageOCRCandidates {
                                ForEach(viewModel.visibleSelectedPageOCRCandidates) { candidate in
                                    OCRCandidateRow(
                                        candidate: candidate,
                                        isSelected: viewModel.selectedOCRCandidateID == candidate.id,
                                        onMask: {
                                            viewModel.maskOCRCandidate(candidate.id)
                                            isPreviewFocused = true
                                        },
                                        onIgnore: {
                                            viewModel.ignoreOCRCandidate(candidate.id)
                                        },
                                        onUndo: {
                                            viewModel.undoOCRCandidate(candidate.id)
                                        },
                                        onLocate: {
                                            viewModel.selectOCRCandidate(candidate.id)
                                            isPreviewFocused = true
                                        }
                                    )
                                }
                            } else {
                                Text(L10n.Review.ocrNoCandidates)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private var customPresetChecklist: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.Review.customPresetFieldsTitle)
                .font(.subheadline.weight(.semibold))

            ForEach(MaskCustomField.allCases) { field in
                Toggle(
                    field.title,
                    isOn: Binding(
                        get: { viewModel.isCustomFieldEnabled(field) },
                        set: { viewModel.setCustomField(field, isEnabled: $0) }
                    )
                )
            }
        }
        .toggleStyle(.checkbox)
    }

    private func selectPreviewRegion(_ regionID: SensitiveRegion.ID?) {
        viewModel.selectRegion(regionID)
        isPreviewFocused = true
    }

    private func createPreviewRegion(with bounds: NormalizedRect) {
        viewModel.createRegion(with: bounds)
        isPreviewFocused = true
    }

    private func updatePreviewRegion(_ regionID: SensitiveRegion.ID, _ bounds: NormalizedRect) {
        viewModel.updateRegion(regionID, bounds: bounds)
        isPreviewFocused = true
    }
}

private struct OCRCandidateRow: View {
    let candidate: OCRSensitiveCandidate
    let isSelected: Bool
    let onMask: () -> Void
    let onIgnore: () -> Void
    let onUndo: () -> Void
    let onLocate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(candidate.displayTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(candidate.displayValueText)
                .font(.subheadline)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 8) {
                Button(L10n.Review.maskOCRCandidate) {
                    onMask()
                }
                .disabled(!canMask)

                Button(L10n.Review.ignoreOCRCandidate) {
                    onIgnore()
                }
                .disabled(!canIgnore)

                Button(L10n.Review.undoOCRCandidate) {
                    onUndo()
                }
                .disabled(!canUndo)

                Button(L10n.Review.locateOCRCandidate) {
                    onLocate()
                }
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(candidate.status == .ignored ? 0.58 : 1)
        .background(rowBackgroundColor)
        .overlay(
            HStack(spacing: 0) {
                Rectangle()
                    .fill(isSelected ? Color.secondary.opacity(0.45) : Color.clear)
                    .frame(width: 3)
                Spacer(minLength: 0)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var canMask: Bool {
        candidate.status == .pending
    }

    private var canIgnore: Bool {
        candidate.status == .pending
    }

    private var canUndo: Bool {
        candidate.status == .masked || candidate.status == .ignored
    }

    private var rowBackgroundColor: Color {
        if isSelected {
            return Color(nsColor: .separatorColor).opacity(0.18)
        }

        switch candidate.status {
        case .pending, .masked:
            return Color(nsColor: .controlBackgroundColor)
        case .ignored:
            return Color(nsColor: .controlBackgroundColor).opacity(0.55)
        }
    }
}
