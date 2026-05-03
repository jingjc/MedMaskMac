import SwiftUI

struct ExportSummaryPageView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Export Summary")
                    .font(.largeTitle.weight(.semibold))

                Text("Export is intentionally not implemented in this phase. This page only establishes the shell and the future summary surface.")
                    .foregroundStyle(.secondary)

                HStack(alignment: .top, spacing: 20) {
                    PanelCard(
                        title: "Prepared Session",
                        subtitle: viewModel.exportPlaceholderSummary
                    ) {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("\(viewModel.files.count) file(s)", systemImage: "doc.on.doc")
                            Label("\(viewModel.totalPageCount) total page(s)", systemImage: "doc.text.magnifyingglass")
                            Label("\(viewModel.totalRegionCount) placeholder sensitive region(s)", systemImage: "rectangle.compress.vertical")
                            Label(viewModel.selectedPreset.title, systemImage: "line.3.horizontal.decrease.circle")
                        }
                    }

                    PanelCard(
                        title: "Next Phase Boundary",
                        subtitle: "Scope remains fixed to a shell-only export summary."
                    ) {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("No real export action", systemImage: "nosign")
                            Label("No quality settings", systemImage: "slider.horizontal.3")
                            Label("Original files remain unchanged", systemImage: "lock.doc")

                            Button("Export Redacted Copy") {}
                                .disabled(true)
                        }
                    }
                }
            }
            .padding(24)
        }
    }
}
