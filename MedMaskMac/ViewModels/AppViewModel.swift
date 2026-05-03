import Combine
import Foundation

@MainActor
final class AppViewModel: ObservableObject {
    @Published var selectedPage: AppPage = .import
    @Published var selectedPreset: MaskPreset = .standard {
        didSet {
            guard oldValue != selectedPreset else {
                return
            }

            lastExportResult = nil
        }
    }
    @Published var previewDisplayMode: ReviewPreviewMode = .original {
        didSet {
            if previewDisplayMode == .maskedPreview {
                selectedRegionID = nil
            }
        }
    }
    @Published var files: [FileItem] {
        didSet {
            guard oldValue != files else {
                return
            }

            lastExportResult = nil
        }
    }
    @Published var selectedFileID: FileItem.ID?
    @Published var selectedPageID: PageItem.ID?
    @Published var selectedRegionID: SensitiveRegion.ID?
    @Published var importErrorMessage: String?
    @Published var lastExportResult: ExportResult?

    private let fileImportService: any FileImportService
    private let pdfRenderService: any PDFRenderService
    private let ocrService: any OCRService
    private let barcodeService: any BarcodeService
    private let maskComposeService: any MaskComposeService
    private let exportService: any ExportService
    private var lastSelectedPageByFileID: [FileItem.ID: PageItem.ID] = [:]
    private var undoStack: [PageEditSnapshot] = []
    private var redoStack: [PageEditSnapshot] = []
    private var historyPageID: PageItem.ID?
    private var isPageEditTransactionOpen = false

    init() {
        self.files = []
        self.fileImportService = DefaultFileImportService()
        self.pdfRenderService = DefaultPDFRenderService()
        self.ocrService = PlaceholderOCRService()
        self.barcodeService = PlaceholderBarcodeService()
        self.maskComposeService = DefaultMaskComposeService()
        self.exportService = DefaultExportService(maskComposeService: maskComposeService)
        self.selectedFileID = nil
        self.selectedPageID = nil
        self.selectedRegionID = nil
        self.lastExportResult = nil
    }

    var selectedFile: FileItem? {
        files.first { $0.id == selectedFileID }
    }

    var selectedDocumentPage: PageItem? {
        selectedFile?.pages.first { $0.id == selectedPageID }
    }

    var supportedImportTypes: String {
        fileImportService.supportedFileTypes().joined(separator: ", ")
    }

    var importGuidanceMessage: String {
        fileImportService.importGuidanceMessage()
    }

    var canvasTitle: String {
        pdfRenderService.canvasTitle(for: selectedDocumentPage)
    }

    var previewContent: DocumentPreviewContent {
        let baseContent = pdfRenderService.previewContent(for: selectedFile, page: selectedDocumentPage)

        guard previewDisplayMode == .maskedPreview,
              let selectedDocumentPage,
              case let .raster(rasterContent) = baseContent else {
            return baseContent
        }

        return .raster(
            maskComposeService.maskedPreview(
                from: rasterContent,
                regions: selectedDocumentPage.sensitiveRegions,
                preset: selectedPreset
            )
        )
    }

    var ocrSummary: String {
        ocrService.availabilitySummary
    }

    var barcodeSummary: String {
        barcodeService.statusSummary
    }

    var totalPageCount: Int {
        files.reduce(0) { $0 + $1.pageCount }
    }

    var totalRegionCount: Int {
        files
            .flatMap(\.pages)
            .reduce(0) { $0 + $1.sensitiveRegions.count }
    }

    var selectedFileRegionCount: Int {
        selectedFile?.pages.reduce(0) { $0 + $1.sensitiveRegions.count } ?? 0
    }

    var selectedPageRegions: [SensitiveRegion] {
        selectedDocumentPage?.sensitiveRegions ?? []
    }

    var selectedRegion: SensitiveRegion? {
        selectedPageRegions.first { $0.id == selectedRegionID }
    }

    var hasSelectedRegion: Bool {
        selectedRegion != nil
    }

    var canDeleteSelectedRegion: Bool {
        isEditingEnabled && selectedRegion != nil
    }

    var maskPreviewSummary: String {
        maskComposeService.previewSummary(for: selectedPreset, regionCount: totalRegionCount)
    }

    var exportPreparedSummary: String {
        exportService.preparedSummary(for: files, preset: selectedPreset)
    }

    var hasImportedFiles: Bool {
        !files.isEmpty
    }

    var isReviewPageActive: Bool {
        selectedPage == .reviewEdit
    }

    var isEditingEnabled: Bool {
        previewDisplayMode == .original
    }

    var displayedPreviewRegions: [SensitiveRegion] {
        isEditingEnabled ? selectedPageRegions : []
    }

    var canUndoCurrentPageEdit: Bool {
        !undoStack.isEmpty
    }

    var canRedoCurrentPageEdit: Bool {
        !redoStack.isEmpty
    }

    var canGoToPreviousPage: Bool {
        guard let pages = selectedFile?.pages,
              let selectedPageID,
              let pageIndex = pages.firstIndex(where: { $0.id == selectedPageID }) else {
            return false
        }

        return pageIndex > 0
    }

    var canGoToNextPage: Bool {
        guard let pages = selectedFile?.pages,
              let selectedPageID,
              let pageIndex = pages.firstIndex(where: { $0.id == selectedPageID }) else {
            return false
        }

        return pageIndex < pages.index(before: pages.endIndex)
    }

    var shouldShowPagesCard: Bool {
        guard let selectedFile else {
            return false
        }

        return selectedFile.pageCount > 1
    }

    var canBeginExportFlow: Bool {
        hasImportedFiles
    }

    var canOpenExportDestination: Bool {
        lastExportResult != nil
    }

    var selectedFileDisplayLabel: String {
        selectedFile?.displayName ?? L10n.Review.noFileSelected
    }

    var selectedPageDisplayLabel: String {
        selectedDocumentPage?.title ?? L10n.Review.noPageSelected
    }

    var selectedSinglePageSidebarMetadata: String? {
        guard let selectedFile,
              selectedFile.pageCount == 1,
              let page = selectedFile.pages.first else {
            return nil
        }

        return L10n.Review.singlePageMetadata(
            pageSummary: pageSummary(for: page),
            status: page.status.displayTitle
        )
    }

    var selectedFileRegionsSummary: String {
        L10n.Common.selectedFileRegions(selectedFileRegionCount)
    }

    var totalSessionRegionsSummary: String {
        L10n.Common.totalSessionRegions(totalRegionCount)
    }

    var importedFilesCardSubtitle: String {
        if hasImportedFiles {
            return L10n.Import.importedFilesSummary(fileCount: files.count, pageCount: totalPageCount)
        }

        return L10n.Import.importedFilesSessionSummary
    }

    var canGoToReview: Bool {
        hasImportedFiles
    }

    var preparedFilesSummary: String {
        L10n.Common.fileCount(files.count)
    }

    var preparedPagesSummary: String {
        L10n.Common.totalPageCount(totalPageCount)
    }

    var preparedRegionsSummary: String {
        L10n.Common.regionCount(totalRegionCount)
    }

    var lastExportDestinationPath: String? {
        lastExportResult?.destinationURL.path
    }

    var exportSuccessSummary: String? {
        guard let lastExportResult else {
            return nil
        }

        return L10n.Export.successCount(lastExportResult.successCount)
    }

    var exportFailureSummary: String? {
        guard let lastExportResult else {
            return nil
        }

        return L10n.Export.failureCount(lastExportResult.failureCount)
    }

    var hasExportFailures: Bool {
        guard let lastExportResult else {
            return false
        }

        return !lastExportResult.failures.isEmpty
    }

    var selectedFileMetadataSummary: String? {
        guard let selectedFile else {
            return nil
        }

        return fileSummary(for: selectedFile)
    }

    var selectedPreviewMetadataSummary: String? {
        guard let selectedFile, let selectedDocumentPage else {
            return nil
        }

        return L10n.Review.previewMetadata(
            kind: selectedFile.kind.displayTitle,
            pageNumber: selectedDocumentPage.pageNumber,
            pageCount: selectedFile.pageCount
        )
    }

    var selectedPageStatusSummary: String? {
        if previewDisplayMode == .maskedPreview {
            return L10n.PageStatus.maskedPreview
        }

        return selectedDocumentPage?.status.displayTitle
    }

    func fileSummary(for file: FileItem) -> String {
        L10n.Common.filePageSummary(kind: file.kind.displayTitle, pageCount: file.pageCount)
    }

    func pageSummary(for page: PageItem) -> String {
        L10n.Common.regionCount(page.sensitiveRegions.count)
    }

    func importFiles() {
        importErrorMessage = nil

        do {
            let importedFiles = try fileImportService.importFiles()

            guard !importedFiles.isEmpty else {
                return
            }

            let shouldSelectImportedContent = selectedFile == nil
            files.append(contentsOf: importedFiles)

            if shouldSelectImportedContent, let firstImportedFile = importedFiles.first {
                applySelection(for: firstImportedFile, preferredPageID: firstImportedFile.pages.first?.id)
            } else if selectedPageID == nil {
                if let selectedFile {
                    applySelection(for: selectedFile, preferredPageID: selectedFile.pages.first?.id)
                }
            }
        } catch {
            importErrorMessage = error.localizedDescription
        }
    }

    func goToReview() {
        guard canGoToReview else {
            return
        }

        if selectedFile == nil, let firstFile = files.first {
            applySelection(for: firstFile, preferredPageID: firstFile.pages.first?.id)
        }

        selectedPage = .reviewEdit
    }

    func selectFile(_ fileID: FileItem.ID) {
        guard let file = files.first(where: { $0.id == fileID }) else {
            return
        }

        let preferredPageID = lastSelectedPageByFileID[fileID] ?? file.pages.first?.id
        applySelection(for: file, preferredPageID: preferredPageID)
    }

    func selectPage(_ pageID: PageItem.ID) {
        guard let selectedFile, selectedFile.pages.contains(where: { $0.id == pageID }) else {
            return
        }

        selectedPageID = pageID
        selectedRegionID = nil
        clearPageHistory()

        if let selectedFileID {
            lastSelectedPageByFileID[selectedFileID] = pageID
        }
    }

    func selectRegion(_ regionID: SensitiveRegion.ID?) {
        guard let regionID else {
            selectedRegionID = nil
            return
        }

        guard selectedPageRegions.contains(where: { $0.id == regionID }) else {
            selectedRegionID = nil
            return
        }

        guard regionID != selectedRegionID else {
            return
        }

        selectedRegionID = regionID
    }

    func clearSelectedRegionSelection() {
        selectedRegionID = nil
    }

    func createRegion(with bounds: NormalizedRect) {
        let clampedBounds = bounds.clamped()
        guard clampedBounds.width > 0, clampedBounds.height > 0 else {
            return
        }

        let startedImplicitTransaction = beginImplicitPageEditTransactionIfNeeded()
        var createdRegionID: SensitiveRegion.ID?
        mutateSelectedPage { page in
            let region = SensitiveRegion(
                kind: .freeform,
                bounds: clampedBounds,
                isMasked: true
            )
            page.sensitiveRegions.append(region)
            createdRegionID = region.id
        }

        selectedRegionID = createdRegionID

        if startedImplicitTransaction {
            endPageEditTransaction()
        }
    }

    func updateRegion(_ regionID: SensitiveRegion.ID, bounds: NormalizedRect) {
        let startedImplicitTransaction = beginImplicitPageEditTransactionIfNeeded()
        mutateSelectedPage { page in
            guard let regionIndex = page.sensitiveRegions.firstIndex(where: { $0.id == regionID }) else {
                return
            }

            page.sensitiveRegions[regionIndex].bounds = bounds.clamped()
        }

        if startedImplicitTransaction {
            endPageEditTransaction()
        }
    }

    func deleteSelectedRegion() {
        guard canDeleteSelectedRegion, let selectedRegionID else {
            return
        }

        let startedImplicitTransaction = beginImplicitPageEditTransactionIfNeeded()
        mutateSelectedPage { page in
            page.sensitiveRegions.removeAll { $0.id == selectedRegionID }
        }

        self.selectedRegionID = nil

        if startedImplicitTransaction {
            endPageEditTransaction()
        }
    }

    func beginPageEditTransaction() {
        guard let selectedPageID else {
            return
        }

        if historyPageID != selectedPageID {
            clearPageHistory()
            historyPageID = selectedPageID
        }

        guard !isPageEditTransactionOpen, let snapshot = currentPageEditSnapshot else {
            return
        }

        undoStack.append(snapshot)
        if undoStack.count > 20 {
            undoStack.removeFirst(undoStack.count - 20)
        }
        redoStack.removeAll()
        isPageEditTransactionOpen = true
    }

    func endPageEditTransaction() {
        isPageEditTransactionOpen = false
    }

    func undoCurrentPageEdit() {
        guard let snapshot = undoStack.popLast(),
              let currentSnapshot = currentPageEditSnapshot else {
            return
        }

        redoStack.append(currentSnapshot)
        applyPageEditSnapshot(snapshot)
        isPageEditTransactionOpen = false
    }

    func redoCurrentPageEdit() {
        guard let snapshot = redoStack.popLast(),
              let currentSnapshot = currentPageEditSnapshot else {
            return
        }

        undoStack.append(currentSnapshot)
        applyPageEditSnapshot(snapshot)
        isPageEditTransactionOpen = false
    }

    func goToPreviousPage() {
        guard let pages = selectedFile?.pages,
              let selectedPageID,
              let currentIndex = pages.firstIndex(where: { $0.id == selectedPageID }),
              currentIndex > 0 else {
            return
        }

        selectPage(pages[currentIndex - 1].id)
    }

    func goToNextPage() {
        guard let pages = selectedFile?.pages,
              let selectedPageID,
              let currentIndex = pages.firstIndex(where: { $0.id == selectedPageID }),
              currentIndex < pages.index(before: pages.endIndex) else {
            return
        }

        selectPage(pages[currentIndex + 1].id)
    }

    func togglePreviewDisplayMode() {
        previewDisplayMode = previewDisplayMode.toggled()
    }

    func beginExportFlow() {
        guard canBeginExportFlow else {
            return
        }

        guard let destinationURL = exportService.chooseDestination() else {
            return
        }

        lastExportResult = exportService.exportSession(
            files: files,
            preset: selectedPreset,
            destinationURL: destinationURL
        )
        selectedPage = .exportSummary
    }

    func openExportDestination() {
        guard let destinationURL = lastExportResult?.destinationURL else {
            return
        }

        exportService.openFolder(at: destinationURL)
    }

    private func applySelection(for file: FileItem, preferredPageID: PageItem.ID?) {
        selectedFileID = file.id
        selectedPageID = resolvedPageID(in: file, preferredPageID: preferredPageID)
        selectedRegionID = nil
        clearPageHistory()

        if let selectedPageID {
            lastSelectedPageByFileID[file.id] = selectedPageID
        }
    }

    private func resolvedPageID(in file: FileItem, preferredPageID: PageItem.ID?) -> PageItem.ID? {
        if let preferredPageID, file.pages.contains(where: { $0.id == preferredPageID }) {
            return preferredPageID
        }

        return file.pages.first?.id
    }

    private func mutateSelectedPage(_ mutation: (inout PageItem) -> Void) {
        guard let selection = selectedPageLocation else {
            return
        }

        var updatedFiles = files
        mutation(&updatedFiles[selection.fileIndex].pages[selection.pageIndex])
        files = updatedFiles
    }

    private var selectedPageLocation: (fileIndex: Int, pageIndex: Int)? {
        guard let selectedFileID,
              let fileIndex = files.firstIndex(where: { $0.id == selectedFileID }),
              let selectedPageID,
              let pageIndex = files[fileIndex].pages.firstIndex(where: { $0.id == selectedPageID }) else {
            return nil
        }

        return (fileIndex, pageIndex)
    }

    private func beginImplicitPageEditTransactionIfNeeded() -> Bool {
        guard !isPageEditTransactionOpen else {
            return false
        }

        beginPageEditTransaction()
        return true
    }

    private func clearPageHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
        historyPageID = selectedPageID
        isPageEditTransactionOpen = false
    }

    private func applyPageEditSnapshot(_ snapshot: PageEditSnapshot) {
        mutateSelectedPage { page in
            page.sensitiveRegions = snapshot.regions
        }

        if let selectedRegionID = snapshot.selectedRegionID,
           selectedPageRegions.contains(where: { $0.id == selectedRegionID }) {
            self.selectedRegionID = selectedRegionID
        } else {
            self.selectedRegionID = nil
        }
    }

    private var currentPageEditSnapshot: PageEditSnapshot? {
        guard let selectedDocumentPage else {
            return nil
        }

        return PageEditSnapshot(
            regions: selectedDocumentPage.sensitiveRegions,
            selectedRegionID: selectedRegionID
        )
    }
}

private struct PageEditSnapshot {
    let regions: [SensitiveRegion]
    let selectedRegionID: SensitiveRegion.ID?
}
