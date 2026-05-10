import AppKit
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
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

#if PRIVATE_OCR_REGRESSION
enum PrivateOCRRegressionClassification: String {
    case valueExtractionPassed
    case regionFallbackPassed
    case failed
}

struct PrivateOCRRegressionCandidateSummary {
    let category: String
    let detectionKind: String
    let boundingBox: String
    let redactedValue: String
}

struct PrivateOCRRegressionCheckResult {
    let name: String
    let passed: Bool
}

struct PrivateOCRRegressionFixtureResult {
    let classification: PrivateOCRRegressionClassification
    let totalCandidateCount: Int
    let candidateSummaries: [PrivateOCRRegressionCandidateSummary]
    let splitNameGroupCount: Int
    let pairedSplitNameGroupCount: Int
    let expectedNameFillArea: String?
    let nameFillCoverageRatio: Double
    let exactlyOneNameCandidate: Bool
    let testerOperatorContaminationDetected: Bool
    let standardScopeClean: Bool
    let idSourcePresentInOCR: Bool
    let idCandidateExistsIfPresent: Bool
    let checks: [PrivateOCRRegressionCheckResult]

    var passed: Bool {
        classification != .failed && checks.allSatisfy(\.passed)
    }
}
#endif

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
            guard let cgImage = Self.makeOCRImageCGImage(from: sourceURL)
                ?? NSImage(contentsOf: sourceURL)?.cgImageValue else {
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
        let observations: [VNRecognizedTextObservation]
        do {
            observations = try recognizedTextObservations(in: cgImage)
        } catch {
            throw OCRServiceError.recognitionFailed(error.localizedDescription)
        }

        return buildCandidates(
            from: observations,
            pageID: pageID,
            options: options,
            context: OCRProcessingContext(sourceImage: cgImage)
        )
    }

    private static func buildCandidates(
        from observations: [VNRecognizedTextObservation],
        pageID: PageItem.ID,
        options: OCRDetectionOptions,
        context: OCRProcessingContext = .empty
    ) -> [OCRSensitiveCandidate] {
        let textItems = recognizedTextItems(from: observations)

        return buildCandidates(from: textItems, pageID: pageID, options: options, context: context)
    }

    private static func buildCandidates(
        from textItems: [OCRTextItem],
        pageID: PageItem.ID,
        options: OCRDetectionOptions,
        context: OCRProcessingContext = .empty
    ) -> [OCRSensitiveCandidate] {
        let includedCategories = options.includedCategories
        var candidates: [OCRSensitiveCandidate] = []

        for item in textItems {
            for rule in targetRules where includedCategories.contains(rule.category) {
                for match in rule.matches(in: item.text) {
                    guard !isForbiddenStandardNameTargetMatch(
                        rule: rule,
                        match: match,
                        in: item.text,
                        options: options
                    ) else {
                        continue
                    }

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
            context: context,
            to: &candidates
        )

        return finalizedCandidates(candidates, includedCategories: includedCategories)
    }

    private static func recognizedTextObservations(in cgImage: CGImage) throws -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        return request.results ?? []
    }

    private static func makeOCRImageCGImage(from sourceURL: URL) -> CGImage? {
        guard let imageSource = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
            return nil
        }

        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 2400
        ] as CFDictionary

        let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options)
            ?? CGImageSourceCreateImageAtIndex(imageSource, 0, nil)

        guard let image else {
            return nil
        }

        return normalizedRGBImage(image)
    }

    private static func normalizedRGBImage(_ image: CGImage) -> CGImage? {
        guard image.width > 0, image.height > 0 else {
            return nil
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
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
        context: OCRProcessingContext,
        to candidates: inout [OCRSensitiveCandidate]
    ) {
        let includedCategories = options.includedCategories
        let consumedSplitNameLabelIndexes = appendStandardSplitNameLabelCandidates(
            from: textItems,
            pageID: pageID,
            options: options,
            context: context,
            to: &candidates
        )

        for (labelIndex, labelItem) in textItems.enumerated() {
            let wasConsumed = consumedSplitNameLabelIndexes.contains(labelIndex)

            guard !wasConsumed else {
                continue
            }

            for labelRule in labelRules where includedCategories.contains(labelRule.category) && labelRule.matches(labelItem.text) {
                guard !isForbiddenStandardNameLabelMatch(
                    labelRule: labelRule,
                    labelText: labelItem.text,
                    options: options
                ) else {
                    continue
                }

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
        context: OCRProcessingContext,
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
                options: options,
                context: context
            ) {
                appendCandidate(candidate, to: &candidates)
            }

            consumedIndexes.formUnion(group.itemIndexes)
        }

        return consumedIndexes
    }

    private static func splitNameLabelGroups(in textItems: [OCRTextItem]) -> [OCRSplitNameLabelGroup] {
        let splitItems = textItems.enumerated().compactMap { index, item -> OCRSplitNameLabelItem? in
            guard let match = splitNameLabelMatch(for: item) else {
                return nil
            }

            return OCRSplitNameLabelItem(
                index: index,
                part: match.part,
                boundingBox: item.boundingBox,
                confidence: item.confidence,
                inlineValue: match.inlineValue
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
                    confidence: min(surname.confidence, givenName.confidence),
                    inlineValues: [surname.inlineValue, givenName.inlineValue].compactMap(\.self)
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
                    confidence: surname.confidence,
                    inlineValues: [surname.inlineValue].compactMap(\.self)
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

    private static func splitNameLabelMatch(
        for item: OCRTextItem
    ) -> (part: OCRSplitNameLabelPart, inlineValue: OCRSplitNameInlineValue?)? {
        if let part = splitNameLabelPart(for: item.text) {
            return (part, nil)
        }

        if let part = emptyFillSplitNameLabelPart(for: item.text) {
            return (part, nil)
        }

        guard let inlineMatch = splitNameInlineValue(in: item) else {
            return nil
        }

        return (inlineMatch.part, inlineMatch.value)
    }

    private static func emptyFillSplitNameLabelPart(for text: String) -> OCRSplitNameLabelPart? {
        let normalizedText = normalizedOCRValueText(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let labelIndex = normalizedText.firstIndex(where: { !$0.isWhitespace }) else {
            return nil
        }

        let part: OCRSplitNameLabelPart
        switch normalizedText[labelIndex] {
        case "姓":
            part = .surname
        case "名":
            part = .givenName
        default:
            return nil
        }

        let remainderStart = normalizedText.index(after: labelIndex)
        let remainder = String(normalizedText[remainderStart...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainder.isEmpty else {
            return part
        }

        return remainder.allSatisfy(isSplitNameEmptyFillCharacter) ? part : nil
    }

    nonisolated private static func isSplitNameEmptyFillCharacter(_ character: Character) -> Bool {
        if isSplitNameInlineSeparator(character) {
            return true
        }

        return ["_", "-", "—", "–", "－", ".", "．", "·", "•", "|", "/", "\\", "﹕", "∶"].contains(character)
    }

    private static func splitNameInlineValue(
        in item: OCRTextItem
    ) -> (part: OCRSplitNameLabelPart, value: OCRSplitNameInlineValue)? {
        let text = item.text
        guard let labelIndex = text.firstIndex(where: { !$0.isWhitespace }) else {
            return nil
        }

        let part: OCRSplitNameLabelPart
        switch text[labelIndex] {
        case "姓":
            part = .surname
        case "名":
            part = .givenName
        default:
            return nil
        }

        var valueStart = text.index(after: labelIndex)
        var sawSeparator = false
        while valueStart < text.endIndex {
            let character = text[valueStart]
            if character.isWhitespace {
                valueStart = text.index(after: valueStart)
                continue
            }

            guard isSplitNameInlineSeparator(character) else {
                break
            }

            sawSeparator = true
            valueStart = text.index(after: valueStart)
        }

        guard sawSeparator, valueStart < text.endIndex else {
            return nil
        }

        let rawValue = String(text[valueStart...])
        let normalizedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedValue.isEmpty,
              likelyHumanNameDisplayValue(from: normalizedValue) != nil
                  || likelySplitNamePartComponent(from: normalizedValue, for: part) != nil else {
            return nil
        }

        let valueRange = NSRange(valueStart..<text.endIndex, in: text)
        let valueBox = appNormalizedRect(
            for: valueRange,
            in: item.recognizedText,
            fallbackBounds: item.boundingBox
        ) ?? item.boundingBox

        return (
            part,
            OCRSplitNameInlineValue(
                part: part,
                text: normalizedValue,
                boundingBox: valueBox,
                confidence: item.confidence
            )
        )
    }

    nonisolated private static func isSplitNameInlineSeparator(_ character: Character) -> Bool {
        [":", "：", "﹕", "∶", ";", "；", "﹔"].contains(character)
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
        options: OCRDetectionOptions,
        context: OCRProcessingContext
    ) -> OCRSensitiveCandidate? {
        if let inlineCandidate = inlineSplitNameValueCandidate(group, pageID: pageID) {
            return inlineCandidate
        }

        if let componentCandidate = splitNameComponentValueCandidate(
            group,
            textItems: textItems,
            pageID: pageID
        ) {
            return componentCandidate
        }

        if let roiCandidate = splitNameROIValueCandidate(
            group,
            pageID: pageID,
            context: context
        ) {
            return roiCandidate
        }

        let fallbackBox = likelySplitNameFillArea(for: group)
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

    private static func inlineSplitNameValueCandidate(
        _ group: OCRSplitNameLabelGroup,
        pageID: PageItem.ID
    ) -> OCRSensitiveCandidate? {
        guard !group.inlineValues.isEmpty else {
            return nil
        }

        if let combinedCandidate = combinedSplitNameComponentCandidate(
            from: group.inlineValues.compactMap { inlineValue in
                guard let component = likelySplitNamePartComponent(from: inlineValue.text, for: inlineValue.part) else {
                    return nil
                }

                return OCRSplitNameComponentValue(
                    part: inlineValue.part,
                    text: component,
                    boundingBox: inlineValue.boundingBox,
                    confidence: inlineValue.confidence,
                    sourceIndex: nil
                )
            },
            group: group,
            pageID: pageID
        ) {
            return combinedCandidate
        }

        return nil
    }

    private static func splitNameComponentValueCandidate(
        _ group: OCRSplitNameLabelGroup,
        textItems: [OCRTextItem],
        pageID: PageItem.ID
    ) -> OCRSensitiveCandidate? {
        guard let givenNameBoundingBox = group.givenNameBoundingBox else {
            return nil
        }

        guard let surname = splitNameComponentValue(
            for: .surname,
            labelBox: group.surnameBoundingBox,
            textItems: textItems,
            excluding: group.itemIndexes
        ) else {
            return nil
        }

        var excludedIndexes = group.itemIndexes
        if let sourceIndex = surname.sourceIndex {
            excludedIndexes.insert(sourceIndex)
        }

        guard let givenName = splitNameComponentValue(
            for: .givenName,
            labelBox: givenNameBoundingBox,
            textItems: textItems,
            excluding: excludedIndexes
        ) else {
            return nil
        }

        return combinedSplitNameComponentCandidate(
            from: [surname, givenName],
            group: group,
            pageID: pageID
        )
    }

    private static func splitNameComponentValue(
        for part: OCRSplitNameLabelPart,
        labelBox: NormalizedRect,
        textItems: [OCRTextItem],
        excluding excludedIndexes: Set<Int>
    ) -> OCRSplitNameComponentValue? {
        splitNameComponentValue(
            for: part,
            labelBox: labelBox,
            textItems: textItems,
            excluding: excludedIndexes,
            mode: .sameLineRight
        )
    }

    private static func splitNameComponentValue(
        for part: OCRSplitNameLabelPart,
        labelBox: NormalizedRect,
        textItems: [OCRTextItem],
        excluding excludedIndexes: Set<Int>,
        mode: OCRValueSearchMode
    ) -> OCRSplitNameComponentValue? {
        textItems
            .enumerated()
            .compactMap { index, item -> OCRSplitNameComponentValue? in
                guard !excludedIndexes.contains(index),
                      isLikelyNeighborValue(item.text),
                      let component = likelySplitNamePartComponent(from: item.text, for: part),
                      item.boundingBox.width > 0.005,
                      item.boundingBox.height > 0.005,
                      splitNameComponentValueIsInExpectedArea(
                          item.boundingBox,
                          labelBox: labelBox,
                          mode: mode
                      ) else {
                    return nil
                }

                return OCRSplitNameComponentValue(
                    part: part,
                    text: component,
                    boundingBox: item.boundingBox,
                    confidence: item.confidence,
                    sourceIndex: index
                )
            }
            .sorted { left, right in
                valueDistance(from: labelBox, to: left.boundingBox, mode: mode)
                    < valueDistance(from: labelBox, to: right.boundingBox, mode: mode)
            }
            .first
    }

    private static func splitNameComponentValueIsInExpectedArea(
        _ valueBox: NormalizedRect,
        labelBox: NormalizedRect,
        mode: OCRValueSearchMode
    ) -> Bool {
        switch mode {
        case .sameLineRight:
            let verticalCenterDelta = abs(valueBox.centerY - labelBox.centerY)
            let rightGap = valueBox.x - labelBox.maxX

            return rightGap >= -0.015
                && rightGap <= 0.32
                && verticalCenterDelta <= max(labelBox.height, valueBox.height) * 0.80
                && valueBox.maxX <= min(labelBox.maxX + 0.46, 1)
        case .below:
            return false
        }
    }

    private static func combinedSplitNameComponentCandidate(
        from components: [OCRSplitNameComponentValue],
        group: OCRSplitNameLabelGroup,
        pageID: PageItem.ID
    ) -> OCRSensitiveCandidate? {
        guard let surname = components.first(where: { $0.part == .surname }),
              let givenName = components.first(where: { $0.part == .givenName }) else {
            return nil
        }

        if let surnameIndex = surname.sourceIndex,
           let givenNameIndex = givenName.sourceIndex,
           surnameIndex == givenNameIndex {
            return nil
        }

        let combinedValue = surname.text + givenName.text
        guard let nameValue = likelyHumanNameDisplayValue(from: combinedValue) else {
            return nil
        }

        let combinedBox = unionRect(surname.boundingBox, givenName.boundingBox)

        return OCRSensitiveCandidate(
            pageID: pageID,
            text: nameValue,
            category: .name,
            confidence: min(group.confidence, surname.confidence, givenName.confidence),
            boundingBox: combinedBox.padded(horizontal: 0.003, vertical: 0.004),
            labelBoundingBox: group.labelBoundingBox,
            detectionKind: .labelValue
        )
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
            options: options,
            pageID: pageID
        ) {
            return inlineValue
        }

        if labelRule.category == .name,
           options.preset == .standard,
           labelRule.inlineValueRange(
               in: labelItem.text,
               allowsNameWithSpaces: true
           ) != nil {
            return nil
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

        let fallbackBox = labelRule.category == .name && options.preset == .standard
            ? likelyNameFillArea(toRightOf: labelItem.boundingBox)
            : likelyFillArea(toRightOf: labelItem.boundingBox)
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
        options: OCRDetectionOptions,
        pageID: PageItem.ID
    ) -> OCRSensitiveCandidate? {
        guard let valueRange = labelRule.inlineValueRange(
            in: labelItem.text,
            allowsNameWithSpaces: options.preset == .standard
        ),
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

    private static func likelyNameFillArea(toRightOf labelBox: NormalizedRect) -> NormalizedRect {
        let gap = 0.015
        let x = min(labelBox.maxX + gap, 0.94)
        let width = min(max(0.22, labelBox.width * 2.8), 0.56, 0.98 - x)
        let height = min(max(labelBox.height * 1.45, 0.032), 0.07)
        let y = max(labelBox.centerY - height / 2, 0)

        return NormalizedRect(
            x: x,
            y: y,
            width: width,
            height: height
        )
        .clamped()
    }

    private static func likelySplitNameFillArea(for group: OCRSplitNameLabelGroup) -> NormalizedRect {
        let labelBoxes = [group.surnameBoundingBox, group.givenNameBoundingBox].compactMap(\.self)
        let labelBox = group.labelBoundingBox
        let rightEdge = labelBoxes.map(\.maxX).max() ?? labelBox.maxX
        let rowHeight = labelBoxes.map(\.height).max() ?? labelBox.height
        let hasGivenNameRow = group.givenNameBoundingBox != nil
        let gap = 0.015
        let x = min(rightEdge + gap, 0.94)
        let width = min(max(0.24, labelBox.width * 2.8), 0.58, 0.98 - x)
        let y = max(labelBox.y - max(rowHeight * 0.35, 0.006), 0)
        let height = hasGivenNameRow
            ? min(max(labelBox.height + rowHeight * 0.70, 0.036), 0.16, 1 - y)
            : min(max(rowHeight * 4.6, 0.085), 0.12, 1 - y)

        return NormalizedRect(
            x: x,
            y: y,
            width: width,
            height: height
        )
        .clamped()
    }

    private static func splitNameROIValueCandidate(
        _ group: OCRSplitNameLabelGroup,
        pageID: PageItem.ID,
        context: OCRProcessingContext
    ) -> OCRSensitiveCandidate? {
        guard let sourceImage = context.sourceImage,
              let givenNameBoundingBox = group.givenNameBoundingBox else {
            return nil
        }

        guard let surname = splitNameRowOCRComponentValue(
            for: .surname,
            labelBox: group.surnameBoundingBox,
            sourceImage: sourceImage
        ) else {
            return nil
        }

        guard let givenName = splitNameRowOCRComponentValue(
            for: .givenName,
            labelBox: givenNameBoundingBox,
            sourceImage: sourceImage
        ) else {
            return nil
        }

        return combinedSplitNameComponentCandidate(
            from: [surname, givenName],
            group: group,
            pageID: pageID
        )
    }

    private static func splitNameRowOCRComponentValue(
        for part: OCRSplitNameLabelPart,
        labelBox: NormalizedRect,
        sourceImage: CGImage
    ) -> OCRSplitNameComponentValue? {
        let rowBox = splitNameRowOCRRegion(toRightOf: labelBox)
        guard let croppedImage = croppedImage(sourceImage, to: rowBox) else {
            return nil
        }

        if let value = splitNameRowOCRComponentValue(
            for: part,
            in: croppedImage,
            rowBox: rowBox,
            labelBox: labelBox
        ) {
            return value
        }

        guard let scaledImage = scaledImage(croppedImage, scale: 3) else {
            return nil
        }

        return splitNameRowOCRComponentValue(
            for: part,
            in: scaledImage,
            rowBox: rowBox,
            labelBox: labelBox
        )
    }

    private static func splitNameRowOCRComponentValue(
        for part: OCRSplitNameLabelPart,
        in rowImage: CGImage,
        rowBox: NormalizedRect,
        labelBox: NormalizedRect
    ) -> OCRSplitNameComponentValue? {
        guard let observations = try? recognizedTextObservations(in: rowImage) else {
            return nil
        }

        let rowItems = recognizedTextItems(from: observations)
            .map { item in
                OCRTextItem(
                    text: item.text,
                    recognizedText: nil,
                    boundingBox: pageRect(from: item.boundingBox, in: rowBox),
                    confidence: item.confidence
                )
            }

        return splitNameComponentValue(
            for: part,
            labelBox: labelBox,
            textItems: rowItems,
            excluding: []
        )
    }

    private static func splitNameRowOCRRegion(toRightOf labelBox: NormalizedRect) -> NormalizedRect {
        let gap = max(0.008, labelBox.height * 0.30)
        let x = min(labelBox.maxX + gap, 0.96)
        let height = min(max(labelBox.height * 2.0, 0.028), 0.060)
        let y = max(labelBox.centerY - height / 2, 0)
        let width = min(max(0.22, labelBox.width * 5.0), 0.38, 0.98 - x)

        return NormalizedRect(
            x: x,
            y: y,
            width: width,
            height: min(height, 1 - y)
        )
        .clamped()
    }

    private static func pageRect(from localRect: NormalizedRect, in roiBox: NormalizedRect) -> NormalizedRect {
        NormalizedRect(
            x: roiBox.x + localRect.x * roiBox.width,
            y: roiBox.y + localRect.y * roiBox.height,
            width: localRect.width * roiBox.width,
            height: localRect.height * roiBox.height
        )
        .clamped()
    }

    private static func croppedImage(_ sourceImage: CGImage, to normalizedRect: NormalizedRect) -> CGImage? {
        let imageBounds = CGRect(x: 0, y: 0, width: sourceImage.width, height: sourceImage.height)
        let cropRect = CGRect(
            x: normalizedRect.x * Double(sourceImage.width),
            y: normalizedRect.y * Double(sourceImage.height),
            width: normalizedRect.width * Double(sourceImage.width),
            height: normalizedRect.height * Double(sourceImage.height)
        )
        .integral
        .intersection(imageBounds)

        guard cropRect.width >= 2, cropRect.height >= 2 else {
            return nil
        }

        return sourceImage.cropping(to: cropRect)
    }

    private static func scaledImage(_ sourceImage: CGImage, scale: Int) -> CGImage? {
        guard scale > 1 else {
            return sourceImage
        }

        let width = sourceImage.width * scale
        let height = sourceImage.height * scale
        let colorSpace = sourceImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(sourceImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func appNormalizedRect(
        for targetRange: NSRange,
        in recognizedText: VNRecognizedText?,
        fallbackBounds: NormalizedRect
    ) -> NormalizedRect? {
        guard let recognizedText,
              let stringRange = Range(targetRange, in: recognizedText.string),
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
    struct DebugStandardNameRegressionCaseResult {
        let caseName: String
        let passed: Bool
        let details: String
    }

    static func debugStandardNamePostProcessingRegressionCheck() -> Bool {
        debugStandardNamePostProcessingRegressionResults().allSatisfy(\.passed)
    }

    static func debugStandardNamePostProcessingRegressionResults() -> [DebugStandardNameRegressionCaseResult] {
        let pageID = UUID()
        let surnameLabelBox = NormalizedRect(x: 0.10, y: 0.10, width: 0.040, height: 0.018)
        let givenNameLabelBox = NormalizedRect(x: 0.10, y: 0.140, width: 0.040, height: 0.018)
        let caseA = debugStandardCandidates(
            pageID: pageID,
            textItems: [
                debugTextItem("姓:", box: surnameLabelBox),
                debugTextItem("靖", box: NormalizedRect(x: 0.18, y: 0.10, width: 0.026, height: 0.018)),
                debugTextItem("名:", box: givenNameLabelBox),
                debugTextItem("加成", box: NormalizedRect(x: 0.18, y: 0.14, width: 0.052, height: 0.018)),
                debugTextItem("地址:", box: NormalizedRect(x: 0.10, y: 0.18, width: 0.060, height: 0.018)),
                debugTextItem("测试者: 金品", box: NormalizedRect(x: 0.10, y: 0.26, width: 0.180, height: 0.018))
            ]
        )
        let caseB = debugStandardCandidates(
            pageID: pageID,
            textItems: [
                debugTextItem("姓:", box: surnameLabelBox),
                debugTextItem("张", box: NormalizedRect(x: 0.18, y: 0.10, width: 0.026, height: 0.018)),
                debugTextItem("名:", box: givenNameLabelBox),
                debugTextItem("三", box: NormalizedRect(x: 0.18, y: 0.14, width: 0.026, height: 0.018))
            ]
        )
        let caseC = debugStandardCandidates(
            pageID: pageID,
            textItems: [
                debugTextItem("姓: 欧阳", box: NormalizedRect(x: 0.10, y: 0.10, width: 0.140, height: 0.018)),
                debugTextItem("名: 小明", box: NormalizedRect(x: 0.10, y: 0.14, width: 0.140, height: 0.018))
            ]
        )
        let caseD = debugStandardCandidates(
            pageID: pageID,
            textItems: [
                debugTextItem("测试者: 金品", box: NormalizedRect(x: 0.10, y: 0.10, width: 0.180, height: 0.018))
            ]
        )
        let caseE = debugStandardCandidates(
            pageID: pageID,
            textItems: [
                debugTextItem("姓名：张三", box: NormalizedRect(x: 0.10, y: 0.10, width: 0.160, height: 0.018))
            ]
        )
        let caseF = debugStandardCandidates(
            pageID: pageID,
            textItems: [
                debugTextItem("使用协议名称：“Threshold 500Hz TB”-打印于：2023-7-21 11:15:45", box: NormalizedRect(x: 0.10, y: 0.10, width: 0.620, height: 0.018))
            ]
        )
        let caseG = debugStandardCandidates(
            pageID: pageID,
            textItems: [
                debugTextItem("姓名：30岁", box: NormalizedRect(x: 0.10, y: 0.10, width: 0.130, height: 0.018))
            ]
        )

        return [
            debugRegressionResult(
                "Case A current split-name contamination",
                candidates: caseA,
                passed: caseA.filter { $0.category == .name }.count == 1
                    && debugContains(caseA, category: .name, text: "靖加成")
                    && !debugCandidateSummary(caseA).contains("加靖金金品")
                    && !debugCandidateSummary(caseA).contains("靖加成金品")
                    && !debugCandidateSummary(caseA).contains("金品")
            ),
            debugRegressionResult(
                "Case B split-name order check",
                candidates: caseB,
                passed: caseB.filter { $0.category == .name }.count == 1
                    && debugContains(caseB, category: .name, text: "张三")
                    && !debugContains(caseB, category: .name, text: "三张")
            ),
            debugRegressionResult(
                "Case C compound surname",
                candidates: caseC,
                passed: caseC.filter { $0.category == .name }.count == 1
                    && debugContains(caseC, category: .name, text: "欧阳小明")
            ),
            debugRegressionResult(
                "Case D tester only excluded",
                candidates: caseD,
                passed: caseD.filter { $0.category == .name }.isEmpty
            ),
            debugRegressionResult(
                "Case E combined name layout",
                candidates: caseE,
                passed: caseE.filter { $0.category == .name }.count == 1
                    && debugContains(caseE, category: .name, text: "张三")
            ),
            debugRegressionResult(
                "Case F false positive long text",
                candidates: caseF,
                passed: caseF.filter { $0.category == .name }.isEmpty
                    && !(labelRules.first { $0.category == .name }?.matches("使用协议名称：“Threshold 500Hz TB\"-打印于：2023-7-21 11:15:45") ?? true)
                    && !(labelRules.first { $0.category == .name }?.matches("名称") ?? true)
            ),
            debugRegressionResult(
                "Case G invalid value blocked",
                candidates: caseG,
                passed: !debugContains(caseG, category: .name, text: "30岁")
                    && !isLikelyValue("30岁", for: .name)
                    && !isLikelyValue("30", for: .name)
                    && !isLikelyValue("Age 30", for: .name)
                    && !isLikelyValue("三十岁", for: .name)
                    && !isLikelyValue("男", for: .name)
                    && !isLikelyValue("女", for: .name)
                    && !isLikelyValue("M", for: .name)
                    && !isLikelyValue("F", for: .name)
                    && !isLikelyValue("中国", for: .name)
                    && !isLikelyValue("420117199303207538", for: .name)
                    && !isLikelyValue("test@example.com", for: .name)
                    && !isLikelyValue("13800138000", for: .name)
                    && !isLikelyValue("1993-03-20", for: .name)
                    && !isLikelyValue("项目名称", for: .name)
                    && !isLikelyValue("Threshold", for: .name)
                    && !isLikelyValue("ABR", for: .name)
                    && !isLikelyValue("测试者", for: .name)
                    && !isLikelyValue("检查者", for: .name)
                    && !isLikelyValue("操作者", for: .name)
                    && !isLikelyValue("医生", for: .name)
                    && !isLikelyValue("技师", for: .name)
            )
        ]
    }

    private static func debugTextItem(_ text: String, box: NormalizedRect) -> OCRTextItem {
        OCRTextItem(text: text, recognizedText: nil, boundingBox: box, confidence: 0.90)
    }

    private static func debugStandardCandidates(
        pageID: PageItem.ID,
        textItems: [OCRTextItem],
        sourceImage: CGImage? = nil
    ) -> [OCRSensitiveCandidate] {
        buildCandidates(
            from: textItems,
            pageID: pageID,
            options: OCRDetectionOptions(preset: .standard, customFields: []),
            context: OCRProcessingContext(sourceImage: sourceImage)
        )
    }

    private static func debugRegressionResult(
        _ caseName: String,
        candidates: [OCRSensitiveCandidate],
        passed: Bool,
        detailsSuffix: String? = nil
    ) -> DebugStandardNameRegressionCaseResult {
        let details = [debugCandidateSummary(candidates), detailsSuffix]
            .compactMap { $0 }
            .joined(separator: "; ")

        return DebugStandardNameRegressionCaseResult(
            caseName: caseName,
            passed: passed,
            details: details
        )
    }

    static func debugSyntheticSplitNamePipelineImageURL() -> URL? {
        let url = URL(fileURLWithPath: "/private/tmp/MedMaskSyntheticSplitName.jpg")
        guard let image = debugSyntheticSplitNamePipelineImage(),
              let destination = CGImageDestinationCreateWithURL(
                  url as CFURL,
                  UTType.jpeg.identifier as CFString,
                  1,
                  nil
              ) else {
            return nil
        }

        let options = [
            kCGImageDestinationLossyCompressionQuality: 0.95
        ] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        return url
    }

    private static func debugSyntheticSplitNameROIImage(includeName: Bool) -> CGImage? {
        debugSyntheticSplitNameImage(includeLabels: false, includeName: includeName)
    }

    private static func debugSyntheticSplitNamePipelineImage() -> CGImage? {
        debugSyntheticSplitNameImage(includeLabels: true, includeName: true)
    }

    private static func debugSyntheticSplitNameImage(includeLabels: Bool, includeName: Bool) -> CGImage? {
        let size = CGSize(width: 1200, height: 800)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()

        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 54, weight: .regular),
            .foregroundColor: NSColor.black
        ]
        let valueAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 66, weight: .medium),
            .foregroundColor: NSColor.black
        ]

        if includeLabels {
            ("姓：" as NSString).draw(at: CGPoint(x: 120, y: 800 - 145), withAttributes: labelAttributes)
            ("名：" as NSString).draw(at: CGPoint(x: 120, y: 800 - 245), withAttributes: labelAttributes)
        }

        if includeName {
            ("张三" as NSString).draw(at: CGPoint(x: 280, y: 800 - 188), withAttributes: valueAttributes)
        }

        image.unlockFocus()
        return image.cgImageValue
    }

    private static func debugHasSingleNameFallback(
        _ candidates: [OCRSensitiveCandidate],
        missingValueText: String,
        minimumWidth: Double,
        minimumHeight: Double = 0.030
    ) -> Bool {
        let nameCandidates = candidates.filter { $0.category == .name }
        guard nameCandidates.count == 1,
              let nameCandidate = nameCandidates.first,
              nameCandidate.text == missingValueText,
              nameCandidate.detectionKind == .labelFallback else {
            return false
        }

        return nameCandidate.boundingBox.width >= minimumWidth
            && nameCandidate.boundingBox.height >= minimumHeight
    }

    private static func debugContains(
        _ candidates: [OCRSensitiveCandidate],
        category: OCRCandidateCategory,
        text: String
    ) -> Bool {
        candidates.contains { $0.category == category && $0.text == text }
    }

    private static func debugCandidateSummary(_ candidates: [OCRSensitiveCandidate]) -> String {
        if candidates.isEmpty {
            return "[]"
        }

        return candidates
            .map { "\($0.category.rawValue)/\($0.text)/\($0.detectionKind.rawValue)" }
            .joined(separator: ", ")
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
        let asciiDigits = valueText.unicodeScalars.filter { (48...57).contains($0.value) }

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
              !isForbiddenNameText(valueText),
              !isAddressLikeNameFalsePositive(valueText) else {
            return false
        }

        if !asciiDigits.isEmpty {
            return false
        }

        if compactText.range(of: #"^[一-龥·]{2,6}$"#, options: .regularExpression) != nil {
            return true
        }

        return valueText.range(
            of: #"(?i)^[A-Z][A-Z'\-]{1,24}(?:\s+[A-Z][A-Z'\-]{1,24}){0,3}$"#,
            options: .regularExpression
        ) != nil
    }

    private static func likelyHumanNameDisplayValue(from text: String) -> String? {
        guard !isStandardForbiddenNameLabelText(text) else {
            return nil
        }

        for match in targetRules.filter({ $0.category == .name }).flatMap({ $0.matches(in: text) }) {
            if let value = likelyHumanNameDisplayValueFromRawValue(match.text) {
                return value
            }
        }

        if let nameLabelRule = labelRules.first(where: { $0.category == .name }),
           let valueRange = nameLabelRule.inlineValueRange(in: text, allowsNameWithSpaces: true) {
            let inlineText = (text as NSString)
                .substring(with: valueRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = likelyHumanNameDisplayValueFromRawValue(inlineText) {
                return value
            }
        }

        return likelyHumanNameDisplayValueFromRawValue(text)
    }

    private static func likelyHumanNameDisplayValueFromRawValue(_ text: String) -> String? {
        let valueText = normalizedOCRValueText(text)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ":：;；,，.。\"'“”‘’()（）[]【】")))
        let compactText = normalizedOCRLabelText(valueText)

        guard isLikelyHumanNameValue(valueText),
              !compactText.isEmpty else {
            return nil
        }

        if compactText.range(of: #"^[一-龥·]{2,6}$"#, options: .regularExpression) != nil {
            return compactText
        }

        return valueText
    }

    private static func likelyHumanNameComponent(from text: String) -> String? {
        let compactText = normalizedOCRLabelText(text)
        let isSingleChineseNameComponent = compactText.range(
            of: #"^[一-龥·]$"#,
            options: .regularExpression
        ) != nil

        guard compactText.range(of: #"^[一-龥·]{1,3}$"#, options: .regularExpression) != nil,
              splitNameLabelPart(for: text) == nil,
              !isKnownLabelOnlyText(text),
              !isForbiddenNameText(text),
              (!isAgeLikeText(text) || isSingleChineseNameComponent),
              !isGenderLikeText(text),
              !isAddressLikeNameFalsePositive(text) else {
            return nil
        }

        return compactText
    }

    private static func likelySplitNamePartComponent(
        from text: String,
        for part: OCRSplitNameLabelPart
    ) -> String? {
        let valueText = normalizedOCRValueText(text)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ":：;；,，.。\"'“”‘’()（）[]【】")))
        let compactText = normalizedOCRLabelText(valueText)
        let isSingleChineseNameComponent = compactText.range(
            of: #"^[一-龥]$"#,
            options: .regularExpression
        ) != nil

        guard !compactText.isEmpty,
              splitNameLabelPart(for: valueText) == nil,
              !isKnownLabelOnlyText(valueText),
              !isForbiddenNameText(valueText),
              !containsForbiddenSplitNamePartText(valueText),
              (!isAgeLikeText(valueText) || isSingleChineseNameComponent),
              !isGenderLikeText(valueText),
              normalizedDateValue(valueText) == nil,
              !isEmailLikeText(valueText),
              !isPhoneLikeText(valueText),
              !isChineseIDLikeText(valueText),
              (!isPureNumberLikeText(valueText) || isSingleChineseNameComponent),
              !isAddressLikeNameFalsePositive(valueText) else {
            return nil
        }

        switch part {
        case .surname:
            guard compactText.range(of: #"^[一-龥]{1,2}$"#, options: .regularExpression) != nil else {
                return nil
            }
        case .givenName:
            guard compactText.range(of: #"^[一-龥]{1,4}$"#, options: .regularExpression) != nil else {
                return nil
            }
        }

        return compactText
    }

    private static func containsForbiddenSplitNamePartText(_ text: String) -> Bool {
        let compact = normalizedOCRLabelText(text)
        guard !compact.isEmpty else {
            return false
        }

        return splitNamePartForbiddenTexts.contains { forbiddenText in
            let forbidden = normalizedOCRLabelText(forbiddenText)
            return !forbidden.isEmpty && compact.contains(forbidden)
        }
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

    private static func isForbiddenNameText(_ text: String) -> Bool {
        isForbiddenNameValueText(text)
    }

    private static func isForbiddenStandardNameTargetMatch(
        rule: OCRTargetRule,
        match: OCRTargetMatch,
        in text: String,
        options: OCRDetectionOptions
    ) -> Bool {
        guard options.preset == .standard,
              rule.category == .name else {
            return false
        }

        let nsText = text as NSString
        let prefixLength = max(0, min(match.targetRange.location, nsText.length))
        let prefix = nsText.substring(to: prefixLength)

        return isStandardForbiddenNameLabelText(prefix)
    }

    private static func isForbiddenStandardNameLabelMatch(
        labelRule: OCRLabelRule,
        labelText: String,
        options: OCRDetectionOptions
    ) -> Bool {
        options.preset == .standard
            && labelRule.category == .name
            && isStandardForbiddenNameLabelText(labelText)
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

    #if PRIVATE_OCR_REGRESSION
    static func privateOCRRegressionFixtureResult(
        fixtureURL: URL
    ) async throws -> PrivateOCRRegressionFixtureResult {
        let page = PageItem(
            pageNumber: 1,
            sourcePageIndex: 0,
            status: .readyForReview
        )
        let file = FileItem(
            displayName: fixtureURL.lastPathComponent,
            sourceURL: fixtureURL,
            kind: .image,
            status: .readyForReview,
            pages: [page]
        )
        let options = OCRDetectionOptions(preset: .standard, customFields: [])
        let service = DefaultOCRService()
        let candidates = try await service.candidates(for: file, page: page, options: options)
        let input = try service.makeImageRecognitionInput(
            fileName: fixtureURL.lastPathComponent,
            sourceURL: fixtureURL
        )
        let textItems = try Self.recognizedTextItems(
            from: Self.recognizedTextObservations(in: input.cgImage)
        )

        return privateOCRRegressionFixtureResult(
            candidates: candidates,
            textItems: textItems
        )
    }

    static func privateOCRRegressionSyntheticCaseResults() -> [PrivateOCRRegressionCheckResult] {
        let pageID = UUID()
        let surnameLabelBox = NormalizedRect(x: 0.10, y: 0.10, width: 0.040, height: 0.018)
        let givenNameLabelBox = NormalizedRect(x: 0.10, y: 0.140, width: 0.040, height: 0.018)
        let caseB = privateOCRRegressionStandardCandidates(
            pageID: pageID,
            textItems: [
                privateOCRRegressionTextItem("姓:", box: surnameLabelBox),
                privateOCRRegressionTextItem("张", box: NormalizedRect(x: 0.18, y: 0.10, width: 0.026, height: 0.018)),
                privateOCRRegressionTextItem("名:", box: givenNameLabelBox),
                privateOCRRegressionTextItem("三", box: NormalizedRect(x: 0.18, y: 0.14, width: 0.026, height: 0.018))
            ]
        )
        let caseC = privateOCRRegressionStandardCandidates(
            pageID: pageID,
            textItems: [
                privateOCRRegressionTextItem("姓: 欧阳", box: NormalizedRect(x: 0.10, y: 0.10, width: 0.140, height: 0.018)),
                privateOCRRegressionTextItem("名: 小明", box: NormalizedRect(x: 0.10, y: 0.14, width: 0.140, height: 0.018))
            ]
        )
        let caseD = privateOCRRegressionStandardCandidates(
            pageID: pageID,
            textItems: [
                privateOCRRegressionTextItem("测试者: 李四", box: NormalizedRect(x: 0.10, y: 0.10, width: 0.180, height: 0.018))
            ]
        )
        let caseE = privateOCRRegressionStandardCandidates(
            pageID: pageID,
            textItems: [
                privateOCRRegressionTextItem("姓名：张三", box: NormalizedRect(x: 0.10, y: 0.10, width: 0.160, height: 0.018))
            ]
        )
        let caseF = privateOCRRegressionStandardCandidates(
            pageID: pageID,
            textItems: [
                privateOCRRegressionTextItem("使用协议名称：“Threshold 500Hz TB”-打印于：2023-7-21", box: NormalizedRect(x: 0.10, y: 0.10, width: 0.620, height: 0.018))
            ]
        )
        let caseG = privateOCRRegressionStandardCandidates(
            pageID: pageID,
            textItems: [
                privateOCRRegressionTextItem("姓名：30岁", box: NormalizedRect(x: 0.10, y: 0.10, width: 0.130, height: 0.018))
            ]
        )

        return [
            PrivateOCRRegressionCheckResult(
                name: "Case B split name normal order",
                passed: privateOCRRegressionHasSingleName(caseB, equalTo: "张三")
                    && !privateOCRRegressionHasName(caseB, equalTo: "三张")
            ),
            PrivateOCRRegressionCheckResult(
                name: "Case C split name compound surname",
                passed: privateOCRRegressionHasSingleName(caseC, equalTo: "欧阳小明")
            ),
            PrivateOCRRegressionCheckResult(
                name: "Case D tester only excluded",
                passed: caseD.filter { $0.category == .name }.isEmpty
            ),
            PrivateOCRRegressionCheckResult(
                name: "Case E combined name layout",
                passed: privateOCRRegressionHasSingleName(caseE, equalTo: "张三")
            ),
            PrivateOCRRegressionCheckResult(
                name: "Case F false positive long text",
                passed: caseF.filter { $0.category == .name }.isEmpty
                    && !(labelRules.first { $0.category == .name }?.matches("使用协议名称：“Threshold 500Hz TB”-打印于：2023-7-21") ?? true)
                    && !(labelRules.first { $0.category == .name }?.matches("名称") ?? true)
            ),
            PrivateOCRRegressionCheckResult(
                name: "Case G invalid name value",
                passed: caseG.filter { $0.category == .name }.isEmpty
                    && !isLikelyValue("30岁", for: .name)
                    && !isLikelyValue("30", for: .name)
                    && !isLikelyValue("Age 30", for: .name)
                    && !isLikelyValue("三十岁", for: .name)
                    && !isLikelyValue("男", for: .name)
                    && !isLikelyValue("女", for: .name)
                    && !isLikelyValue("M", for: .name)
                    && !isLikelyValue("F", for: .name)
                    && !isLikelyValue("420117199303207538", for: .name)
                    && !isLikelyValue("test@example.com", for: .name)
                    && !isLikelyValue("13800138000", for: .name)
                    && !isLikelyValue("1993-03-20", for: .name)
                    && !isLikelyValue("中国", for: .name)
                    && !isLikelyValue("地址", for: .name)
                    && !isLikelyValue("性别", for: .name)
                    && !isLikelyValue("年龄", for: .name)
                    && !isLikelyValue("生日", for: .name)
                    && !isLikelyValue("证件号", for: .name)
                    && !isLikelyValue("测试者", for: .name)
                    && !isLikelyValue("检查者", for: .name)
                    && !isLikelyValue("操作者", for: .name)
                    && !isLikelyValue("医生", for: .name)
                    && !isLikelyValue("技师", for: .name)
                    && !isLikelyValue("使用协议名称", for: .name)
                    && !isLikelyValue("Threshold", for: .name)
                    && !isLikelyValue("ABR", for: .name)
            )
        ]
    }

    private static func privateOCRRegressionFixtureResult(
        candidates: [OCRSensitiveCandidate],
        textItems: [OCRTextItem]
    ) -> PrivateOCRRegressionFixtureResult {
        let nameCandidates = candidates.filter { $0.category == .name }
        let nonPatientRows = privateOCRRegressionRows(
            matching: standardNonPatientNameLabelTexts,
            in: textItems
        )
        let forbiddenNameRows = privateOCRRegressionRows(
            matching: forbiddenNameLabelTexts,
            in: textItems
        )
        let splitNameGroups = splitNameLabelGroups(in: textItems)
        let pairedSplitNameGroups = splitNameGroups
            .filter { $0.givenNameBoundingBox != nil }
        let splitGroup = (pairedSplitNameGroups.isEmpty ? splitNameGroups : pairedSplitNameGroups)
            .sorted { $0.labelBoundingBox.y < $1.labelBoundingBox.y }
            .first
        let nameCandidate = nameCandidates.first
        let exactlyOneNameCandidate = nameCandidates.count == 1
        let duplicateNameCandidatesAbsent = nameCandidates.count <= 1
        let testerOperatorContaminationDetected = nameCandidates.contains { candidate in
            privateOCRRegressionCandidate(candidate, isContaminatedBy: nonPatientRows)
        }
        let nameFromForbiddenLabelDetected = nameCandidates.contains { candidate in
            privateOCRRegressionCandidate(candidate, isSourcedFrom: forbiddenNameRows)
                || isForbiddenNameValueText(candidate.text)
        }
        let standardScopeClean = candidates.allSatisfy { candidate in
            OCRDetectionOptions.standardCategories.contains(candidate.category)
        }
        let idSourcePresentInOCR = privateOCRRegressionIDSourcePresent(in: textItems)
        let idCandidateExists = candidates.contains {
            $0.category == .chineseID || $0.category == .documentNumber
        }
        let idCandidateExistsIfPresent = !idSourcePresentInOCR || idCandidateExists
        let expectedFillArea = splitGroup.map(likelySplitNameFillArea)
        let nameBoxCoversFillArea = nameCandidate.map { candidate in
            privateOCRRegressionNameCandidateCoversSplitFillArea(candidate, splitGroup: splitGroup)
        } ?? false
        let nameFillCoverageRatio = if let nameCandidate,
                                       let expectedFillArea {
            privateOCRRegressionCoverageRatio(nameCandidate.boundingBox, expectedFillArea)
        } else {
            0.0
        }
        let nameBoxExcludesTesterRows = nameCandidate.map { candidate in
            !nonPatientRows.contains { row in
                privateOCRRegressionRect(candidate.boundingBox, reachesRow: row.rowBox)
                    || candidate.labelBoundingBox.map { privateOCRRegressionRect($0, reachesRow: row.labelBox) } == true
            }
        } ?? false
        let nameCandidateIsValueOrFallback = nameCandidate.map { candidate in
            if candidate.detectionKind == .labelFallback {
                return candidate.text == L10n.Review.ocrNoExplicitValue
            }

            return likelyHumanNameDisplayValue(from: candidate.text) != nil
        } ?? false

        let checks = [
            PrivateOCRRegressionCheckResult(name: "Case A exactly one patient name candidate", passed: exactlyOneNameCandidate),
            PrivateOCRRegressionCheckResult(name: "Case A no duplicate name candidates", passed: duplicateNameCandidatesAbsent),
            PrivateOCRRegressionCheckResult(name: "Case A no tester/operator contamination", passed: !testerOperatorContaminationDetected),
            PrivateOCRRegressionCheckResult(name: "Case A name not created from tester/operator row", passed: !(nameCandidate.map { privateOCRRegressionCandidate($0, isSourcedFrom: nonPatientRows) } ?? true)),
            PrivateOCRRegressionCheckResult(name: "Case A name not created from protocol/name label", passed: !nameFromForbiddenLabelDetected),
            PrivateOCRRegressionCheckResult(name: "Case A Standard scope clean", passed: standardScopeClean),
            PrivateOCRRegressionCheckResult(name: "Case A ID candidate exists if ID source is present", passed: idCandidateExistsIfPresent),
            PrivateOCRRegressionCheckResult(name: "Case A name box covers split-name fill area", passed: nameBoxCoversFillArea),
            PrivateOCRRegressionCheckResult(name: "Case A name box excludes tester/operator rows", passed: nameBoxExcludesTesterRows),
            PrivateOCRRegressionCheckResult(name: "Case A name result is value extraction or region fallback", passed: nameCandidateIsValueOrFallback)
        ]
        let classification: PrivateOCRRegressionClassification
        if checks.allSatisfy(\.passed),
           let nameCandidate {
            classification = nameCandidate.detectionKind == .labelFallback
                ? .regionFallbackPassed
                : .valueExtractionPassed
        } else {
            classification = .failed
        }

        return PrivateOCRRegressionFixtureResult(
            classification: classification,
            totalCandidateCount: candidates.count,
            candidateSummaries: candidates.map(privateOCRRegressionCandidateSummary),
            splitNameGroupCount: splitNameGroups.count,
            pairedSplitNameGroupCount: pairedSplitNameGroups.count,
            expectedNameFillArea: expectedFillArea.map(privateOCRRegressionRectDescription),
            nameFillCoverageRatio: nameFillCoverageRatio,
            exactlyOneNameCandidate: exactlyOneNameCandidate,
            testerOperatorContaminationDetected: testerOperatorContaminationDetected,
            standardScopeClean: standardScopeClean,
            idSourcePresentInOCR: idSourcePresentInOCR,
            idCandidateExistsIfPresent: idCandidateExistsIfPresent,
            checks: checks
        )
    }

    private static func privateOCRRegressionRows(
        matching labelTexts: [String],
        in textItems: [OCRTextItem]
    ) -> [PrivateOCRRegressionRowFact] {
        textItems.enumerated().compactMap { _, item in
            guard privateOCRRegressionText(item.text, matchesAnyLabelIn: labelTexts) else {
                return nil
            }

            let inlineValue = privateOCRRegressionInlineValue(afterAny: labelTexts, in: item.text)
            let valueItem = nearestValueItem(
                for: item,
                category: .name,
                in: textItems,
                mode: .sameLineRight
            )
            let valueText = inlineValue ?? valueItem?.text
            let rowBox = valueItem.map { unionRect(item.boundingBox, $0.boundingBox) } ?? item.boundingBox

            return PrivateOCRRegressionRowFact(
                labelBox: item.boundingBox,
                rowBox: rowBox,
                normalizedValue: valueText.map(normalizedOCRLabelText)
            )
        }
    }

    private static func privateOCRRegressionText(
        _ text: String,
        matchesAnyLabelIn labelTexts: [String]
    ) -> Bool {
        let compact = normalizedOCRLabelText(text)
        guard !compact.isEmpty else {
            return false
        }

        return labelTexts.contains { labelText in
            let label = normalizedOCRLabelText(labelText)
            return compact == label || compact.hasPrefix(label)
        }
    }

    private static func privateOCRRegressionInlineValue(
        afterAny labelTexts: [String],
        in text: String
    ) -> String? {
        let normalized = normalizedOCRValueText(text)
        let sortedLabels = labelTexts.sorted { $0.count > $1.count }

        for labelText in sortedLabels {
            guard let labelRange = normalized.range(of: labelText, options: [.caseInsensitive]) else {
                continue
            }

            let rawValue = String(normalized[labelRange.upperBound...])
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ":：;；,，.。\"'“”‘’()（）[]【】")))
            if let value = likelyHumanNameDisplayValueFromRawValue(rawValue) {
                return value
            }
        }

        return nil
    }

    private static func privateOCRRegressionCandidate(
        _ candidate: OCRSensitiveCandidate,
        isContaminatedBy rows: [PrivateOCRRegressionRowFact]
    ) -> Bool {
        rows.contains { row in
            if let normalizedValue = row.normalizedValue,
               !normalizedValue.isEmpty {
                let candidateValue = normalizedOCRLabelText(candidate.text)
                if candidateValue == normalizedValue || candidateValue.contains(normalizedValue) {
                    return true
                }
            }

            return privateOCRRegressionCandidate(candidate, isSourcedFrom: [row])
                || privateOCRRegressionRect(candidate.boundingBox, reachesRow: row.rowBox)
        }
    }

    private static func privateOCRRegressionCandidate(
        _ candidate: OCRSensitiveCandidate,
        isSourcedFrom rows: [PrivateOCRRegressionRowFact]
    ) -> Bool {
        rows.contains { row in
            if let labelBoundingBox = candidate.labelBoundingBox,
               privateOCRRegressionRect(labelBoundingBox, reachesRow: row.labelBox) {
                return true
            }

            return privateOCRRegressionRect(candidate.boundingBox, reachesRow: row.rowBox)
                && abs(candidate.boundingBox.centerY - row.rowBox.centerY) <= max(candidate.boundingBox.height, row.rowBox.height)
        }
    }

    private static func privateOCRRegressionNameCandidateCoversSplitFillArea(
        _ candidate: OCRSensitiveCandidate,
        splitGroup: OCRSplitNameLabelGroup?
    ) -> Bool {
        guard let splitGroup else {
            return false
        }

        let expectedFillArea = likelySplitNameFillArea(for: splitGroup)
        if privateOCRRegressionRect(candidate.boundingBox, covers: expectedFillArea) {
            return true
        }

        if candidate.detectionKind != .labelFallback,
           candidate.boundingBox.centerX >= expectedFillArea.x,
           candidate.boundingBox.centerX <= expectedFillArea.maxX,
           candidate.boundingBox.y >= expectedFillArea.y - 0.020,
           candidate.boundingBox.maxY <= expectedFillArea.maxY + 0.020 {
            return true
        }

        return false
    }

    private static func privateOCRRegressionRect(
        _ candidateBox: NormalizedRect,
        covers expectedBox: NormalizedRect
    ) -> Bool {
        privateOCRRegressionCoverageRatio(candidateBox, expectedBox) >= 0.35
            || candidateBoxesReferToSameLocation(candidateBox, expectedBox)
    }

    private static func privateOCRRegressionCoverageRatio(
        _ candidateBox: NormalizedRect,
        _ expectedBox: NormalizedRect
    ) -> Double {
        let intersection = normalizedRectIntersectionArea(candidateBox, expectedBox)
        let candidateArea = candidateBox.width * candidateBox.height
        let expectedArea = expectedBox.width * expectedBox.height

        guard candidateArea > 0, expectedArea > 0 else {
            return 0
        }

        return intersection / min(candidateArea, expectedArea)
    }

    private static func privateOCRRegressionRect(
        _ candidateBox: NormalizedRect,
        reachesRow rowBox: NormalizedRect
    ) -> Bool {
        let verticalOverlap = max(0, min(candidateBox.maxY, rowBox.maxY) - max(candidateBox.y, rowBox.y))
        guard verticalOverlap > min(candidateBox.height, rowBox.height) * 0.20 else {
            return false
        }

        let horizontalOverlap = max(0, min(candidateBox.maxX, rowBox.maxX) - max(candidateBox.x, rowBox.x))
        return horizontalOverlap > 0
            || abs(candidateBox.centerX - rowBox.centerX) <= max(candidateBox.width, rowBox.width) * 0.75 + 0.08
    }

    private static func privateOCRRegressionIDSourcePresent(in textItems: [OCRTextItem]) -> Bool {
        textItems.contains { item in
            isChineseIDLikeText(item.text)
                || targetRules
                    .filter { $0.category == .chineseID || $0.category == .documentNumber }
                    .contains { !$0.matches(in: item.text).isEmpty }
        }
    }

    private static func privateOCRRegressionCandidateSummary(
        _ candidate: OCRSensitiveCandidate
    ) -> PrivateOCRRegressionCandidateSummary {
        PrivateOCRRegressionCandidateSummary(
            category: candidate.category.rawValue,
            detectionKind: candidate.detectionKind.rawValue,
            boundingBox: String(
                privateOCRRegressionRectDescription(candidate.boundingBox)
            ),
            redactedValue: privateOCRRegressionRedactedValue(for: candidate)
        )
    }

    private static func privateOCRRegressionRectDescription(_ rect: NormalizedRect) -> String {
        String(
            format: "(x: %.4f, y: %.4f, w: %.4f, h: %.4f)",
            rect.x,
            rect.y,
            rect.width,
            rect.height
        )
    }

    private static func privateOCRRegressionRedactedValue(
        for candidate: OCRSensitiveCandidate
    ) -> String {
        switch candidate.category {
        case .name:
            return candidate.detectionKind == .labelFallback ? "<REGION_FALLBACK>" : "<REDACTED_NAME>"
        case .chineseID, .documentNumber:
            return "<REDACTED_ID>"
        default:
            return "<REDACTED_VALUE>"
        }
    }

    private static func privateOCRRegressionTextItem(
        _ text: String,
        box: NormalizedRect
    ) -> OCRTextItem {
        OCRTextItem(text: text, recognizedText: nil, boundingBox: box, confidence: 0.90)
    }

    private static func privateOCRRegressionStandardCandidates(
        pageID: PageItem.ID,
        textItems: [OCRTextItem]
    ) -> [OCRSensitiveCandidate] {
        buildCandidates(
            from: textItems,
            pageID: pageID,
            options: OCRDetectionOptions(preset: .standard, customFields: []),
            context: .empty
        )
    }

    private static func privateOCRRegressionHasSingleName(
        _ candidates: [OCRSensitiveCandidate],
        equalTo expectedText: String
    ) -> Bool {
        candidates.filter { $0.category == .name }.count == 1
            && privateOCRRegressionHasName(candidates, equalTo: expectedText)
    }

    private static func privateOCRRegressionHasName(
        _ candidates: [OCRSensitiveCandidate],
        equalTo expectedText: String
    ) -> Bool {
        candidates.contains { $0.category == .name && $0.text == expectedText }
    }

    private struct PrivateOCRRegressionRowFact {
        let labelBox: NormalizedRect
        let rowBox: NormalizedRect
        let normalizedValue: String?
    }
    #endif

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

private struct OCRProcessingContext {
    let sourceImage: CGImage?

    static let empty = OCRProcessingContext(sourceImage: nil)
}

private struct OCRTextItem {
    let text: String
    let recognizedText: VNRecognizedText?
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
    let inlineValue: OCRSplitNameInlineValue?
}

private struct OCRSplitNameLabelGroup {
    let surnameIndex: Int
    let givenNameIndex: Int?
    let surnameBoundingBox: NormalizedRect
    let givenNameBoundingBox: NormalizedRect?
    let labelBoundingBox: NormalizedRect
    let confidence: Double
    let inlineValues: [OCRSplitNameInlineValue]

    var itemIndexes: Set<Int> {
        var indexes = Set([surnameIndex])
        if let givenNameIndex {
            indexes.insert(givenNameIndex)
        }
        return indexes
    }
}

private struct OCRSplitNameInlineValue {
    let part: OCRSplitNameLabelPart
    let text: String
    let boundingBox: NormalizedRect
    let confidence: Double
}

private struct OCRSplitNameComponentValue {
    let part: OCRSplitNameLabelPart
    let text: String
    let boundingBox: NormalizedRect
    let confidence: Double
    let sourceIndex: Int?
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
        if category == .name, isForbiddenNameLabelText(text) {
            return false
        }

        let normalized = normalizedOCRLabelText(text)

        return labelPatterns.contains { pattern in
            let normalizedPattern = normalizedOCRLabelText(pattern)
            if isSingleCharacterSplitNameLabelPattern(normalizedPattern) {
                return normalizedSplitNameLabelText(text) == normalizedPattern
            }

            return normalized.localizedCaseInsensitiveContains(normalizedPattern)
        }
    }

    func inlineValueRange(in text: String, allowsNameWithSpaces: Bool = false) -> NSRange? {
        if category == .name, isForbiddenNameLabelText(text) {
            return nil
        }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        for pattern in labelPatterns.sorted(by: { $0.count > $1.count }) {
            let escapedPattern = NSRegularExpression.escapedPattern(for: pattern)
            let valuePattern = category == .name && allowsNameWithSpaces ? "(.{1,80})" : #"([^\s:：]{1,80})"#
            let regex = try! NSRegularExpression(
                pattern: "\(escapedPattern)\\s*[:：]?\\s*\(valuePattern)",
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

private let forbiddenNameLabelTexts: [String] = [
    "使用协议名称",
    "协议名称",
    "项目名称",
    "检查名称",
    "医院名称",
    "文件名称",
    "名称"
]

private let standardNonPatientNameLabelTexts: [String] = [
    "测试者",
    "测试人员",
    "检查者",
    "操作者",
    "操作员",
    "医生",
    "医师",
    "技师",
    "审核者",
    "审核医生",
    "报告医生",
    "送检医生",
    "申请医生"
]

private let forbiddenNameValueTexts: [String] = forbiddenNameLabelTexts + [
    "地址",
    "性别",
    "年龄",
    "生日",
    "证件号",
    "身份证号",
    "使用协议",
    "Threshold",
    "ABR"
] + standardNonPatientNameLabelTexts + [
    "中国"
]

private let splitNamePartForbiddenTexts: [String] = forbiddenNameValueTexts + [
    "电话",
    "手机号",
    "手机",
    "身份证号",
    "身份证号码",
    "电子邮件",
    "男",
    "女",
    "M",
    "F",
    "Age 30"
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

private func isForbiddenNameLabelText(_ text: String) -> Bool {
    let compact = normalizedOCRLabelText(text)

    return forbiddenNameLabelTexts.contains { forbiddenLabel in
        let forbidden = normalizedOCRLabelText(forbiddenLabel)

        if forbidden == "名称" {
            return compact == forbidden
        }

        return compact == forbidden || compact.hasPrefix(forbidden)
    }
}

private func isStandardForbiddenNameLabelText(_ text: String) -> Bool {
    let compact = normalizedOCRLabelText(text)
    guard !compact.isEmpty else {
        return false
    }

    return (forbiddenNameLabelTexts + standardNonPatientNameLabelTexts).contains { forbiddenText in
        let forbidden = normalizedOCRLabelText(forbiddenText)
        return compact == forbidden || compact.hasPrefix(forbidden)
    }
}

private func isForbiddenNameValueText(_ text: String) -> Bool {
    let compact = normalizedOCRLabelText(text)

    return forbiddenNameValueTexts.contains { forbiddenText in
        let forbidden = normalizedOCRLabelText(forbiddenText)

        if forbidden == "名称" || forbidden == "abr" || forbidden == "threshold" {
            return compact == forbidden
        }

        return compact == forbidden || compact.hasPrefix(forbidden)
    }
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
