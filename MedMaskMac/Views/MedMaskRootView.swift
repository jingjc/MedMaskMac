import SwiftUI

struct MedMaskRootView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
                .zIndex(1)
            Divider()
            pageContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.App.title)
                    .font(.title2.weight(.semibold))
                Text(viewModel.selectedPage.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Picker(L10n.App.pagePickerLabel, selection: $viewModel.selectedPage) {
                ForEach(AppPage.allCases) { page in
                    Text(page.title).tag(page)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 360)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    @ViewBuilder
    private var pageContent: some View {
        switch viewModel.selectedPage {
        case .import:
            ImportPageView(viewModel: viewModel)
        case .reviewEdit:
            ReviewEditPageView(viewModel: viewModel)
        case .exportSummary:
            ExportSummaryPageView(viewModel: viewModel)
        }
    }
}
