import Foundation

protocol MaskComposeService {
    func previewSummary(for preset: MaskPreset, regionCount: Int) -> String
}

struct PlaceholderMaskComposeService: MaskComposeService {
    func previewSummary(for preset: MaskPreset, regionCount: Int) -> String {
        "\(preset.title) will eventually burn \(regionCount) region(s) into the export copy."
    }
}
