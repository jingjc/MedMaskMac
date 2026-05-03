import Foundation

protocol OCRService {
    var availabilitySummary: String { get }
}

struct PlaceholderOCRService: OCRService {
    let availabilitySummary = "OCR is not implemented in the current phase."
}
