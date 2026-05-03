import Combine
import Foundation

@MainActor
final class AppViewModel: ObservableObject {
    @Published var selectedPage: AppPage = .import
    @Published var selectedPreset: MaskPreset = .standard
    @Published var files: [FileItem]
    @Published var selectedFileID: FileItem.ID?
    @Published var selectedPageID: PageItem.ID?
    @Published var importErrorMessage: String?

    private let fileImportService: any FileImportService
    private let pdfRenderService: any PDFRenderService
    private let ocrService: any OCRService
    private let barcodeService: any BarcodeService
    private let maskComposeService: any MaskComposeService
    private let exportService: any ExportService
    private var lastSelectedPageByFileID: [FileItem.ID: PageItem.ID] = [:]

    init() {
        self.files = []
        self.fileImportService = DefaultFileImportService()
        self.pdfRenderService = DefaultPDFRenderService()
        self.ocrService = PlaceholderOCRService()
        self.barcodeService = PlaceholderBarcodeService()
        self.maskComposeService = PlaceholderMaskComposeService()
        self.exportService = PlaceholderExportService()
        self.selectedFileID = nil
        self.selectedPageID = nil
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
        pdfRenderService.previewContent(for: selectedFile, page: selectedDocumentPage)
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

    var maskPreviewSummary: String {
        maskComposeService.previewSummary(for: selectedPreset, regionCount: totalRegionCount)
    }

    var exportPlaceholderSummary: String {
        exportService.exportSummary(for: files, preset: selectedPreset)
    }

    var hasImportedFiles: Bool {
        !files.isEmpty
    }

    var selectedFileDisplayLabel: String {
        selectedFile?.displayName ?? L10n.Review.noFileSelected
    }

    var selectedPageDisplayLabel: String {
        selectedDocumentPage?.title ?? L10n.Review.noPageSelected
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
        L10n.Common.placeholderRegionCount(totalRegionCount)
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
        selectedDocumentPage?.status.displayTitle
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
        selectedPageID = pageID

        if let selectedFileID {
            lastSelectedPageByFileID[selectedFileID] = pageID
        }
    }

    private func applySelection(for file: FileItem, preferredPageID: PageItem.ID?) {
        selectedFileID = file.id
        selectedPageID = resolvedPageID(in: file, preferredPageID: preferredPageID)

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
}
