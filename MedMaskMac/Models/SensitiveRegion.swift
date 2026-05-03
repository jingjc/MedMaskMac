import CoreGraphics
import Foundation

struct NormalizedRect: Hashable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    static let zero = NormalizedRect(x: 0, y: 0, width: 0, height: 0)

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(rect: CGRect, in size: CGSize) {
        guard size.width > 0, size.height > 0 else {
            self = .zero
            return
        }

        let bounds = CGRect(origin: .zero, size: size)
        let clampedRect = rect.standardized.intersection(bounds)

        self.init(
            x: Double(clampedRect.minX / size.width),
            y: Double(clampedRect.minY / size.height),
            width: Double(clampedRect.width / size.width),
            height: Double(clampedRect.height / size.height)
        )

        self = self.clamped()
    }

    func rect(in size: CGSize) -> CGRect {
        CGRect(
            x: x * size.width,
            y: y * size.height,
            width: width * size.width,
            height: height * size.height
        )
    }

    func clamped() -> NormalizedRect {
        let clampedX = x.clamped(to: 0...1)
        let clampedY = y.clamped(to: 0...1)
        let clampedWidth = width.clamped(to: 0...(1 - clampedX))
        let clampedHeight = height.clamped(to: 0...(1 - clampedY))

        return NormalizedRect(
            x: clampedX,
            y: clampedY,
            width: clampedWidth,
            height: clampedHeight
        )
    }
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

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
