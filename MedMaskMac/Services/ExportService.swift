import Foundation

protocol ExportService {
    func exportSummary(for files: [FileItem], preset: MaskPreset) -> String
}

struct PlaceholderExportService: ExportService {
    func exportSummary(for files: [FileItem], preset: MaskPreset) -> String {
        "Prepared \(files.count) file(s) for a future \(preset.title.lowercased()) export flow."
    }
}
