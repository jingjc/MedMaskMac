#!/usr/bin/env swift

import Darwin
import Foundation

enum RunnerError: Error, CustomStringConvertible {
    case missingFixture(String)
    case commandFailed(String, Int32)

    var description: String {
        switch self {
        case let .missingFixture(path):
            "Missing private fixture at \(path)"
        case let .commandFailed(command, status):
            "\(command) failed with exit code \(status)"
        }
    }
}

func main() throws -> Int32 {
let fileManager = FileManager.default
let launchPath = CommandLine.arguments.first ?? "Scripts/run_private_ocr_regression.swift"
let currentDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
let scriptURL = URL(fileURLWithPath: launchPath, relativeTo: currentDirectory).standardizedFileURL
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let fixtureRelativePath = "PrivateFixtures/OCR/split_name_real_private.jpeg"
let fixtureURL = repoRoot.appendingPathComponent(fixtureRelativePath)

guard fileManager.fileExists(atPath: fixtureURL.path) else {
    throw RunnerError.missingFixture(fixtureRelativePath)
}

let buildDirectory = repoRoot.appendingPathComponent(".build/private-ocr-regression", isDirectory: true)
try fileManager.createDirectory(at: buildDirectory, withIntermediateDirectories: true)
let moduleCacheDirectory = buildDirectory.appendingPathComponent("module-cache", isDirectory: true)
try fileManager.createDirectory(at: moduleCacheDirectory, withIntermediateDirectories: true)

let helperURL = buildDirectory.appendingPathComponent("PrivateOCRRegressionMain.swift")
let executableURL = buildDirectory.appendingPathComponent("private-ocr-regression")

let helperSource = #"""
import AppKit
import Darwin
import Foundation

extension NSImage {
    var cgImageValue: CGImage? {
        cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

@main
struct PrivateOCRRegressionMain {
    static func main() async {
        guard CommandLine.arguments.count == 2 else {
            print("usage: private-ocr-regression <private-fixture-path>")
            exit(2)
        }

        do {
            let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[1])
            let result = try await DefaultOCRService.privateOCRRegressionFixtureResult(fixtureURL: fixtureURL)
            let syntheticResults = DefaultOCRService.privateOCRRegressionSyntheticCaseResults()
            let allSyntheticPassed = syntheticResults.allSatisfy(\.passed)
            let categories = result.candidateSummaries.map(\.category).joined(separator: ",")

            print("fixture=PrivateFixtures/OCR/split_name_real_private.jpeg")
            print("classification=\(result.classification.rawValue)")
            print("totalCandidateCount=\(result.totalCandidateCount)")
            print("candidateCategories=\(categories.isEmpty ? "none" : categories)")
            print("splitNameGroupCount=\(result.splitNameGroupCount)")
            print("pairedSplitNameGroupCount=\(result.pairedSplitNameGroupCount)")
            print("expectedNameFillArea=\(result.expectedNameFillArea ?? "none")")
            print(String(format: "nameFillCoverageRatio=%.4f", result.nameFillCoverageRatio))
            print("candidates:")
            if result.candidateSummaries.isEmpty {
                print("  none")
            } else {
                for candidate in result.candidateSummaries {
                    print("  category=\(candidate.category) detectionKind=\(candidate.detectionKind) value=\(candidate.redactedValue) box=\(candidate.boundingBox)")
                }
            }
            print("exactlyOneNameCandidate=\(result.exactlyOneNameCandidate)")
            print("testerOperatorContaminationDetected=\(result.testerOperatorContaminationDetected)")
            print("standardScopeClean=\(result.standardScopeClean)")
            print("idSourcePresentInOCR=\(result.idSourcePresentInOCR)")
            print("idCandidateExistsIfPresent=\(result.idCandidateExistsIfPresent)")
            print("checks:")
            for check in result.checks {
                print("  \(check.passed ? "PASS" : "FAIL") \(check.name)")
            }
            print("syntheticCases:")
            for check in syntheticResults {
                print("  \(check.passed ? "PASS" : "FAIL") \(check.name)")
            }

            exit(result.passed && allSyntheticPassed ? 0 : 1)
        } catch {
            print("privateOCRRegression=failed")
            print("error=\(error.localizedDescription)")
            exit(1)
        }
    }
}
"""#

try helperSource.write(to: helperURL, atomically: true, encoding: .utf8)

let sourcePaths = [
    "MedMaskMac/App/AppPage.swift",
    "MedMaskMac/Utils/L10n.swift",
    "MedMaskMac/Models/SensitiveRegion.swift",
    "MedMaskMac/Models/PageItem.swift",
    "MedMaskMac/Models/FileItem.swift",
    "MedMaskMac/Models/MaskPreset.swift",
    "MedMaskMac/Models/OCRSensitiveCandidate.swift",
    "MedMaskMac/Services/OCRService.swift",
    helperURL.path
]

func run(_ executable: String, arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = repoRoot
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

let compileArguments = [
    "swiftc",
    "-D",
    "PRIVATE_OCR_REGRESSION",
    "-parse-as-library",
    "-module-cache-path",
    moduleCacheDirectory.path
] + sourcePaths + [
    "-o",
    executableURL.path
]

let compileStatus = try run("/usr/bin/xcrun", arguments: compileArguments)
guard compileStatus == 0 else {
    throw RunnerError.commandFailed("xcrun swiftc", compileStatus)
}

let runStatus = try run(executableURL.path, arguments: [fixtureURL.path])
return runStatus
}

do {
    exit(try main())
} catch {
    fputs("privateOCRRegression=failed\n", stderr)
    fputs("error=\(error)\n", stderr)
    exit(1)
}
