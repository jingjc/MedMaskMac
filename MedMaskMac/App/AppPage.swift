import Foundation

enum AppPage: String, CaseIterable, Identifiable {
    case `import`
    case reviewEdit
    case exportSummary

    var id: Self { self }

    var title: String {
        switch self {
        case .import:
            "Import"
        case .reviewEdit:
            "Review / Edit"
        case .exportSummary:
            "Export Summary"
        }
    }

    var subtitle: String {
        switch self {
        case .import:
            "Prepare PDFs or images for a local redaction pass."
        case .reviewEdit:
            "Inspect page structure before masking and export are implemented."
        case .exportSummary:
            "Review the shell of the final redaction handoff."
        }
    }
}
