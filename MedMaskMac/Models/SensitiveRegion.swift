import Foundation

struct NormalizedRect: Hashable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

enum SensitiveRegionKind: String, CaseIterable, Hashable {
    case name = "Name"
    case phoneNumber = "Phone Number"
    case idNumber = "ID Number"
    case barcode = "Barcode / QR"
    case freeform = "Freeform"
}

struct SensitiveRegion: Identifiable, Hashable {
    let id: UUID
    var kind: SensitiveRegionKind
    var bounds: NormalizedRect
    var isMasked: Bool

    init(
        id: UUID = UUID(),
        kind: SensitiveRegionKind,
        bounds: NormalizedRect,
        isMasked: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.bounds = bounds
        self.isMasked = isMasked
    }
}
