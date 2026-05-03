import Foundation

protocol BarcodeService {
    var statusSummary: String { get }
}

struct PlaceholderBarcodeService: BarcodeService {
    let statusSummary = "Barcode and QR detection are placeholder-only for now."
}
