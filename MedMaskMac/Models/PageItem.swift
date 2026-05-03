import Foundation

enum PageProcessingStatus: String, CaseIterable, Hashable {
    case pendingDetection = "Pending Detection"
    case readyForReview = "Ready For Review"
    case maskedPreview = "Masked Preview"
}

struct PageItem: Identifiable, Hashable {
    let id: UUID
    var pageNumber: Int
    var status: PageProcessingStatus
    var sensitiveRegions: [SensitiveRegion]

    init(
        id: UUID = UUID(),
        pageNumber: Int,
        status: PageProcessingStatus,
        sensitiveRegions: [SensitiveRegion] = []
    ) {
        self.id = id
        self.pageNumber = pageNumber
        self.status = status
        self.sensitiveRegions = sensitiveRegions
    }

    var title: String {
        "Page \(pageNumber)"
    }
}
