import AppKit
import CoreGraphics
import Foundation
import PDFKit
import Vision

protocol OCRService {
    var availabilitySummary: String { get }

    func candidates(
        for file: FileItem,
        page: PageItem,
        options: OCRDetectionOptions
    ) async throws -> [OCRSensitiveCandidate]
}

enum OCRServiceError: LocalizedError {
    case sourceUnavailable
    case imageUnavailable(String)
    case pdfUnavailable(String)
    case pdfPageUnavailable(Int)
    case recognitionFailed(String)

    var errorDescription: String? {
        switch self {
        case .sourceUnavailable:
            L10n.Services.ocrFailureSourceUnavailable
        case let .imageUnavailable(fileName):
            L10n.Services.ocrFailureImageUnavailable(fileName)
        case let .pdfUnavailable(fileName):
            L10n.Services.ocrFailurePDFUnavailable(fileName)
        case let .pdfPageUnavailable(pageNumber):
            L10n.Services.ocrFailurePDFPageUnavailable(pageNumber)
        case let .recognitionFailed(reason):
            L10n.Services.ocrFailureRecognitionFailed(reason)
        }
    }
}

struct DefaultOCRService: OCRService {
    let availabilitySummary = L10n.Services.ocrSummary

    func candidates(
        for file: FileItem,
        page: PageItem,
        options: OCRDetectionOptions
    ) async throws -> [OCRSensitiveCandidate] {
        let input = try makeRecognitionInput(for: file, page: page)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[OCRSensitiveCandidate], Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try Self.recognizeSensitiveText(
                        in: input.cgImage,
                        pageID: page.id,
                        options: options
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func makeRecognitionInput(
        for file: FileItem,
        page: PageItem
    ) throws -> OCRRecognitionInput {
        guard let sourceURL = file.sourceURL else {
            throw OCRServiceError.sourceUnavailable
        }

        switch file.kind {
        case .image:
            return try makeImageRecognitionInput(fileName: file.displayName, sourceURL: sourceURL)
        case .pdf:
            return try makePDFRecognitionInput(
                fileName: file.displayName,
                sourceURL: sourceURL,
                page: page
            )
        }
    }

    private func makeImageRecognitionInput(
        fileName: String,
        sourceURL: URL
    ) throws -> OCRRecognitionInput {
        try withSecurityScopedAccess(to: sourceURL) {
            guard let image = NSImage(contentsOf: sourceURL),
                  let cgImage = image.cgImageValue else {
                throw OCRServiceError.imageUnavailable(fileName)
            }

            return OCRRecognitionInput(cgImage: cgImage)
        }
    }

    private func makePDFRecognitionInput(
        fileName: String,
        sourceURL: URL,
        page: PageItem
    ) throws -> OCRRecognitionInput {
        try withSecurityScopedAccess(to: sourceURL) {
            guard let document = PDFDocument(url: sourceURL) else {
                throw OCRServiceError.pdfUnavailable(fileName)
            }

            let pageIndex = page.sourcePageIndex ?? max(0, page.pageNumber - 1)
            guard let pdfPage = document.page(at: pageIndex) else {
                throw OCRServiceError.pdfPageUnavailable(page.pageNumber)
            }

            let pageBounds = pdfPage.bounds(for: .mediaBox).standardized
            let image = pdfPage.thumbnail(of: rasterSize(for: pageBounds.size), for: .mediaBox)

            guard let cgImage = image.cgImageValue else {
                throw OCRServiceError.pdfPageUnavailable(page.pageNumber)
            }

            return OCRRecognitionInput(cgImage: cgImage)
        }
    }

    private static func recognizeSensitiveText(
        in cgImage: CGImage,
        pageID: PageItem.ID,
        options: OCRDetectionOptions
    ) throws -> [OCRSensitiveCandidate] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false

        do {
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try handler.perform([request])
        } catch {
            throw OCRServiceError.recognitionFailed(error.localizedDescription)
        }

        return buildCandidates(from: request.results ?? [], pageID: pageID, options: options)
    }

    private static func buildCandidates(
        from observations: [VNRecognizedTextObservation],
        pageID: PageItem.ID,
        options: OCRDetectionOptions
    ) -> [OCRSensitiveCandidate] {
        let textItems = recognizedTextItems(from: observations)
        let includedCategories = options.includedCategories
        var candidates: [OCRSensitiveCandidate] = []

        for item in textItems {
            for rule in targetRules where includedCategories.contains(rule.category) {
                for match in rule.matches(in: item.text) {
                    let targetRange = match.targetRange
                    guard let bounds = appNormalizedRect(
                        for: targetRange,
                        in: item.recognizedText,
                        fallbackBounds: item.boundingBox
                    ) else {
                        continue
                    }

                    let dateBinding = rule.category == .date
                        ? bindingForDateValue(
                            match: match,
                            valueBox: bounds,
                            valueItem: item,
                            textItems: textItems,
                            includedCategories: includedCategories
                        )
                        : nil
                    let category = dateBinding?.category ?? rule.category
                    guard includedCategories.contains(category) else {
                        continue
                    }

                    debugLogDateBinding(
                        valueText: match.text,
                        valueBox: bounds,
                        binding: dateBinding
                    )

                    appendCandidate(
                        OCRSensitiveCandidate(
                            pageID: pageID,
                            text: displayText(match.text, for: category),
                            category: category,
                            confidence: item.confidence,
                            boundingBox: bounds.padded(horizontal: 0.003, vertical: 0.004),
                            labelBoundingBox: dateBinding?.labelBoundingBox,
                            detectionKind: dateBinding == nil ? .directValue : .labelValue
                        ),
                        to: &candidates
                    )
                }
            }
        }

        appendLabelBasedCandidates(
            from: textItems,
            pageID: pageID,
            options: options,
            to: &candidates
        )

        return finalizedCandidates(candidates, includedCategories: includedCategories)
    }

    private static func recognizedTextItems(from observations: [VNRecognizedTextObservation]) -> [OCRTextItem] {
        observations.compactMap { observation in
            guard let recognizedText = observation.topCandidates(1).first,
                  recognizedText.confidence >= 0.30 else {
                return nil
            }

            let text = recognizedText.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return nil
            }

            return OCRTextItem(
                text: text,
                recognizedText: recognizedText,
                boundingBox: appNormalizedRect(fromVisionBounds: observation.boundingBox),
                confidence: Double(recognizedText.confidence)
            )
        }
    }

    private static func appendLabelBasedCandidates(
        from textItems: [OCRTextItem],
        pageID: PageItem.ID,
        options: OCRDetectionOptions,
        to candidates: inout [OCRSensitiveCandidate]
    ) {
        let includedCategories = options.includedCategories
        let consumedSplitNameLabelIndexes = appendStandardSplitNameLabelCandidates(
            from: textItems,
            pageID: pageID,
            options: options,
            to: &candidates
        )

        for (labelIndex, labelItem) in textItems.enumerated() {
            let wasConsumed = consumedSplitNameLabelIndexes.contains(labelIndex)

            guard !wasConsumed else {
                continue
            }

            for labelRule in labelRules where includedCategories.contains(labelRule.category) && labelRule.matches(labelItem.text) {
                guard !containsDirectValue(
                    for: labelRule.category,
                    in: labelItem.text,
                    includedCategories: includedCategories
                ) else {
                    continue
                }

                let candidate = candidateNearLabel(
                    labelRule: labelRule,
                    labelItem: labelItem,
                    textItems: textItems,
                    pageID: pageID,
                    options: options
                )
                guard let candidate else {
                    continue
                }

                appendCandidate(candidate, to: &candidates)
            }
        }
    }

    private static func appendStandardSplitNameLabelCandidates(
        from textItems: [OCRTextItem],
        pageID: PageItem.ID,
        options: OCRDetectionOptions,
        to candidates: inout [OCRSensitiveCandidate]
    ) -> Set<Int> {
        guard options.preset == .standard,
              options.includedCategories.contains(.name) else {
            return []
        }

        let groups = splitNameLabelGroups(in: textItems)
        var consumedIndexes = Set<Int>()

        for group in groups {
            if let candidate = candidateNearSplitNameLabel(
                group,
                textItems: textItems,
                pageID: pageID,
                options: options
            ) {
                appendCandidate(candidate, to: &candidates)
            }

            consumedIndexes.formUnion(group.itemIndexes)
        }

        return consumedIndexes
    }

    private static func splitNameLabelGroups(in textItems: [OCRTextItem]) -> [OCRSplitNameLabelGroup] {
        let splitItems = textItems.enumerated().compactMap { index, item -> OCRSplitNameLabelItem? in
            guard let part = splitNameLabelPart(for: item.text) else {
                return nil
            }

            return OCRSplitNameLabelItem(
                index: index,
                part: part,
                boundingBox: item.boundingBox,
                confidence: item.confidence
            )
        }

        return splitNameLabelGroups(from: splitItems)
    }

    private static func splitNameLabelGroups(from splitItems: [OCRSplitNameLabelItem]) -> [OCRSplitNameLabelGroup] {
        let surnames = splitItems
            .filter { $0.part == .surname }
            .sorted(by: splitNameLabelPrecedes)
        let givenNames = splitItems
            .filter { $0.part == .givenName }
            .sorted(by: splitNameLabelPrecedes)
        var consumedIndexes = Set<Int>()
        var groups: [OCRSplitNameLabelGroup] = []

        for surname in surnames {
            guard !consumedIndexes.contains(surname.index) else {
                continue
            }

            if let givenName = givenNames
                .filter({
                          !consumedIndexes.contains($0.index)
                              && splitNameLabelsBelongToSameField(surname.boundingBox, $0.boundingBox)
                      })
                .sorted(by: {
                          splitNameLabelGroupScore(surname.boundingBox, $0.boundingBox)
                              < splitNameLabelGroupScore(surname.boundingBox, $1.boundingBox)
                      })
                .first {
                let group = OCRSplitNameLabelGroup(
                    surnameIndex: surname.index,
                    givenNameIndex: givenName.index,
                    surnameBoundingBox: surname.boundingBox,
                    givenNameBoundingBox: givenName.boundingBox,
                    labelBoundingBox: unionRect(surname.boundingBox, givenName.boundingBox),
                    confidence: min(surname.confidence, givenName.confidence)
                )
                groups.append(group)
                consumedIndexes.insert(surname.index)
                consumedIndexes.insert(givenName.index)
            } else {
                let group = OCRSplitNameLabelGroup(
                    surnameIndex: surname.index,
                    givenNameIndex: nil,
                    surnameBoundingBox: surname.boundingBox,
                    givenNameBoundingBox: nil,
                    labelBoundingBox: surname.boundingBox,
                    confidence: surname.confidence
                )
                groups.append(group)
                consumedIndexes.insert(surname.index)
            }
        }

        return groups
    }

    private static func splitNameLabelPart(for text: String) -> OCRSplitNameLabelPart? {
        switch normalizedSplitNameLabelText(text) {
        case "姓":
            return .surname
        case "名":
            return .givenName
        default:
            return nil
        }
    }

    nonisolated private static func splitNameLabelPrecedes(
        _ left: OCRSplitNameLabelItem,
        _ right: OCRSplitNameLabelItem
    ) -> Bool {
        let leftCenterY = left.boundingBox.y + left.boundingBox.height / 2
        let rightCenterY = right.boundingBox.y + right.boundingBox.height / 2
        let sameRowThreshold = max(left.boundingBox.height, right.boundingBox.height) * 0.75
        let isSameRow = abs(leftCenterY - rightCenterY) <= max(sameRowThreshold, 0.015)

        if isSameRow, left.boundingBox.x != right.boundingBox.x {
            return left.boundingBox.x < right.boundingBox.x
        }

        if left.boundingBox.y != right.boundingBox.y {
            return left.boundingBox.y < right.boundingBox.y
        }

        return left.boundingBox.x < right.boundingBox.x
    }

    private static func splitNameLabelsBelongToSameField(
        _ left: NormalizedRect,
        _ right: NormalizedRect
    ) -> Bool {
        verticallyStackedSplitNameLabels(left, right)
            || horizontallyAdjacentSplitNameLabels(left, right)
    }

    private static func verticallyStackedSplitNameLabels(
        _ left: NormalizedRect,
        _ right: NormalizedRect
    ) -> Bool {
        let horizontalOverlap = min(left.maxX, right.maxX) - max(left.x, right.x)
        let centerDeltaX = abs(left.centerX - right.centerX)
        let verticalGap = max(0, max(left.y, right.y) - min(left.maxY, right.maxY))
        let centerDeltaY = abs(left.centerY - right.centerY)
        let rowHeight = max(left.height, right.height)
        let horizontalAligned = horizontalOverlap >= -max(left.width, right.width) * 0.35
            || centerDeltaX <= max(left.width, right.width) * 1.5 + 0.05

        return horizontalAligned
            && verticalGap <= max(rowHeight * 3.5, 0.08)
            && centerDeltaY <= max(rowHeight * 5.0, 0.14)
    }

    private static func horizontallyAdjacentSplitNameLabels(
        _ left: NormalizedRect,
        _ right: NormalizedRect
    ) -> Bool {
        let verticalOverlap = min(left.maxY, right.maxY) - max(left.y, right.y)
        let centerDeltaY = abs(left.centerY - right.centerY)
        let horizontalGap = max(0, max(left.x, right.x) - min(left.maxX, right.maxX))
        let rowHeight = max(left.height, right.height)
        let sameRow = verticalOverlap > 0
            || centerDeltaY <= max(rowHeight * 0.9, 0.02)

        return sameRow
            && horizontalGap <= max(max(left.width, right.width) * 3.0, 0.12)
    }

    private static func splitNameLabelGroupScore(
        _ left: NormalizedRect,
        _ right: NormalizedRect
    ) -> Double {
        let horizontalGap = max(0, max(left.x, right.x) - min(left.maxX, right.maxX))
        let verticalGap = max(0, max(left.y, right.y) - min(left.maxY, right.maxY))

        return horizontalGap + verticalGap + abs(left.centerX - right.centerX) + abs(left.centerY - right.centerY)
    }

    private static func unionRect(
        _ left: NormalizedRect,
        _ right: NormalizedRect
    ) -> NormalizedRect {
        let x = min(left.x, right.x)
        let y = min(left.y, right.y)
        let maxX = max(left.maxX, right.maxX)
        let maxY = max(left.maxY, right.maxY)

        return NormalizedRect(
            x: x,
            y: y,
            width: maxX - x,
            height: maxY - y
        )
        .clamped()
    }

    private static func candidateNearSplitNameLabel(
        _ group: OCRSplitNameLabelGroup,
        textItems: [OCRTextItem],
        pageID: PageItem.ID,
        options: OCRDetectionOptions
    ) -> OCRSensitiveCandidate? {
        var searchBoxes = [
            group.labelBoundingBox,
            group.surnameBoundingBox
        ]
        if let givenNameBoundingBox = group.givenNameBoundingBox {
            searchBoxes.append(givenNameBoundingBox)
        }

        if let valueItem = nearestValueItem(
            for: searchBoxes,
            category: .name,
            in: textItems,
            excluding: group.itemIndexes,
            mode: .sameLineRight
        ) ?? nearestValueItem(
            for: searchBoxes,
            category: .name,
            in: textItems,
            excluding: group.itemIndexes,
            mode: .below
        ) {
            let candidate = OCRSensitiveCandidate(
                pageID: pageID,
                text: displayText(valueItem.text, for: .name),
                category: .name,
                confidence: min(group.confidence, valueItem.confidence),
                boundingBox: valueItem.boundingBox.padded(horizontal: 0.003, vertical: 0.004),
                labelBoundingBox: group.labelBoundingBox,
                detectionKind: .labelValue
            )
            return candidate
        }

        let fallbackBox = likelyFillArea(toRightOf: group.labelBoundingBox)
        guard allowsLabelFallback(
            for: .name,
            fallbackBox: fallbackBox,
            options: options
        ) else {
            return nil
        }

        let candidate = OCRSensitiveCandidate(
            pageID: pageID,
            text: L10n.Review.ocrNoExplicitValue,
            category: .name,
            confidence: group.confidence,
            boundingBox: fallbackBox,
            labelBoundingBox: group.labelBoundingBox,
            detectionKind: .labelFallback
        )
        return candidate
    }

    private static func candidateNearLabel(
        labelRule: OCRLabelRule,
        labelItem: OCRTextItem,
        textItems: [OCRTextItem],
        pageID: PageItem.ID,
        options: OCRDetectionOptions
    ) -> OCRSensitiveCandidate? {
        if let inlineValue = inlineValueCandidate(
            labelRule: labelRule,
            labelItem: labelItem,
            pageID: pageID
        ) {
            return inlineValue
        }

        if let valueItem = nearestValueItem(
            for: labelItem,
            category: labelRule.category,
            in: textItems,
            mode: .sameLineRight
        ) ?? nearestValueItem(
            for: labelItem,
            category: labelRule.category,
            in: textItems,
            mode: .below
        ) {
            return OCRSensitiveCandidate(
                pageID: pageID,
                text: displayText(valueItem.text, for: labelRule.category),
                category: labelRule.category,
                confidence: min(labelItem.confidence, valueItem.confidence),
                boundingBox: valueItem.boundingBox.padded(horizontal: 0.003, vertical: 0.004),
                labelBoundingBox: labelItem.boundingBox,
                detectionKind: .labelValue
            )
        }

        let fallbackBox = likelyFillArea(toRightOf: labelItem.boundingBox)
        guard allowsLabelFallback(
            for: labelRule.category,
            fallbackBox: fallbackBox,
            options: options
        ) else {
            return nil
        }

        return OCRSensitiveCandidate(
            pageID: pageID,
            text: L10n.Review.ocrNoExplicitValue,
            category: labelRule.category,
            confidence: labelItem.confidence,
            boundingBox: fallbackBox,
            labelBoundingBox: labelItem.boundingBox,
            detectionKind: .labelFallback
        )
    }

    private static func inlineValueCandidate(
        labelRule: OCRLabelRule,
        labelItem: OCRTextItem,
        pageID: PageItem.ID
    ) -> OCRSensitiveCandidate? {
        guard let valueRange = labelRule.inlineValueRange(in: labelItem.text),
              let bounds = appNormalizedRect(
                  for: valueRange,
                  in: labelItem.recognizedText,
                  fallbackBounds: labelItem.boundingBox
              ) else {
            return nil
        }

        let text = (labelItem.text as NSString)
            .substring(with: valueRange)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard isLikelyValue(text, for: labelRule.category) else {
            return nil
        }

        return OCRSensitiveCandidate(
            pageID: pageID,
            text: displayText(text, for: labelRule.category),
            category: labelRule.category,
            confidence: labelItem.confidence,
            boundingBox: bounds.padded(horizontal: 0.003, vertical: 0.004),
            labelBoundingBox: labelItem.boundingBox,
            detectionKind: .labelValue
        )
    }

    private static func nearestValueItem(
        for labelItem: OCRTextItem,
        category: OCRCandidateCategory,
        in textItems: [OCRTextItem],
        mode: OCRValueSearchMode
    ) -> OCRTextItem? {
        let labelBox = labelItem.boundingBox

        return textItems
            .filter { item in
                guard item.text != labelItem.text,
                      isLikelyNeighborValue(item.text),
                      isLikelyValue(item.text, for: category),
                      item.boundingBox.width > 0.01,
                      item.boundingBox.height > 0.005 else {
                    return false
                }

                switch mode {
                case .sameLineRight:
                    let verticalCenterDelta = abs(item.boundingBox.centerY - labelBox.centerY)
                    let rightGap = item.boundingBox.x - labelBox.maxX

                    return rightGap >= -0.015
                        && rightGap <= 0.45
                        && verticalCenterDelta <= max(labelBox.height, item.boundingBox.height) * 0.75
                        && item.boundingBox.maxX <= min(labelBox.maxX + 0.62, 1)
                case .below:
                    let verticalGap = item.boundingBox.y - labelBox.maxY
                    let horizontalOverlap = min(item.boundingBox.maxX, labelBox.maxX + 0.50) - max(item.boundingBox.x, labelBox.x - 0.04)

                    return verticalGap >= -0.005
                        && verticalGap <= max(labelBox.height * 2.4, 0.08)
                        && horizontalOverlap > 0
                        && item.boundingBox.x <= min(labelBox.x + 0.45, 1)
                }
            }
            .sorted { left, right in
                valueDistance(from: labelBox, to: left.boundingBox, mode: mode)
                    < valueDistance(from: labelBox, to: right.boundingBox, mode: mode)
            }
            .first
    }

    private static func nearestValueItem(
        for labelBoxes: [NormalizedRect],
        category: OCRCandidateCategory,
        in textItems: [OCRTextItem],
        excluding excludedIndexes: Set<Int>,
        mode: OCRValueSearchMode
    ) -> OCRTextItem? {
        labelBoxes
            .compactMap { labelBox -> (item: OCRTextItem, score: Double)? in
                guard let item = nearestValueItem(
                    for: labelBox,
                    category: category,
                    in: textItems,
                    excluding: excludedIndexes,
                    mode: mode
                ) else {
                    return nil
                }

                return (item, valueDistance(from: labelBox, to: item.boundingBox, mode: mode))
            }
            .sorted { left, right in
                left.score < right.score
            }
            .first?
            .item
    }

    private static func nearestValueItem(
        for labelBox: NormalizedRect,
        category: OCRCandidateCategory,
        in textItems: [OCRTextItem],
        excluding excludedIndexes: Set<Int>,
        mode: OCRValueSearchMode
    ) -> OCRTextItem? {
        textItems
            .enumerated()
            .filter { index, item in
                guard !excludedIndexes.contains(index),
                      isLikelyNeighborValue(item.text),
                      isLikelyValue(item.text, for: category),
                      item.boundingBox.width > 0.01,
                      item.boundingBox.height > 0.005 else {
                    return false
                }

                switch mode {
                case .sameLineRight:
                    let verticalCenterDelta = abs(item.boundingBox.centerY - labelBox.centerY)
                    let rightGap = item.boundingBox.x - labelBox.maxX

                    return rightGap >= -0.015
                        && rightGap <= 0.45
                        && verticalCenterDelta <= max(labelBox.height, item.boundingBox.height) * 0.75
                        && item.boundingBox.maxX <= min(labelBox.maxX + 0.62, 1)
                case .below:
                    let verticalGap = item.boundingBox.y - labelBox.maxY
                    let horizontalOverlap = min(item.boundingBox.maxX, labelBox.maxX + 0.50) - max(item.boundingBox.x, labelBox.x - 0.04)

                    return verticalGap >= -0.005
                        && verticalGap <= max(labelBox.height * 2.4, 0.08)
                        && horizontalOverlap > 0
                        && item.boundingBox.x <= min(labelBox.x + 0.45, 1)
                }
            }
            .sorted { left, right in
                valueDistance(from: labelBox, to: left.element.boundingBox, mode: mode)
                    < valueDistance(from: labelBox, to: right.element.boundingBox, mode: mode)
            }
            .first?
            .element
    }

    private static func likelyFillArea(toRightOf labelBox: NormalizedRect) -> NormalizedRect {
        let gap = 0.015
        let x = min(labelBox.maxX + gap, 0.94)
        let width = min(max(0.18, labelBox.width * 2.2), 0.50, 0.98 - x)
        let height = min(max(labelBox.height * 1.35, 0.028), 0.06)
        let y = max(labelBox.centerY - height / 2, 0)

        return NormalizedRect(
            x: x,
            y: y,
            width: width,
            height: height
        )
        .clamped()
    }

    private static func appNormalizedRect(
        for targetRange: NSRange,
        in recognizedText: VNRecognizedText,
        fallbackBounds: NormalizedRect
    ) -> NormalizedRect? {
        guard let stringRange = Range(targetRange, in: recognizedText.string),
              let preciseBounds = try? recognizedText.boundingBox(for: stringRange)?.boundingBox else {
            return fallbackBounds
        }

        let bounds = appNormalizedRect(fromVisionBounds: preciseBounds)
        guard bounds.width > 0, bounds.height > 0 else {
            return fallbackBounds
        }

        return bounds
    }

    private static func appNormalizedRect(fromVisionBounds visionBounds: CGRect) -> NormalizedRect {
        NormalizedRect(
            x: Double(visionBounds.minX),
            y: Double(1 - visionBounds.maxY),
            width: Double(visionBounds.width),
            height: Double(visionBounds.height)
        )
        .clamped()
    }

    private static func appendCandidate(
        _ candidate: OCRSensitiveCandidate,
        to candidates: inout [OCRSensitiveCandidate]
    ) {
        guard candidate.boundingBox.width > 0, candidate.boundingBox.height > 0 else {
            return
        }

        guard !candidates.contains(where: { existingCandidate in
            candidateCategoriesOverlap(existingCandidate.category, candidate.category)
                && normalizedText(existingCandidate.text) == normalizedText(candidate.text)
                && existingCandidate.boundingBox.substantiallyOverlaps(candidate.boundingBox)
        }) else {
            return
        }

        candidates.append(candidate)
    }

    private static func finalizedCandidates(
        _ candidates: [OCRSensitiveCandidate],
        includedCategories: Set<OCRCandidateCategory>
    ) -> [OCRSensitiveCandidate] {
        let presetScopedCandidates = candidates.filter { includedCategories.contains($0.category) }
        let validatedCandidates = presetScopedCandidates.filter { candidate in
            isValidCandidateForFinalOutput(candidate)
        }
        let mergedCandidates = mergedLabelFallbackCandidates(validatedCandidates)
        let revalidatedMergedCandidates = mergedCandidates.filter { candidate in
            isValidCandidateForFinalOutput(candidate)
        }
        return deduplicatedCandidates(revalidatedMergedCandidates)
    }

    private static func isValidCandidateForFinalOutput(_ candidate: OCRSensitiveCandidate) -> Bool {
        if candidate.detectionKind == .labelFallback {
            return candidate.text == L10n.Review.ocrNoExplicitValue
        }

        return isLikelyValue(candidate.text, for: candidate.category)
    }

    private static func bindingForDateValue(
        match: OCRTargetMatch,
        valueBox: NormalizedRect,
        valueItem: OCRTextItem,
        textItems: [OCRTextItem],
        includedCategories: Set<OCRCandidateCategory>
    ) -> OCRDateBinding? {
        let labelRules = dateBindingLabelRules(includedCategories: includedCategories)

        if let sameObservationBinding = sameObservationDateBinding(
            match: match,
            valueItem: valueItem,
            labelRules: labelRules
        ) {
            return sameObservationBinding
        }

        return nearbyDateLabelBinding(
            valueBox: valueBox,
            valueItem: valueItem,
            textItems: textItems,
            labelRules: labelRules
        )
    }

    private static func sameObservationDateBinding(
        match: OCRTargetMatch,
        valueItem: OCRTextItem,
        labelRules: [OCRLabelRule]
    ) -> OCRDateBinding? {
        let nsText = valueItem.text as NSString
        guard match.targetRange.location > 0,
              match.targetRange.location <= nsText.length else {
            return nil
        }

        let prefix = nsText.substring(to: match.targetRange.location)
        return labelRules
            .compactMap { labelRule -> OCRDateBinding? in
                guard labelRule.matches(prefix) else {
                    return nil
                }

                return OCRDateBinding(
                    category: labelRule.category,
                    labelText: prefix.trimmingCharacters(in: .whitespacesAndNewlines),
                    labelBoundingBox: valueItem.boundingBox,
                    reason: "same observation prefix",
                    score: Double(dateCategoryPriority(labelRule.category))
                )
            }
            .sorted(by: dateBindingPrecedes)
            .first
    }

    private static func nearbyDateLabelBinding(
        valueBox: NormalizedRect,
        valueItem: OCRTextItem,
        textItems: [OCRTextItem],
        labelRules: [OCRLabelRule]
    ) -> OCRDateBinding? {
        textItems
            .filter { $0.text != valueItem.text || $0.boundingBox != valueItem.boundingBox }
            .flatMap { labelItem in
                labelRules.compactMap { labelRule -> OCRDateBinding? in
                    guard labelRule.matches(labelItem.text),
                          let proximity = labelValueProximity(
                              labelBox: labelItem.boundingBox,
                              valueBox: valueBox
                          ) else {
                        return nil
                    }

                    return OCRDateBinding(
                        category: labelRule.category,
                        labelText: labelItem.text,
                        labelBoundingBox: labelItem.boundingBox,
                        reason: proximity.reason,
                        score: proximity.score + Double(dateCategoryPriority(labelRule.category)) * 10
                    )
                }
            }
            .sorted(by: dateBindingPrecedes)
            .first
    }

    nonisolated private static func dateBindingPrecedes(
        _ left: OCRDateBinding,
        _ right: OCRDateBinding
    ) -> Bool {
        if dateCategoryPriority(left.category) != dateCategoryPriority(right.category) {
            return dateCategoryPriority(left.category) < dateCategoryPriority(right.category)
        }

        return left.score < right.score
    }

    private static func dateBindingLabelRules(includedCategories: Set<OCRCandidateCategory>) -> [OCRLabelRule] {
        [.birthday, .examDate]
            .filter { includedCategories.contains($0) }
            .compactMap { category in
                labelRules.first { $0.category == category }
            }
    }

    private static func labelValueProximity(
        labelBox: NormalizedRect,
        valueBox: NormalizedRect
    ) -> (reason: String, score: Double)? {
        if let sameRowScore = sameRowLeftLabelScore(labelBox: labelBox, valueBox: valueBox) {
            return ("same row left label", sameRowScore)
        }

        if let nearScore = nearbyLabelScore(labelBox: labelBox, valueBox: valueBox) {
            return ("nearby or above label", nearScore + 2)
        }

        return nil
    }

    private static func sameRowLeftLabelScore(
        labelBox: NormalizedRect,
        valueBox: NormalizedRect
    ) -> Double? {
        let rightGap = valueBox.x - labelBox.maxX
        let verticalOverlap = min(labelBox.maxY, valueBox.maxY) - max(labelBox.y, valueBox.y)
        let centerDeltaY = abs(labelBox.centerY - valueBox.centerY)
        let rowHeight = max(labelBox.height, valueBox.height)

        guard rightGap >= -0.025,
              rightGap <= 0.70,
              (verticalOverlap >= min(labelBox.height, valueBox.height) * 0.28 || centerDeltaY <= rowHeight * 0.95) else {
            return nil
        }

        return max(0, rightGap) + centerDeltaY * 2
    }

    private static func nearbyLabelScore(
        labelBox: NormalizedRect,
        valueBox: NormalizedRect
    ) -> Double? {
        let verticalGap = valueBox.y - labelBox.maxY
        let horizontalOverlap = min(labelBox.maxX, valueBox.maxX) - max(labelBox.x, valueBox.x)
        let centerDeltaX = abs(labelBox.centerX - valueBox.centerX)
        let centerDeltaY = abs(labelBox.centerY - valueBox.centerY)
        let horizontalAllowance = max(labelBox.width, valueBox.width) * 0.90 + 0.08

        guard verticalGap >= -0.015,
              verticalGap <= max(labelBox.height * 3.0, 0.10),
              (horizontalOverlap > 0 || centerDeltaX <= horizontalAllowance) else {
            return nil
        }

        return max(0, verticalGap) + centerDeltaX * 0.75 + centerDeltaY
    }

    private static func mergedLabelFallbackCandidates(_ candidates: [OCRSensitiveCandidate]) -> [OCRSensitiveCandidate] {
        var mergedCandidates = candidates
        var removedCandidateIDs = Set<OCRSensitiveCandidate.ID>()

        for fallback in candidates where fallback.detectionKind == .labelFallback {
            guard !removedCandidateIDs.contains(fallback.id),
                  let valueIndex = mergedCandidates.indices
                      .filter({ !removedCandidateIDs.contains(mergedCandidates[$0].id) })
                      .filter({ mergedCandidates[$0].detectionKind != .labelFallback })
                      .filter({ valueCandidate(mergedCandidates[$0], canFill: fallback) })
                      .sorted(by: { leftIndex, rightIndex in
                          fallbackMergeScore(value: mergedCandidates[leftIndex], fallback: fallback)
                              < fallbackMergeScore(value: mergedCandidates[rightIndex], fallback: fallback)
                      })
                      .first else {
                continue
            }

            var mergedCandidate = mergedCandidates[valueIndex]
            mergedCandidate.category = fallback.category
            mergedCandidate.text = displayText(mergedCandidate.text, for: fallback.category)
            mergedCandidate.labelBoundingBox = fallback.labelBoundingBox
            mergedCandidate.detectionKind = .labelValue
            mergedCandidate.confidence = max(mergedCandidate.confidence ?? 0, fallback.confidence ?? 0)

            debugLogFallbackMerge(
                fallback: fallback,
                value: mergedCandidates[valueIndex],
                merged: mergedCandidate
            )

            mergedCandidates[valueIndex] = mergedCandidate
            removedCandidateIDs.insert(fallback.id)
        }

        return mergedCandidates.filter { !removedCandidateIDs.contains($0.id) }
    }

    private static func valueCandidate(
        _ valueCandidate: OCRSensitiveCandidate,
        canFill fallback: OCRSensitiveCandidate
    ) -> Bool {
        guard valueCandidate.pageID == fallback.pageID,
              candidateCategoriesOverlap(valueCandidate.category, fallback.category),
              !comparableValue(for: valueCandidate).isEmpty else {
            return false
        }

        if isDateCategory(valueCandidate.category) || isDateCategory(fallback.category) {
            guard normalizedDateValue(valueCandidate.text) != nil else {
                return false
            }
        }

        if let labelBox = fallback.labelBoundingBox,
           labelValueProximity(labelBox: labelBox, valueBox: valueCandidate.boundingBox) != nil {
            return true
        }

        return fallback.boundingBox.substantiallyOverlaps(valueCandidate.boundingBox, threshold: 0.20)
            || boxesOverlapOrAreNearby(fallback.boundingBox, valueCandidate.boundingBox)
    }

    private static func fallbackMergeScore(
        value: OCRSensitiveCandidate,
        fallback: OCRSensitiveCandidate
    ) -> Double {
        if let labelBox = fallback.labelBoundingBox,
           let proximity = labelValueProximity(labelBox: labelBox, valueBox: value.boundingBox) {
            return proximity.score
        }

        let centerDeltaX = abs(value.boundingBox.centerX - fallback.boundingBox.centerX)
        let centerDeltaY = abs(value.boundingBox.centerY - fallback.boundingBox.centerY)
        return centerDeltaX + centerDeltaY * 2
    }

    private static func debugLogDateBinding(
        valueText: String,
        valueBox: NormalizedRect,
        binding: OCRDateBinding?
    ) {
        #if DEBUG
        guard let binding else {
            return
        }

        print(
            "[OCRDateBinding] value='\(valueText)' valueBox=\(debugDescription(valueBox)) "
                + "label='\(binding.labelText)' labelBox=\(debugDescription(binding.labelBoundingBox)) "
                + "category=\(binding.category.rawValue) reason='\(binding.reason)'"
        )
        #endif
    }

    private static func debugLogFallbackMerge(
        fallback: OCRSensitiveCandidate,
        value: OCRSensitiveCandidate,
        merged: OCRSensitiveCandidate
    ) {
        #if DEBUG
        guard isDateCategory(fallback.category) || isDateCategory(value.category) else {
            return
        }

        print(
            "[OCRFallbackMerge] fallback=\(fallback.category.rawValue)/'\(fallback.text)' "
                + "fallbackBox=\(debugDescription(fallback.boundingBox)) "
                + "value=\(value.category.rawValue)/'\(value.text)' valueBox=\(debugDescription(value.boundingBox)) "
                + "merged=\(merged.category.rawValue)/'\(merged.text)'"
        )
        #endif
    }

    private static func debugDescription(_ rect: NormalizedRect) -> String {
        #if DEBUG
        return String(
            format: "(x: %.4f, y: %.4f, w: %.4f, h: %.4f)",
            rect.x,
            rect.y,
            rect.width,
            rect.height
        )
        #else
        return ""
        #endif
    }

    #if DEBUG
    static func debugStandardNamePostProcessingRegressionCheck() -> Bool {
        let pageID = UUID()
        let missingValueText = L10n.Review.ocrNoExplicitValue
        let surnameLabelBox = NormalizedRect(x: 0.10, y: 0.10, width: 0.035, height: 0.018)
        let givenNameLabelBox = NormalizedRect(x: 0.10, y: 0.135, width: 0.035, height: 0.018)
        let ageValueBox = NormalizedRect(x: 0.20, y: 0.135, width: 0.050, height: 0.018)
        let splitGroups = splitNameLabelGroups(
            from: [
                OCRSplitNameLabelItem(
                    index: 0,
                    part: .surname,
                    boundingBox: surnameLabelBox,
                    confidence: 0.90
                ),
                OCRSplitNameLabelItem(
                    index: 1,
                    part: .givenName,
                    boundingBox: givenNameLabelBox,
                    confidence: 0.90
                )
            ]
        )

        let candidates = [
            OCRSensitiveCandidate(
                pageID: pageID,
                text: missingValueText,
                category: .name,
                boundingBox: likelyFillArea(toRightOf: surnameLabelBox),
                labelBoundingBox: surnameLabelBox,
                detectionKind: .labelFallback
            ),
            OCRSensitiveCandidate(
                pageID: pageID,
                text: missingValueText,
                category: .name,
                boundingBox: likelyFillArea(toRightOf: givenNameLabelBox),
                labelBoundingBox: givenNameLabelBox,
                detectionKind: .labelFallback
            ),
            OCRSensitiveCandidate(
                pageID: pageID,
                text: "30岁",
                category: .name,
                boundingBox: ageValueBox,
                labelBoundingBox: givenNameLabelBox,
                detectionKind: .labelValue
            ),
            OCRSensitiveCandidate(
                pageID: pageID,
                text: "30岁",
                category: .age,
                boundingBox: ageValueBox,
                detectionKind: .directValue
            ),
            OCRSensitiveCandidate(
                pageID: pageID,
                text: "11010119930320777X",
                category: .chineseID,
                boundingBox: NormalizedRect(x: 0.20, y: 0.20, width: 0.30, height: 0.018),
                detectionKind: .directValue
            )
        ]

        let result = finalizedCandidates(
            candidates,
            includedCategories: OCRDetectionOptions.standardCategories
        )
        let nameCandidates = result.filter { $0.category == .name }

        return splitNameLabelPart(for: "姓:") == .surname
            && splitNameLabelPart(for: "姓；") == .surname
            && splitNameLabelPart(for: "名：") == .givenName
            && splitNameLabelPart(for: "名；") == .givenName
            && !(labelRules.first { $0.category == .name }?.matches("使用协议名称：“Threshold 500Hz TB\"-打印于：2023-7-21 11:15:45") ?? true)
            && !(labelRules.first { $0.category == .name }?.matches("名称") ?? true)
            && splitGroups.count == 1
            && splitGroups.first?.itemIndexes == Set([0, 1])
            && !isLikelyValue("30岁", for: .name)
            && !isLikelyValue("30", for: .name)
            && !isLikelyValue("Age 30", for: .name)
            && !isLikelyValue("三十岁", for: .name)
            && result.contains { $0.category == .chineseID && $0.text == "11010119930320777X" }
            && nameCandidates.count == 1
            && nameCandidates.first?.text == missingValueText
            && !result.contains { $0.category == .name && $0.text == "30岁" }
            && !result.contains { $0.category == .age }
    }
    #endif

    private static func deduplicatedCandidates(_ candidates: [OCRSensitiveCandidate]) -> [OCRSensitiveCandidate] {
        var deduplicated: [OCRSensitiveCandidate] = []

        for candidate in candidates {
            guard candidate.boundingBox.width > 0, candidate.boundingBox.height > 0 else {
                continue
            }

            if let duplicateIndex = deduplicated.firstIndex(where: { areDuplicateCandidates($0, candidate) }) {
                if isPreferredCandidate(candidate, over: deduplicated[duplicateIndex]) {
                    deduplicated[duplicateIndex] = candidate
                }
            } else {
                deduplicated.append(candidate)
            }
        }

        return deduplicated
    }

    private static func areDuplicateCandidates(
        _ left: OCRSensitiveCandidate,
        _ right: OCRSensitiveCandidate
    ) -> Bool {
        guard left.pageID == right.pageID,
               candidateCategoriesOverlap(left.category, right.category) else {
            return false
        }

        let sameLocation = sameCandidateLocation(left, right)

        if left.detectionKind == .labelFallback || right.detectionKind == .labelFallback {
            guard sameLocation else {
                return false
            }

            if left.detectionKind == .labelFallback && right.detectionKind == .labelFallback {
                return comparableValue(for: left) == comparableValue(for: right)
            }

            return true
        }

        let leftValue = comparableValue(for: left)
        let rightValue = comparableValue(for: right)

        guard !leftValue.isEmpty,
              leftValue == rightValue else {
            return false
        }

        return sameLocation
    }

    private static func sameCandidateLocation(
        _ left: OCRSensitiveCandidate,
        _ right: OCRSensitiveCandidate
    ) -> Bool {
        if candidateBoxesReferToSameLocation(left.boundingBox, right.boundingBox) {
            return true
        }

        if sameNearbyLabel(left, right) || sameSplitLabelArea(left, right) {
            return true
        }

        if let leftLabel = left.labelBoundingBox,
           candidateBoxesReferToSameLocation(leftLabel, right.boundingBox) {
            return true
        }

        if let rightLabel = right.labelBoundingBox,
           candidateBoxesReferToSameLocation(left.boundingBox, rightLabel) {
            return true
        }

        return false
    }

    private static func candidateBoxesReferToSameLocation(
        _ left: NormalizedRect,
        _ right: NormalizedRect
    ) -> Bool {
        normalizedRectIoU(left, right) >= 0.18
            || left.substantiallyOverlaps(right, threshold: 0.30)
            || boxesOverlapOrAreNearby(left, right)
            || candidateBoxCentersAreClose(left, right)
    }

    private static func candidateBoxCentersAreClose(
        _ left: NormalizedRect,
        _ right: NormalizedRect
    ) -> Bool {
        let centerDeltaX = abs(left.centerX - right.centerX)
        let centerDeltaY = abs(left.centerY - right.centerY)
        let xAllowance = max(left.width, right.width) * 0.85 + 0.08
        let yAllowance = max(left.height, right.height) * 1.25 + 0.045

        return centerDeltaX <= xAllowance && centerDeltaY <= yAllowance
    }

    private static func normalizedRectIoU(
        _ left: NormalizedRect,
        _ right: NormalizedRect
    ) -> Double {
        let intersection = normalizedRectIntersectionArea(left, right)
        let union = left.width * left.height + right.width * right.height - intersection

        guard union > 0 else {
            return 0
        }

        return intersection / union
    }

    private static func normalizedRectIntersectionArea(
        _ left: NormalizedRect,
        _ right: NormalizedRect
    ) -> Double {
        let width = max(0, min(left.maxX, right.maxX) - max(left.x, right.x))
        let height = max(0, min(left.maxY, right.maxY) - max(left.y, right.y))

        return width * height
    }

    private static func isPreferredCandidate(
        _ candidate: OCRSensitiveCandidate,
        over existingCandidate: OCRSensitiveCandidate
    ) -> Bool {
        let candidateHasExplicitValue = candidate.detectionKind != .labelFallback
        let existingHasExplicitValue = existingCandidate.detectionKind != .labelFallback

        if candidateHasExplicitValue != existingHasExplicitValue {
            return candidateHasExplicitValue
        }

        if candidate.category != existingCandidate.category {
            let categories = Set([candidate.category, existingCandidate.category])

            if categories == Set([.chineseID, .documentNumber]) {
                return candidate.category == .chineseID
            }

            if isDateCategory(candidate.category),
               isDateCategory(existingCandidate.category),
               dateCategoryPriority(candidate.category) != dateCategoryPriority(existingCandidate.category) {
                return dateCategoryPriority(candidate.category) < dateCategoryPriority(existingCandidate.category)
            }

            if candidate.detectionKind == .labelValue,
               existingCandidate.detectionKind == .directValue {
                return true
            }

            if candidate.detectionKind == .directValue,
               existingCandidate.detectionKind == .labelValue {
                return false
            }
        }

        if detectionRank(candidate.detectionKind) != detectionRank(existingCandidate.detectionKind) {
            return detectionRank(candidate.detectionKind) < detectionRank(existingCandidate.detectionKind)
        }

        return (candidate.confidence ?? 0) > (existingCandidate.confidence ?? 0)
    }

    private static func detectionRank(_ kind: OCRCandidateDetectionKind) -> Int {
        switch kind {
        case .directValue:
            0
        case .labelValue:
            1
        case .labelFallback:
            2
        }
    }

    private static func comparableValue(for candidate: OCRSensitiveCandidate) -> String {
        comparableValue(candidate.text, for: candidate.category)
    }

    private static func comparableValue(
        _ text: String,
        for category: OCRCandidateCategory
    ) -> String {
        if isDateCategory(category),
           let normalizedDate = normalizedDateValue(text) {
            return normalizedDate
        }

        let normalized = normalizedOCRValueText(text)

        switch category {
        case .phone, .fax, .chineseID, .documentNumber, .medicalNumber:
            return normalized.filter { $0.isLetter || $0.isNumber }.lowercased()
        default:
            return normalized.lowercased()
        }
    }

    private static func displayText(
        _ text: String,
        for category: OCRCandidateCategory
    ) -> String {
        if isDateCategory(category),
           let normalizedDate = normalizedDateValue(text) {
            return normalizedDate
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sameNearbyLabel(
        _ left: OCRSensitiveCandidate,
        _ right: OCRSensitiveCandidate
    ) -> Bool {
        guard let leftLabel = left.labelBoundingBox,
              let rightLabel = right.labelBoundingBox else {
            return false
        }

        return boxesOverlapOrAreNearby(leftLabel, rightLabel)
    }

    private static func sameSplitLabelArea(
        _ left: OCRSensitiveCandidate,
        _ right: OCRSensitiveCandidate
    ) -> Bool {
        guard left.category == .name,
              right.category == .name,
              let leftLabel = left.labelBoundingBox,
              let rightLabel = right.labelBoundingBox else {
            return false
        }

        return splitNameLabelBoxesAreAligned(leftLabel, rightLabel)
    }

    private static func splitNameLabelBoxesAreAligned(
        _ left: NormalizedRect,
        _ right: NormalizedRect
    ) -> Bool {
        let horizontalOverlap = min(left.maxX, right.maxX) - max(left.x, right.x)
        let centerDeltaX = abs(left.centerX - right.centerX)
        let verticalGap = min(
            abs(left.maxY - right.y),
            abs(right.maxY - left.y)
        )
        let centerDeltaY = abs(left.centerY - right.centerY)
        let horizontalAligned = horizontalOverlap > 0
            || centerDeltaX <= max(left.width, right.width) * 0.90 + 0.035

        return horizontalAligned
            && verticalGap <= max(left.height, right.height) * 2.4 + 0.035
            && centerDeltaY <= max(left.height, right.height) * 4.0 + 0.06
    }

    private static func boxesOverlapOrAreNearby(
        _ left: NormalizedRect,
        _ right: NormalizedRect
    ) -> Bool {
        if left.substantiallyOverlaps(right, threshold: 0.35) {
            return true
        }

        let centerDeltaX = abs(left.centerX - right.centerX)
        let centerDeltaY = abs(left.centerY - right.centerY)
        let nearbyX = max(left.width, right.width) * 0.75 + 0.025
        let nearbyY = max(left.height, right.height) * 0.75 + 0.018

        return centerDeltaX <= nearbyX && centerDeltaY <= nearbyY
    }

    private static func allowsLabelFallback(
        for category: OCRCandidateCategory,
        fallbackBox: NormalizedRect,
        options: OCRDetectionOptions
    ) -> Bool {
        guard options.includedCategories.contains(category) else {
            return false
        }

        switch options.preset {
        case .strict:
            return true
        case .custom:
            return true
        case .standard:
            return OCRDetectionOptions.standardCategories.contains(category)
        }
    }

    private static func containsDirectValue(
        for category: OCRCandidateCategory,
        in text: String,
        includedCategories: Set<OCRCandidateCategory>
    ) -> Bool {
        targetRules
            .filter {
                includedCategories.contains($0.category)
                    && ($0.category == category
                        || ($0.category == .chineseID && category == .documentNumber)
                        || ($0.category == .documentNumber && category == .chineseID))
            }
            .contains { !$0.matches(in: text).isEmpty }
    }

    private static func candidateCategoriesOverlap(
        _ left: OCRCandidateCategory,
        _ right: OCRCandidateCategory
    ) -> Bool {
        if left == right {
            return true
        }

        let relatedPairs: [[OCRCandidateCategory]] = [
            [.chineseID, .documentNumber],
            [.phone, .fax],
            [.date, .birthday, .examDate]
        ]

        return relatedPairs.contains { Set($0).isSuperset(of: Set([left, right])) }
    }

    private static func isDateCategory(_ category: OCRCandidateCategory) -> Bool {
        category == .date || category == .birthday || category == .examDate
    }

    nonisolated private static func dateCategoryPriority(_ category: OCRCandidateCategory) -> Int {
        switch category {
        case .birthday:
            0
        case .examDate:
            1
        case .date:
            2
        default:
            3
        }
    }

    private static func isLikelyNeighborValue(_ text: String) -> Bool {
        let normalized = normalizedText(text)

        guard normalized.count >= 1,
              normalized.count <= 80,
              !isKnownLabelOnlyText(text) else {
            return false
        }

        let punctuationOnly = CharacterSet(charactersIn: "_-—:：/\\|·.。")
        if text.unicodeScalars.allSatisfy({ punctuationOnly.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) }) {
            return false
        }

        return true
    }

    private static func isLikelyValue(_ text: String, for category: OCRCandidateCategory) -> Bool {
        let normalized = normalizedText(text)

        guard !normalized.isEmpty,
              normalized.count <= 80,
              !isKnownLabelOnlyText(text) else {
            return false
        }

        switch category {
        case .sex:
            return ["男", "女", "male", "female", "m", "f"].contains(normalized)
        case .age:
            return normalized.range(of: #"^\d{1,3}(岁|y|Y|years?)?$"#, options: .regularExpression) != nil
        case .email:
            return normalized.range(of: #"(?i)^[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}$"#, options: .regularExpression) != nil
        case .phone:
            let digitCount = normalized.filter(\.isNumber).count
            return digitCount >= 7 && digitCount <= 18
        case .fax:
            let digitCount = normalized.filter(\.isNumber).count
            return digitCount >= 6 && digitCount <= 18
        case .chineseID:
            return normalized.range(of: #"^\d{17}[0-9x]$"#, options: .regularExpression) != nil
        case .documentNumber, .medicalNumber:
            return normalized.range(of: #"^[a-z0-9][a-z0-9/_]{2,31}$"#, options: .regularExpression) != nil
        case .date, .birthday, .examDate:
            let digitString = String(text.filter(\.isNumber))
            return text.range(of: #"(?<!\d)(?:19|20)\d{2}[-/.年](?:0?[1-9]|1[0-2])[-/.月](?:0?[1-9]|[12]\d|3[01])日?(?!\d)"#, options: .regularExpression) != nil
                || digitString.range(of: #"^(?:19|20)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])$"#, options: .regularExpression) != nil
        case .name:
            return isLikelyHumanNameValue(text)
        case .address:
            return normalized.count >= 2
        case .hospital:
            return normalized.count >= 2
        case .department:
            return normalized.count >= 1 && normalized.count <= 30
        case .doctor:
            return normalized.count >= 1 && normalized.count <= 20
        case .bedNumber:
            return normalized.count >= 1 && normalized.count <= 16
        case .custom, .unknown:
            return normalized.count >= 1
        }
    }

    private static func isLikelyHumanNameValue(_ text: String) -> Bool {
        let valueText = normalizedOCRValueText(text)
        let compactText = normalizedOCRLabelText(valueText)
        let digits = valueText.filter(\.isNumber)

        guard compactText.count >= 2,
              compactText.count <= 40,
              !isKnownLabelOnlyText(valueText),
              !isAgeLikeText(valueText),
              !isGenderLikeText(valueText),
              normalizedDateValue(valueText) == nil,
              !isEmailLikeText(valueText),
              !isPhoneLikeText(valueText),
              !isChineseIDLikeText(valueText),
              !isPureNumberLikeText(valueText),
              !isAddressLikeNameFalsePositive(valueText) else {
            return false
        }

        if !digits.isEmpty {
            return false
        }

        if valueText.range(of: #"^[\p{Han}·]{2,6}$"#, options: .regularExpression) != nil {
            return true
        }

        return valueText.range(
            of: #"(?i)^[A-Z][A-Z'\-]{1,24}(?:\s+[A-Z][A-Z'\-]{1,24}){0,3}$"#,
            options: .regularExpression
        ) != nil
    }

    private static func isAgeLikeText(_ text: String) -> Bool {
        let normalized = normalizedOCRValueText(text).lowercased()
        let compact = normalizedOCRLabelText(normalized)

        return compact.range(of: #"^(?:age)?\d{1,3}(?:岁|years?|y)?$"#, options: .regularExpression) != nil
            || compact.range(of: #"^[一二三四五六七八九十百零〇两]{1,4}岁$"#, options: .regularExpression) != nil
    }

    private static func isGenderLikeText(_ text: String) -> Bool {
        ["男", "女", "m", "f", "male", "female"].contains(normalizedOCRLabelText(text))
    }

    private static func isEmailLikeText(_ text: String) -> Bool {
        normalizedOCRValueText(text).range(
            of: #"(?i)^[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}$"#,
            options: .regularExpression
        ) != nil
    }

    private static func isPhoneLikeText(_ text: String) -> Bool {
        let digits = text.filter(\.isNumber)

        return digits.count >= 7 && digits.count <= 18
    }

    private static func isChineseIDLikeText(_ text: String) -> Bool {
        normalizedText(text).range(of: #"^\d{17}[0-9x]$"#, options: .regularExpression) != nil
    }

    private static func isPureNumberLikeText(_ text: String) -> Bool {
        let compact = normalizedOCRLabelText(text)

        return !compact.isEmpty && compact.allSatisfy(\.isNumber)
    }

    private static func isAddressLikeNameFalsePositive(_ text: String) -> Bool {
        let compact = normalizedOCRLabelText(text)

        return [
            "中国",
            "china",
            "地址",
            "住址",
            "家庭地址",
            "联系地址"
        ].contains(compact)
    }

    private static func valueDistance(
        from labelBox: NormalizedRect,
        to valueBox: NormalizedRect,
        mode: OCRValueSearchMode
    ) -> Double {
        switch mode {
        case .sameLineRight:
            return max(0, valueBox.x - labelBox.maxX) + abs(valueBox.centerY - labelBox.centerY) * 2
        case .below:
            return max(0, valueBox.y - labelBox.maxY) + abs(valueBox.x - labelBox.x) * 0.75
        }
    }

    private static func normalizedText(_ text: String) -> String {
        normalizedOCRText(text)
    }

    private static func isKnownLabelOnlyText(_ text: String) -> Bool {
        let trimmedText = normalizedOCRValueText(text)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":："))
        let normalized = normalizedOCRLabelText(trimmedText)

        return allOCRLabelPatterns.contains { pattern in
            normalized == normalizedOCRLabelText(pattern)
        }
    }

    private func rasterSize(for pageSize: CGSize) -> CGSize {
        let scale = 200.0 / 72.0

        return CGSize(
            width: max(pageSize.width * scale, 1),
            height: max(pageSize.height * scale, 1)
        )
    }

    private func withSecurityScopedAccess<T>(
        to url: URL,
        operation: () throws -> T
    ) throws -> T {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        return try operation()
    }
}

private struct OCRRecognitionInput {
    let cgImage: CGImage
}

private struct OCRTextItem {
    let text: String
    let recognizedText: VNRecognizedText
    let boundingBox: NormalizedRect
    let confidence: Double
}

private enum OCRSplitNameLabelPart {
    case surname
    case givenName
}

private struct OCRSplitNameLabelItem {
    let index: Int
    let part: OCRSplitNameLabelPart
    let boundingBox: NormalizedRect
    let confidence: Double
}

private struct OCRSplitNameLabelGroup {
    let surnameIndex: Int
    let givenNameIndex: Int?
    let surnameBoundingBox: NormalizedRect
    let givenNameBoundingBox: NormalizedRect?
    let labelBoundingBox: NormalizedRect
    let confidence: Double

    var itemIndexes: Set<Int> {
        var indexes = Set([surnameIndex])
        if let givenNameIndex {
            indexes.insert(givenNameIndex)
        }
        return indexes
    }
}

private struct OCRDateBinding {
    let category: OCRCandidateCategory
    let labelText: String
    let labelBoundingBox: NormalizedRect
    let reason: String
    let score: Double
}

private enum OCRValueSearchMode {
    case sameLineRight
    case below
}

private struct OCRTargetRule {
    let category: OCRCandidateCategory
    let regex: NSRegularExpression
    let captureGroup: Int

    func matches(in line: String) -> [OCRTargetMatch] {
        let fullRange = NSRange(location: 0, length: (line as NSString).length)

        return regex
            .matches(in: line, range: fullRange)
            .compactMap { result in
                let range = captureGroup == 0 ? result.range : result.range(at: captureGroup)
                guard range.location != NSNotFound, range.length > 0 else {
                    return nil
                }

                let text = (line as NSString).substring(with: range)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    return nil
                }

                return OCRTargetMatch(text: text, targetRange: range)
            }
    }
}

private struct OCRTargetMatch {
    let text: String
    let targetRange: NSRange
}

private struct OCRLabelRule {
    let category: OCRCandidateCategory
    let labelPatterns: [String]

    func matches(_ text: String) -> Bool {
        let normalized = normalizedOCRLabelText(text)

        return labelPatterns.contains { pattern in
            let normalizedPattern = normalizedOCRLabelText(pattern)
            if isSingleCharacterSplitNameLabelPattern(normalizedPattern) {
                return normalizedSplitNameLabelText(text) == normalizedPattern
            }

            return normalized.localizedCaseInsensitiveContains(normalizedPattern)
        }
    }

    func inlineValueRange(in text: String) -> NSRange? {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        for pattern in labelPatterns.sorted(by: { $0.count > $1.count }) {
            let escapedPattern = NSRegularExpression.escapedPattern(for: pattern)
            let regex = try! NSRegularExpression(
                pattern: "\(escapedPattern)\\s*[:：]?\\s*([^\\s:：]{1,80})",
                options: [.caseInsensitive]
            )

            guard let match = regex.firstMatch(in: text, range: fullRange),
                  match.range(at: 1).location != NSNotFound,
                  match.range(at: 1).length > 0 else {
                continue
            }

            return valueRangeByTrimmingTrailingLabels(from: match.range(at: 1), in: text)
        }

        return nil
    }

    private func valueRangeByTrimmingTrailingLabels(from range: NSRange, in text: String) -> NSRange {
        let nsText = text as NSString
        let capturedValue = nsText.substring(with: range)
        let earliestStop = allOCRLabelPatterns
            .compactMap { pattern -> Int? in
                guard let stopRange = capturedValue.range(of: pattern, options: [.caseInsensitive]) else {
                    return nil
                }

                return capturedValue.distance(from: capturedValue.startIndex, to: stopRange.lowerBound)
            }
            .filter { $0 > 0 }
            .min()

        guard let earliestStop, earliestStop > 0 else {
            return range
        }

        let trimmedRange = NSRange(location: range.location, length: earliestStop)
        let trimmedText = nsText.substring(with: trimmedRange).trimmingCharacters(in: .whitespacesAndNewlines)

        return trimmedText.isEmpty ? range : trimmedRange
    }
}

private let targetRules: [OCRTargetRule] = [
    OCRTargetRule(
        category: .phone,
        pattern: #"(?<!\d)(?:\+?86[-\s]?)?1[3-9]\d[-\s]?\d{4}[-\s]?\d{4}(?!\d)"#
    ),
    OCRTargetRule(
        category: .phone,
        pattern: #"(?<!\d)0\d{2,3}[-\s]?\d{7,8}(?!\d)"#
    ),
    OCRTargetRule(
        category: .chineseID,
        pattern: #"(?<![0-9A-Za-z])\d{6}(?:18|19|20)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])\d{3}[0-9Xx](?![0-9A-Za-z])"#
    ),
    OCRTargetRule(
        category: .email,
        pattern: #"(?i)[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#
    ),
    OCRTargetRule(
        category: .date,
        pattern: #"(?<!\d)(?:19|20)\d{2}[-/.年](?:0?[1-9]|1[0-2])[-/.月](?:0?[1-9]|[12]\d|3[01])日?(?!\d)"#
    ),
    OCRTargetRule(
        category: .documentNumber,
        pattern: #"(?:身份证号|身份证号码|证件号|证件号码|身份证|ID\s*Number|ID\s*No\.?|Identification\s*Number)\s*[:：]?\s*([A-Za-z0-9][A-Za-z0-9\-_/]{3,31})"#,
        captureGroup: 1
    ),
    OCRTargetRule(
        category: .medicalNumber,
        pattern: #"(?:门诊号|住院号|病案号|病历号|样本号|检查号|报告号|申请单号|就诊号|患者编号|条码号|门诊号码|住院号码|病案号码|病历号码|样本编号|检查编号|报告编号|申请编号|医疗记录号|标本号|检验号|报告单号|Patient\s*ID|Medical\s*Record\s*Number|MRN|Accession\s*Number|Sample\s*ID|Report\s*ID)\s*[:：]?\s*([A-Za-z0-9][A-Za-z0-9\-_/]{2,31})"#,
        captureGroup: 1
    ),
    OCRTargetRule(
        category: .name,
        pattern: #"(?:患者姓名|病人姓名|受检者|受检人|测试者|被检者|姓名|名字|Name|Patient\s*Name|Subject\s*Name)\s*[:：]?\s*([一-龥·]{2,4})(?=\s|性别|年龄|科室|床号|门诊号|住院号|病案号|样本号|检验号|报告单号|条码号|$)"#,
        captureGroup: 1
    )
]

private let nameLabelPatterns: [String] = [
    "姓名",
    "名字",
    "患者姓名",
    "病人姓名",
    "受检者",
    "受检人",
    "测试者",
    "被检者",
    "姓 名",
    "姓：",
    "姓:",
    "名：",
    "名:",
    "Name",
    "Patient Name",
    "Subject Name"
]

private let phoneLabelPatterns: [String] = [
    "手机号",
    "手机号码",
    "手机",
    "电话",
    "联系电话",
    "电话号码",
    "联系方式",
    "手机号/电话",
    "电话/手机",
    "Tel",
    "Telephone",
    "Phone",
    "Mobile",
    "Contact Number"
]

private let idNumberLabelPatterns: [String] = [
    "身份证号",
    "身份证号码",
    "证件号",
    "证件号码",
    "身份证",
    "ID Number",
    "ID No.",
    "Identification Number"
]

private let medicalNumberLabelPatterns: [String] = [
    "门诊号",
    "住院号",
    "病案号",
    "病历号",
    "样本号",
    "检查号",
    "报告号",
    "申请单号",
    "就诊号",
    "患者编号",
    "条码号",
    "门诊号码",
    "住院号码",
    "病案号码",
    "病历号码",
    "样本编号",
    "检查编号",
    "报告编号",
    "申请编号",
    "Patient ID",
    "Medical Record Number",
    "MRN",
    "Accession Number",
    "Sample ID",
    "Report ID",
    "标本号",
    "检验号",
    "报告单号"
]

private let birthdayLabelPatterns: [String] = [
    "生日",
    "出生日期",
    "出生年月",
    "出生年月日",
    "出生时间",
    "出生",
    "出生日",
    "出生日期/年龄",
    "出生年月/年龄",
    "出生资料",
    "出生信息",
    "患者生日",
    "病人生日",
    "受检者生日",
    "受检人生日",
    "儿童生日",
    "婴儿生日",
    "新生儿生日",
    "生 日",
    "出 生 日 期",
    "出生 日期",
    "出生年月 日",
    "出生年月日：",
    "生日：",
    "出生日期：",
    "DOB",
    "D.O.B.",
    "Date of Birth",
    "Birth Date",
    "Birthday",
    "Birthdate",
    "Birth",
    "Patient DOB",
    "Patient Date of Birth",
    "Subject DOB",
    "Subject Date of Birth"
]

private let examDateLabelPatterns: [String] = [
    "检查日期",
    "测试日期",
    "检测日期",
    "采样日期",
    "采集日期",
    "报告日期",
    "送检日期",
    "申请日期",
    "就诊日期",
    "门诊日期",
    "入院日期",
    "出院日期",
    "打印日期",
    "审核日期",
    "发布日期",
    "诊断日期",
    "检验日期",
    "检验时间",
    "检查时间",
    "报告时间",
    "采样时间",
    "接收时间",
    "送检时间",
    "Exam Date",
    "Examination Date",
    "Test Date",
    "Collection Date",
    "Sample Date",
    "Sampling Date",
    "Report Date",
    "Request Date",
    "Visit Date",
    "Admission Date",
    "Discharge Date",
    "Print Date",
    "Review Date",
    "Release Date",
    "Diagnosis Date",
    "Inspection Date",
    "Detection Date",
    "Collection Time",
    "Report Time",
    "Test Time"
]

private let labelRules: [OCRLabelRule] = [
    OCRLabelRule(category: .address, labelPatterns: ["地址", "住址", "家庭地址", "联系地址"]),
    OCRLabelRule(category: .phone, labelPatterns: phoneLabelPatterns),
    OCRLabelRule(category: .name, labelPatterns: nameLabelPatterns),
    OCRLabelRule(category: .sex, labelPatterns: ["性别"]),
    OCRLabelRule(category: .age, labelPatterns: ["年龄"]),
    OCRLabelRule(category: .chineseID, labelPatterns: idNumberLabelPatterns),
    OCRLabelRule(category: .medicalNumber, labelPatterns: medicalNumberLabelPatterns),
    OCRLabelRule(category: .birthday, labelPatterns: birthdayLabelPatterns),
    OCRLabelRule(category: .examDate, labelPatterns: examDateLabelPatterns),
    OCRLabelRule(category: .fax, labelPatterns: ["传真"]),
    OCRLabelRule(category: .email, labelPatterns: ["电子邮件", "邮箱", "Email", "E-mail"]),
    OCRLabelRule(category: .hospital, labelPatterns: ["医院名称", "医院", "医疗机构", "机构名称"]),
    OCRLabelRule(category: .department, labelPatterns: ["科室", "科别", "病区", "就诊科室", "申请科室", "检查科室"]),
    OCRLabelRule(category: .doctor, labelPatterns: ["医生", "医师", "申请医生", "审核医生", "报告医生", "送检医生", "检查医生"]),
    OCRLabelRule(category: .bedNumber, labelPatterns: ["床号", "床位号", "病床号"])
]

private let allOCRLabelPatterns = labelRules.flatMap(\.labelPatterns)

private extension OCRTargetRule {
    init(
        category: OCRCandidateCategory,
        pattern: String,
        captureGroup: Int = 0
    ) {
        self.category = category
        self.regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        self.captureGroup = captureGroup
    }
}

private extension NormalizedRect {
    var maxX: Double {
        x + width
    }

    var maxY: Double {
        y + height
    }

    var centerY: Double {
        y + height / 2
    }

    var centerX: Double {
        x + width / 2
    }
}

private func normalizedOCRText(_ text: String) -> String {
    text.replacingOccurrences(of: " ", with: "")
        .replacingOccurrences(of: "-", with: "")
        .replacingOccurrences(of: "_", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
}

private func normalizedOCRLabelText(_ text: String) -> String {
    normalizedOCRValueText(text)
        .replacingOccurrences(of: " ", with: "")
        .replacingOccurrences(of: "-", with: "")
        .replacingOccurrences(of: "_", with: "")
        .replacingOccurrences(of: ".", with: "")
        .replacingOccurrences(of: "/", with: "")
        .replacingOccurrences(of: "\\", with: "")
        .replacingOccurrences(of: ":", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
}

private func normalizedSplitNameLabelText(_ text: String) -> String {
    normalizedOCRValueText(text)
        .replacingOccurrences(of: " ", with: "")
        .replacingOccurrences(of: ":", with: "")
        .replacingOccurrences(of: "：", with: "")
        .replacingOccurrences(of: ";", with: "")
        .replacingOccurrences(of: "；", with: "")
        .replacingOccurrences(of: "﹔", with: "")
        .replacingOccurrences(of: "｡", with: "")
        .replacingOccurrences(of: "。", with: "")
        .replacingOccurrences(of: "．", with: "")
        .replacingOccurrences(of: ".", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
}

private func isSingleCharacterSplitNameLabelPattern(_ normalizedPattern: String) -> Bool {
    normalizedPattern == "姓" || normalizedPattern == "名"
}

private func normalizedOCRValueText(_ text: String) -> String {
    let halfWidthText = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
    let normalizedPunctuation = halfWidthText
        .replacingOccurrences(of: "：", with: ":")
        .replacingOccurrences(of: "－", with: "-")
        .replacingOccurrences(of: "—", with: "-")
        .replacingOccurrences(of: "–", with: "-")
        .replacingOccurrences(of: "／", with: "/")
        .replacingOccurrences(of: "。", with: ".")

    return normalizedPunctuation
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func normalizedDateValue(_ text: String) -> String? {
    let normalizedText = normalizedOCRValueText(text)
    let nsText = normalizedText as NSString
    let fullRange = NSRange(location: 0, length: nsText.length)
    let pattern = #"(?<!\d)((?:19|20)\d{2})\s*[-/.年]\s*(\d{1,2})\s*[-/.月]\s*(\d{1,2})\s*日?(?!\d)"#

    if let regex = try? NSRegularExpression(pattern: pattern),
       let match = regex.firstMatch(in: normalizedText, range: fullRange),
       match.numberOfRanges == 4,
       let year = Int(nsText.substring(with: match.range(at: 1))),
       let month = Int(nsText.substring(with: match.range(at: 2))),
       let day = Int(nsText.substring(with: match.range(at: 3))),
       isValidDateParts(year: year, month: month, day: day) {
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    let digits = normalizedText.filter(\.isNumber)
    guard digits.count == 8,
          let year = Int(String(digits.prefix(4))),
          let month = Int(String(digits.dropFirst(4).prefix(2))),
          let day = Int(String(digits.suffix(2))),
          isValidDateParts(year: year, month: month, day: day) else {
        return nil
    }

    return String(format: "%04d-%02d-%02d", year, month, day)
}

private func isValidDateParts(year: Int, month: Int, day: Int) -> Bool {
    (1900...2099).contains(year) && (1...12).contains(month) && (1...31).contains(day)
}
