# MedMask Mac — Project Instructions for Codex

## Project identity
This repository is for **MedMask Mac**, a local-first macOS app for redacting sensitive information from medical reports before sending them to AI tools.

The goal is not monetization, not App Store launch, and not cloud collaboration.
The current goal is to build a V0 local Mac tool that is genuinely useful in real workflows.

## Tech stack
- Swift
- SwiftUI
- PDFKit
- Vision (later phase only; do not implement OCR in the current phase)
- Xcode 26.3
- macOS app
- Single window
- Single user
- Single session

## Current project state
The repository starts from a minimal macOS SwiftUI Xcode project that can already run.

## Frozen V0 scope
V0 includes only 3 pages:
1. Import / file selection page
2. Review and edit core page
3. Export result summary page

V0 includes only 4 main flows:
1. Import images / PDFs
2. Auto-detect sensitive areas (later phase, not now)
3. Manual box editing (later phase)
4. Burned export copy (later phase)

V0 supports only 3 presets:
- Standard redaction
- Strict redaction
- Custom redaction

## Explicitly out of scope
Do not add any of the following:
- Similar-page detection
- Separate custom mode page
- Recent imports
- Import history
- Cross-session persistence
- Cloud sync
- Accounts
- Medical analysis
- AI interpretation
- Export quality settings
- OCR statistics dashboard
- Dedicated QR-code status page
- Archive system
- Health management platform
- App Store packaging priority
- Database
- Core Data
- Settings page
- Multi-window architecture

## OCR and export constraints
OCR will exist later, but not in the current phase.
Later OCR constraints:
- Background low concurrency
- Max 2 OCR tasks
- Current page gets priority

Export will exist later, but not in the current phase.
Later export constraints:
- PDF rasterize and rebuild
- 200 DPI fixed
- No user-facing quality configuration
- True burned black boxes
- Original files remain unchanged

## Interaction constraints for later phases
- Delete: remove selected box
- Left/Right arrows: page switch
- Space: toggle original / preview
- Command+Z / Shift+Command+Z: undo / redo
- Command+E: export
- Drag to create box
- Drag corner to resize
- Drag center to move

## Minimum future detection targets
Later OCR detection targets:
- Person name
- Phone number
- Chinese ID number
- Outpatient / inpatient / record / sample number
- Barcode / QR code

## Required project structure
Organize code using these groups / folders:
- App
- Models
- Views
- ViewModels
- Services
- Utils

## Required key models
Prepare and use clear model types for:
- FileItem
- PageItem
- SensitiveRegion
- MaskPreset

## Required services
Prepare service types or protocols for:
- FileImportService
- PDFRenderService
- OCRService
- BarcodeService
- MaskComposeService
- ExportService

They do not all need real implementation immediately, but the structure must be ready.

## Development rules
1. Do only the requested phase. Do not jump ahead.
2. Prefer small, compilable, incremental changes.
3. Do not introduce third-party dependencies.
4. Use Apple-native frameworks whenever possible.
5. Keep names clean, explicit, and maintainable.
6. If changing files, edit the real repository files directly.
7. After code changes, explain what changed and why.
8. Prefer structure correctness and compile success over visual polish.
9. Never silently expand product scope.
10. If uncertain, choose the smaller implementation.

## Definition of done for the current stage
For the current stage, success means:
- The Xcode project still compiles
- The default Hello world is replaced by MedMask Mac structure
- There is a visible 3-page shell
- The review page has a 3-column skeleton
- The codebase is organized for the next phase

## Current phase
Current phase only:
- Build engineering skeleton
- Build 3-page empty shell
- Build root state management
- No OCR
- No real import
- No real export
- No manual box editing yet
