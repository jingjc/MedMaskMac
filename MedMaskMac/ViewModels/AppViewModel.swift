import Combine
import Foundation

@MainActor
final class AppViewModel: ObservableObject {
    @Published var selectedPage: AppPage = .import
    @Published var selectedPreset: MaskPreset = .standard
    @Published var files: [FileItem]
    @Published var selectedFileID: FileItem.ID?
    @Published var selectedPageID: PageItem.ID?

    private let fileImportService: any FileImportService
    private let pdfRenderService: any PDFRenderService
    private let ocrService: any OCRService
    private let barcodeService: any BarcodeService
    private let maskComposeService: any MaskComposeService
    private let exportService: any ExportService

    init() {
        let files = PlaceholderContent.files

        self.files = files
        self.fileImportService = PlaceholderFileImportService()
        self.pdfRenderService = PlaceholderPDFRenderService()
        self.ocrService = PlaceholderOCRService()
        self.barcodeService = PlaceholderBarcodeService()
        self.maskComposeService = PlaceholderMaskComposeService()
        self.exportService = PlaceholderExportService()
        self.selectedFileID = files.first?.id
        self.selectedPageID = files.first?.pages.first?.id
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

    var importPlaceholderMessage: String {
        fileImportService.placeholderMessage()
    }

    var canvasTitle: String {
        pdfRenderService.canvasTitle(for: selectedDocumentPage)
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

    func selectFile(_ fileID: FileItem.ID) {
        selectedFileID = fileID
        selectedPageID = files.first { $0.id == fileID }?.pages.first?.id
    }

    func selectPage(_ pageID: PageItem.ID) {
        selectedPageID = pageID
    }
}
