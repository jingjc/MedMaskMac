import Foundation

enum MaskPreset: String, CaseIterable, Identifiable {
    case standard
    case strict
    case custom

    var id: Self { self }

    var title: String {
        switch self {
        case .standard:
            "Standard Redaction"
        case .strict:
            "Strict Redaction"
        case .custom:
            "Custom Redaction"
        }
    }

    var summary: String {
        switch self {
        case .standard:
            "Balanced default for common medical report cleanup."
        case .strict:
            "Wider masking intended for conservative review."
        case .custom:
            "Reserved for future manual redaction controls."
        }
    }
}
