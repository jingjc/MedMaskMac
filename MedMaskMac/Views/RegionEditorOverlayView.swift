import SwiftUI

struct RegionEditorOverlayView: View {
    let contentSize: CGSize
    let regions: [SensitiveRegion]
    let selectedRegionID: SensitiveRegion.ID?
    let onSelectRegion: (SensitiveRegion.ID?) -> Void
    let onCreateRegion: (NormalizedRect) -> Void
    let onUpdateRegion: (SensitiveRegion.ID, NormalizedRect) -> Void

    @State private var draftCreationRect: CGRect?
    @State private var moveSession: RegionMoveSession?
    @State private var resizeSession: RegionResizeSession?

    private let minimumRegionLength: CGFloat = 18
    private let handleDiameter: CGFloat = 14

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(regions) { region in
                regionView(for: region)
            }

            if let draftCreationRect {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(
                                Color.accentColor,
                                style: StrokeStyle(lineWidth: 2, dash: [8, 4])
                            )
                    )
                    .frame(width: draftCreationRect.width, height: draftCreationRect.height)
                    .position(x: draftCreationRect.midX, y: draftCreationRect.midY)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: contentSize.width, height: contentSize.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .clipped()
        .gesture(createGesture)
        .gesture(emptySpaceTapGesture)
    }

    private func regionView(for region: SensitiveRegion) -> some View {
        let rect = region.bounds.rect(in: contentSize)
        let isSelected = region.id == selectedRegionID

        return ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.black.opacity(0.10))

            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.accentColor : Color.black.opacity(0.65),
                    style: StrokeStyle(
                        lineWidth: isSelected ? 2.5 : 1.5,
                        dash: isSelected ? [] : [8, 4]
                    )
                )

            if isSelected {
                ForEach(RegionHandleCorner.allCases, id: \.self) { corner in
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: handleDiameter, height: handleDiameter)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.white, lineWidth: 2)
                        )
                        .position(handlePosition(for: corner, in: rect.size))
                        .highPriorityGesture(resizeGesture(for: region, corner: corner))
                }
            }
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
        .contentShape(Rectangle())
        .highPriorityGesture(selectRegionTapGesture(for: region))
        .applyIf(isSelected) { view in
            view.highPriorityGesture(moveGesture(for: region))
        }
    }

    private var createGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard resizeSession == nil,
                      moveSession == nil,
                      region(at: value.startLocation) == nil else {
                    return
                }

                draftCreationRect = clampedDraftRect(
                    from: value.startLocation,
                    to: value.location
                )
            }
            .onEnded { value in
                defer {
                    draftCreationRect = nil
                }

                guard region(at: value.startLocation) == nil else {
                    return
                }

                let proposedRect = clampedDraftRect(
                    from: value.startLocation,
                    to: value.location
                )

                guard isLargeEnough(proposedRect) else {
                    return
                }

                onCreateRegion(NormalizedRect(rect: proposedRect, in: contentSize))
            }
    }

    private var emptySpaceTapGesture: some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                guard region(at: value.location) == nil else {
                    return
                }

                onSelectRegion(nil)
            }
    }

    private func selectRegionTapGesture(for region: SensitiveRegion) -> some Gesture {
        SpatialTapGesture()
            .onEnded { _ in
                onSelectRegion(region.id)
            }
    }

    private func moveGesture(for region: SensitiveRegion) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if moveSession?.regionID != region.id {
                    moveSession = RegionMoveSession(
                        regionID: region.id,
                        initialRect: region.bounds.rect(in: contentSize)
                    )
                }

                guard let initialRect = moveSession?.initialRect else {
                    return
                }

                let movedRect = clampedMovingRect(
                    initialRect.offsetBy(
                        dx: value.translation.width,
                        dy: value.translation.height
                    )
                )

                onUpdateRegion(region.id, NormalizedRect(rect: movedRect, in: contentSize))
            }
            .onEnded { _ in
                moveSession = nil
            }
    }

    private func resizeGesture(for region: SensitiveRegion, corner: RegionHandleCorner) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if resizeSession?.regionID != region.id || resizeSession?.corner != corner {
                    resizeSession = RegionResizeSession(
                        regionID: region.id,
                        corner: corner,
                        initialRect: region.bounds.rect(in: contentSize)
                    )
                }

                guard let resizeSession else {
                    return
                }

                let resizedRect = resizedRect(
                    from: resizeSession.initialRect,
                    corner: corner,
                    translation: value.translation
                )

                onUpdateRegion(region.id, NormalizedRect(rect: resizedRect, in: contentSize))
            }
            .onEnded { _ in
                resizeSession = nil
            }
    }

    private func handlePosition(for corner: RegionHandleCorner, in size: CGSize) -> CGPoint {
        switch corner {
        case .topLeft:
            CGPoint(x: 0, y: 0)
        case .topRight:
            CGPoint(x: size.width, y: 0)
        case .bottomLeft:
            CGPoint(x: 0, y: size.height)
        case .bottomRight:
            CGPoint(x: size.width, y: size.height)
        }
    }

    private func clampedDraftRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        let draftRect = CGRect(
            origin: start,
            size: CGSize(width: end.x - start.x, height: end.y - start.y)
        ).standardized

        return draftRect.intersection(contentBounds)
    }

    private func clampedMovingRect(_ rect: CGRect) -> CGRect {
        let clampedX = min(max(rect.minX, contentBounds.minX), contentBounds.maxX - rect.width)
        let clampedY = min(max(rect.minY, contentBounds.minY), contentBounds.maxY - rect.height)

        return CGRect(
            x: clampedX,
            y: clampedY,
            width: rect.width,
            height: rect.height
        )
    }

    private func resizedRect(from initialRect: CGRect, corner: RegionHandleCorner, translation: CGSize) -> CGRect {
        var minX = initialRect.minX
        var minY = initialRect.minY
        var maxX = initialRect.maxX
        var maxY = initialRect.maxY

        switch corner {
        case .topLeft:
            minX = min(max(initialRect.minX + translation.width, contentBounds.minX), initialRect.maxX - minimumRegionLength)
            minY = min(max(initialRect.minY + translation.height, contentBounds.minY), initialRect.maxY - minimumRegionLength)
        case .topRight:
            maxX = max(min(initialRect.maxX + translation.width, contentBounds.maxX), initialRect.minX + minimumRegionLength)
            minY = min(max(initialRect.minY + translation.height, contentBounds.minY), initialRect.maxY - minimumRegionLength)
        case .bottomLeft:
            minX = min(max(initialRect.minX + translation.width, contentBounds.minX), initialRect.maxX - minimumRegionLength)
            maxY = max(min(initialRect.maxY + translation.height, contentBounds.maxY), initialRect.minY + minimumRegionLength)
        case .bottomRight:
            maxX = max(min(initialRect.maxX + translation.width, contentBounds.maxX), initialRect.minX + minimumRegionLength)
            maxY = max(min(initialRect.maxY + translation.height, contentBounds.maxY), initialRect.minY + minimumRegionLength)
        }

        return CGRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )
    }

    private func isLargeEnough(_ rect: CGRect) -> Bool {
        rect.width >= minimumRegionLength && rect.height >= minimumRegionLength
    }

    private func region(at point: CGPoint) -> SensitiveRegion? {
        regions.first { region in
            region.bounds.rect(in: contentSize).contains(point)
        }
    }

    private var contentBounds: CGRect {
        CGRect(origin: .zero, size: contentSize)
    }
}

private enum RegionHandleCorner: CaseIterable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
}

private struct RegionMoveSession {
    let regionID: SensitiveRegion.ID
    let initialRect: CGRect
}

private struct RegionResizeSession {
    let regionID: SensitiveRegion.ID
    let corner: RegionHandleCorner
    let initialRect: CGRect
}

private extension View {
    @ViewBuilder
    func applyIf<Content: View>(
        _ condition: Bool,
        transform: (Self) -> Content
    ) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
