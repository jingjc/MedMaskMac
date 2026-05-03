import Foundation

enum MaskPreset: String, CaseIterable, Identifiable {
    case standard
    case strict
    case custom

    var id: Self { self }

    var title: String {
        switch self {
        case .standard:
            L10n.Preset.standardTitle
        case .strict:
            L10n.Preset.strictTitle
        case .custom:
            L10n.Preset.customTitle
        }
    }

    var summary: String {
        switch self {
        case .standard:
            L10n.Preset.standardSummary
        case .strict:
            L10n.Preset.strictSummary
        case .custom:
            L10n.Preset.customSummary
        }
    }
}
