import Foundation

protocol ExportService {
    func exportSummary(for files: [FileItem], preset: MaskPreset) -> String
}

struct PlaceholderExportService: ExportService {
    func exportSummary(for files: [FileItem], preset: MaskPreset) -> String {
        L10n.Services.exportSummary(fileCount: files.count, presetTitle: preset.title)
    }
}
