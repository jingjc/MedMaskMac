import Foundation

enum FileKind: String, CaseIterable, Hashable {
    case pdf = "PDF"
    case image = "Image"
}

enum FileProcessingStatus: String, CaseIterable, Hashable {
    case imported = "Imported"
    case readyForReview = "Ready For Review"
    case needsAttention = "Needs Attention"
}

struct FileItem: Identifiable, Hashable {
    let id: UUID
    var displayName: String
    var kind: FileKind
    var status: FileProcessingStatus
    var pages: [PageItem]

    init(
        id: UUID = UUID(),
        displayName: String,
        kind: FileKind,
        status: FileProcessingStatus,
        pages: [PageItem] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.status = status
        self.pages = pages
    }

    var pageCount: Int {
        pages.count
    }
}
