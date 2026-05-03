import Foundation

protocol OCRService {
    var availabilitySummary: String { get }
}

struct PlaceholderOCRService: OCRService {
    let availabilitySummary = L10n.Services.ocrSummary
}
