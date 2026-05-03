import SwiftUI

struct ImportPageView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Import Page")
                    .font(.largeTitle.weight(.semibold))

                Text("This phase only prepares the shell. File selection, OCR, and export remain intentionally unimplemented.")
                    .font(.body)
                    .foregroundStyle(.secondary)

                HStack(alignment: .top, spacing: 20) {
                    PanelCard(
                        title: "Import Placeholder",
                        subtitle: viewModel.importPlaceholderMessage
                    ) {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Supported later: \(viewModel.supportedImportTypes)", systemImage: "doc.badge.plus")
                            Label("Local-first workflow", systemImage: "desktopcomputer")
                            Label("No background processing yet", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")

                            Button("Choose Files") {}
                                .disabled(true)
                        }
                    }

                    PanelCard(
                        title: "Session Seed Data",
                        subtitle: "Sample in-memory items keep the review and export shells visible."
                    ) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(viewModel.files) { file in
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(file.displayName)
                                            .font(.headline)
                                        Text("\(file.kind.rawValue) • \(file.pageCount) page(s)")
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()
                                    StatusBadge(text: file.status.rawValue)
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
