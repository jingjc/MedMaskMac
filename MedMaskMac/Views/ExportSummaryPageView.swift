import SwiftUI

struct ExportSummaryPageView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(L10n.Export.title)
                    .font(.largeTitle.weight(.semibold))

                Text(L10n.Export.description)
                    .foregroundStyle(.secondary)

                HStack(alignment: .top, spacing: 20) {
                    preparedSessionCard
                    exportResultCard
                }

                if viewModel.hasExportFailures,
                   let exportResult = viewModel.lastExportResult {
                    PanelCard(
                        title: L10n.Export.failuresTitle,
                        subtitle: L10n.Export.failuresSubtitle
                    ) {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(exportResult.failures) { failure in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(failure.fileName)
                                        .font(.headline)
                                    Text(failure.reason)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    private var preparedSessionCard: some View {
        PanelCard(
            title: L10n.Export.preparedTitle,
            subtitle: viewModel.exportPreparedSummary
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Label(viewModel.preparedFilesSummary, systemImage: "doc.on.doc")
                Label(viewModel.preparedPagesSummary, systemImage: "doc.text.magnifyingglass")
                Label(viewModel.preparedRegionsSummary, systemImage: "rectangle.compress.vertical")
                Label(viewModel.selectedPreset.title, systemImage: "line.3.horizontal.decrease.circle")
                Label(L10n.Export.originalUnchanged, systemImage: "lock.doc")
            }
        }
    }

    private var exportResultCard: some View {
        PanelCard(
            title: viewModel.lastExportResult == nil ? L10n.Export.readyTitle : L10n.Export.resultsTitle,
            subtitle: viewModel.lastExportResult == nil ? L10n.Export.readySubtitle : L10n.Export.resultsSubtitle
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if viewModel.lastExportResult != nil {
                    if let exportSuccessSummary = viewModel.exportSuccessSummary {
                        Label(exportSuccessSummary, systemImage: "checkmark.circle")
                    }

                    if let exportFailureSummary = viewModel.exportFailureSummary {
                        Label(exportFailureSummary, systemImage: "exclamationmark.triangle")
                    }

                    if let destinationPath = viewModel.lastExportDestinationPath {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "folder")
                            Text(L10n.Export.destinationPath(destinationPath))
                                .textSelection(.enabled)
                        }
                    }
                } else {
                    Label(L10n.Export.noResultsYet, systemImage: "clock")
                    Label(L10n.Export.fixedPDFResolution, systemImage: "doc.richtext")
                    Label(L10n.Export.localDestinationOnly, systemImage: "internaldrive")
                }

                HStack(spacing: 12) {
                    Button(L10n.Export.exportButton) {
                        viewModel.beginExportFlow()
                    }
                    .disabled(!viewModel.canBeginExportFlow)

                    Button(L10n.Export.openFolderButton) {
                        viewModel.openExportDestination()
                    }
                    .disabled(!viewModel.canOpenExportDestination)
                }
            }
        }
    }
}
