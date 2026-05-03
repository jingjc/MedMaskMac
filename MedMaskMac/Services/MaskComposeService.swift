import Foundation

protocol MaskComposeService {
    func previewSummary(for preset: MaskPreset, regionCount: Int) -> String
}

struct PlaceholderMaskComposeService: MaskComposeService {
    func previewSummary(for preset: MaskPreset, regionCount: Int) -> String {
        L10n.Services.maskPreviewSummary(presetTitle: preset.title, regionCount: regionCount)
    }
}
