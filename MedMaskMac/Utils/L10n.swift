import Foundation

enum L10n {
    private static let table = "Localizable"

    private static func string(_ key: String, default defaultValue: String) -> String {
        Bundle.main.localizedString(forKey: key, value: defaultValue, table: table)
    }

    private static func formatted(
        _ key: String,
        default defaultValue: String,
        _ arguments: CVarArg...
    ) -> String {
        String(format: string(key, default: defaultValue), locale: Locale.current, arguments: arguments)
    }

    private static func countText(_ count: Int) -> String {
        count.formatted()
    }

    enum App {
        static let title = L10n.string("app.title", default: "MedMask Mac")
        static let pagePickerLabel = L10n.string("app.page_picker_label", default: "Page")
    }

    enum Navigation {
        static func title(for page: AppPage) -> String {
            switch page {
            case .import:
                L10n.string("nav.import.title", default: "Import")
            case .reviewEdit:
                L10n.string("nav.review.title", default: "Review / Edit")
            case .exportSummary:
                L10n.string("nav.export.title", default: "Export Summary")
            }
        }

        static func subtitle(for page: AppPage) -> String {
            switch page {
            case .import:
                L10n.string("nav.import.subtitle", default: "Prepare PDFs or images for a local redaction pass.")
            case .reviewEdit:
                L10n.string("nav.review.subtitle", default: "Inspect page structure before masking and export are implemented.")
            case .exportSummary:
                L10n.string("nav.export.subtitle", default: "Review the shell of the final redaction handoff.")
            }
        }
    }

    enum FileKind {
        static let pdf = L10n.string("file_kind.pdf", default: "PDF")
        static let image = L10n.string("file_kind.image", default: "Image")
    }

    enum FileStatus {
        static let imported = L10n.string("file_status.imported", default: "Imported")
        static let readyForReview = L10n.string("file_status.ready_for_review", default: "Ready For Review")
        static let needsAttention = L10n.string("file_status.needs_attention", default: "Needs Attention")
    }

    enum PageStatus {
        static let pendingDetection = L10n.string("page_status.pending_detection", default: "Pending Detection")
        static let readyForReview = L10n.string("page_status.ready_for_review", default: "Ready For Review")
        static let maskedPreview = L10n.string("page_status.masked_preview", default: "Masked Preview")
    }

    enum Preset {
        static let standardTitle = L10n.string("preset.standard.title", default: "Standard Redaction")
        static let standardSummary = L10n.string("preset.standard.summary", default: "Balanced default for common medical report cleanup.")
        static let strictTitle = L10n.string("preset.strict.title", default: "Strict Redaction")
        static let strictSummary = L10n.string("preset.strict.summary", default: "Wider masking intended for conservative review.")
        static let customTitle = L10n.string("preset.custom.title", default: "Custom Redaction")
        static let customSummary = L10n.string("preset.custom.summary", default: "Reserved for future manual redaction controls.")
    }

    enum Common {
        static func supportedFormats(_ types: String) -> String {
            L10n.formatted("common.supported_formats", default: "Supported: %@", types)
        }

        static func pageTitle(_ pageNumber: Int) -> String {
            L10n.formatted("common.page_title", default: "Page %@", countText(pageNumber))
        }

        static func pageCount(_ count: Int) -> String {
            L10n.formatted("common.page_count", default: "%@ page(s)", countText(count))
        }

        static func regionCount(_ count: Int) -> String {
            L10n.formatted("common.region_count", default: "%@ region(s)", countText(count))
        }

        static func fileCount(_ count: Int) -> String {
            L10n.formatted("common.file_count", default: "%@ file(s)", countText(count))
        }

        static func totalPageCount(_ count: Int) -> String {
            L10n.formatted("common.total_page_count", default: "%@ total page(s)", countText(count))
        }

        static func placeholderRegionCount(_ count: Int) -> String {
            L10n.formatted("common.placeholder_region_count", default: "%@ placeholder sensitive region(s)", countText(count))
        }

        static func filePageSummary(kind: String, pageCount: Int) -> String {
            L10n.formatted("common.file_page_summary", default: "%@ • %@", kind, self.pageCount(pageCount))
        }

        static func selectedFileRegions(_ count: Int) -> String {
            L10n.formatted("common.selected_file_regions", default: "Selected file regions: %@", countText(count))
        }

        static func totalSessionRegions(_ count: Int) -> String {
            L10n.formatted("common.total_session_regions", default: "Total session regions: %@", countText(count))
        }
    }

    enum Import {
        static let title = L10n.string("import.title", default: "Import Page")
        static let description = L10n.string("import.description", default: "Choose local PDF or image files to load them into the current session. OCR, barcode detection, and export remain unimplemented.")
        static let actionTitle = L10n.string("import.card.title", default: "Import Files")
        static let localFirst = L10n.string("import.local_first", default: "Local-only session")
        static let noBackground = L10n.string("import.no_background", default: "Metadata import only. No OCR, barcode scan, or export yet")
        static let chooseFiles = L10n.string("import.choose_files", default: "Choose Files")
        static let goToReview = L10n.string("import.go_to_review", default: "Go to Review / Edit")
        static let importedFilesTitle = L10n.string("import.card.session_seed_title", default: "Imported Files")
        static let importedFilesSessionSummary = L10n.string("import.summary.session_only", default: "Imported files remain in memory for the current session only.")
        static let emptyImportedFiles = L10n.string("import.summary.empty", default: "No files imported yet.")
        static let panelTitle = L10n.string("import.panel.title", default: "Import Files")
        static let panelMessage = L10n.string("import.panel.message", default: "Choose one or more PDF or image files to load into this session.")

        static func importedFilesSummary(fileCount: Int, pageCount: Int) -> String {
            L10n.formatted(
                "import.summary.counts",
                default: "%1$@ file(s) • %2$@ total page(s)",
                L10n.countText(fileCount),
                L10n.countText(pageCount)
            )
        }

        static func importErrorUnreadableFile(_ fileName: String) -> String {
            L10n.formatted("import.error.unreadable_file", default: "Could not import \"%@\".", fileName)
        }

        static func importErrorEmptyPDF(_ fileName: String) -> String {
            L10n.formatted("import.error.empty_pdf", default: "\"%@\" has no readable pages.", fileName)
        }
    }

    enum Review {
        static let filesTitle = L10n.string("review.sidebar.files_title", default: "Files")
        static let filesSubtitle = L10n.string("review.sidebar.files_subtitle", default: "Imported documents in the current session.")
        static let noImportedFiles = L10n.string("review.sidebar.no_files", default: "No files imported yet.")
        static let pagesTitle = L10n.string("review.sidebar.pages_title", default: "Pages")
        static let pagesSubtitle = L10n.string("review.sidebar.pages_subtitle", default: "Pages discovered from the selected file.")
        static let noPagesAvailable = L10n.string("review.sidebar.no_pages", default: "Select a file to view its pages.")
        static let canvasSectionTitle = L10n.string("review.canvas.title", default: "Canvas")
        static let canvasSubtitle = L10n.string("review.canvas.subtitle", default: "Actual preview is shown here for imported images and PDF pages.")
        static let canvasPreviewPlaceholder = L10n.string("review.canvas.preview_placeholder", default: "Select a file and page to preview.")
        static let noFileSelected = L10n.string("review.canvas.no_file", default: "No file selected")
        static let noPageSelected = L10n.string("review.canvas.no_page", default: "No page selected")
        static let inspectorTitle = L10n.string("review.inspector.title", default: "Inspector")
        static let inspectorSubtitle = L10n.string("review.inspector.subtitle", default: "Right-side placeholder for mask settings and page details.")
        static let maskPreset = L10n.string("review.inspector.mask_preset", default: "Mask Preset")
        static let detectionTitle = L10n.string("review.inspector.detection_title", default: "Detection Status")
        static let detectionSubtitle = L10n.string("review.inspector.detection_subtitle", default: "Service placeholders only. No OCR or barcode pass runs yet.")

        static var previewUnavailable: String {
            L10n.string("review.canvas.preview_unavailable", default: "Preview unavailable for the selected content.")
        }

        static func previewLoadFailed(_ fileName: String) -> String {
            L10n.formatted("review.canvas.preview_load_failed", default: "Could not load a preview for \"%@\".", fileName)
        }

        static func previewMetadata(kind: String, pageNumber: Int, pageCount: Int) -> String {
            L10n.formatted(
                "review.canvas.preview_metadata",
                default: "%1$@ • Page %2$@ of %3$@",
                kind,
                L10n.countText(pageNumber),
                L10n.countText(pageCount)
            )
        }
    }

    enum Export {
        static let title = L10n.string("export.title", default: "Export Summary")
        static let description = L10n.string("export.description", default: "Export is intentionally not implemented in this phase. This page only establishes the shell and the future summary surface.")
        static let preparedTitle = L10n.string("export.prepared_title", default: "Prepared Session")
        static let nextPhaseTitle = L10n.string("export.next_phase_title", default: "Next Phase Boundary")
        static let nextPhaseSubtitle = L10n.string("export.next_phase_subtitle", default: "Scope remains fixed to a shell-only export summary.")
        static let noAction = L10n.string("export.no_action", default: "No real export action")
        static let noQualitySettings = L10n.string("export.no_quality_settings", default: "No quality settings")
        static let originalUnchanged = L10n.string("export.original_unchanged", default: "Original files remain unchanged")
        static let exportButton = L10n.string("export.export_button", default: "Export Redacted Copy")
    }

    enum Services {
        static let fileImportGuidance = L10n.string("service.file_import.guidance", default: "Choose local PDF or image files. They remain in memory for this session only.")
        static let emptyCanvasTitle = L10n.string("service.pdf.canvas_title_empty", default: "Canvas Placeholder")
        static let ocrSummary = L10n.string("service.ocr.summary", default: "OCR is not implemented in the current phase.")
        static let barcodeSummary = L10n.string("service.barcode.summary", default: "Barcode and QR detection are placeholder-only for now.")

        static func canvasTitle(for pageTitle: String) -> String {
            L10n.formatted("service.pdf.canvas_title", default: "%@ Canvas Placeholder", pageTitle)
        }

        static func maskPreviewSummary(presetTitle: String, regionCount: Int) -> String {
            L10n.formatted(
                "service.mask.preview_summary",
                default: "%1$@ will eventually burn %2$@ region(s) into the export copy.",
                presetTitle,
                L10n.Common.regionCount(regionCount)
            )
        }

        static func exportSummary(fileCount: Int, presetTitle: String) -> String {
            L10n.formatted(
                "service.export.summary",
                default: "Prepared %1$@ file(s) for a future %2$@ export flow.",
                countText(fileCount),
                presetTitle
            )
        }
    }
}
