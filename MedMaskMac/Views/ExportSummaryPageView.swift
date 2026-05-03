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
                    PanelCard(
                        title: L10n.Export.preparedTitle,
                        subtitle: viewModel.exportPlaceholderSummary
                    ) {
                        VStack(alignment: .leading, spacing: 12) {
                            Label(viewModel.preparedFilesSummary, systemImage: "doc.on.doc")
                            Label(viewModel.preparedPagesSummary, systemImage: "doc.text.magnifyingglass")
                            Label(viewModel.preparedRegionsSummary, systemImage: "rectangle.compress.vertical")
                            Label(viewModel.selectedPreset.title, systemImage: "line.3.horizontal.decrease.circle")
                        }
                    }

                    PanelCard(
                        title: L10n.Export.nextPhaseTitle,
                        subtitle: L10n.Export.nextPhaseSubtitle
                    ) {
                        VStack(alignment: .leading, spacing: 12) {
                            Label(L10n.Export.noAction, systemImage: "nosign")
                            Label(L10n.Export.noQualitySettings, systemImage: "slider.horizontal.3")
                            Label(L10n.Export.originalUnchanged, systemImage: "lock.doc")

                            Button(L10n.Export.exportButton) {}
                                .disabled(true)
                        }
                    }
                }
            }
            .padding(24)
        }
    }
}
