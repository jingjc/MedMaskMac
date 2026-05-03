import SwiftUI

struct ImportPageView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(L10n.Import.title)
                    .font(.largeTitle.weight(.semibold))

                Text(L10n.Import.description)
                    .font(.body)
                    .foregroundStyle(.secondary)

                HStack(alignment: .top, spacing: 20) {
                    PanelCard(
                        title: L10n.Import.actionTitle,
                        subtitle: viewModel.importGuidanceMessage
                    ) {
                        VStack(alignment: .leading, spacing: 12) {
                            Label(L10n.Common.supportedFormats(viewModel.supportedImportTypes), systemImage: "doc.badge.plus")
                            Label(L10n.Import.localFirst, systemImage: "desktopcomputer")
                            Label(L10n.Import.noBackground, systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")

                            HStack(spacing: 12) {
                                Button(L10n.Import.chooseFiles) {
                                    viewModel.importFiles()
                                }

                                Button(L10n.Import.goToReview) {
                                    viewModel.goToReview()
                                }
                                .disabled(!viewModel.canGoToReview)
                            }

                            if let importErrorMessage = viewModel.importErrorMessage {
                                Text(importErrorMessage)
                                    .font(.subheadline)
                                    .foregroundStyle(.red)
                            }
                        }
                    }

                    PanelCard(
                        title: L10n.Import.importedFilesTitle,
                        subtitle: viewModel.importedFilesCardSubtitle
                    ) {
                        if viewModel.files.isEmpty {
                            Text(L10n.Import.emptyImportedFiles)
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(viewModel.files) { file in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(file.displayName)
                                                .font(.headline)
                                            Text(viewModel.fileSummary(for: file))
                                                .foregroundStyle(.secondary)
                                        }

                                        Spacer()
                                        StatusBadge(text: file.status.displayTitle)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
    }
}
