import Foundation

protocol FileImportService {
    func supportedFileTypes() -> [String]
    func placeholderMessage() -> String
}

struct PlaceholderFileImportService: FileImportService {
    func supportedFileTypes() -> [String] {
        ["PDF", "PNG", "JPEG", "TIFF"]
    }

    func placeholderMessage() -> String {
        "Real file picking is intentionally deferred in this phase."
    }
}
