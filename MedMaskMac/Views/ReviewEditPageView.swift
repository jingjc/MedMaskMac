import SwiftUI

struct ReviewEditPageView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 250, idealWidth: 280, maxWidth: 320)

            canvas
                .frame(minWidth: 480, maxWidth: .infinity)

            inspector
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 360)
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PanelCard(
                    title: "Files",
                    subtitle: "Left sidebar placeholder for imported documents."
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(viewModel.files) { file in
                            Button {
                                viewModel.selectFile(file.id)
                            } label: {
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(file.displayName)
                                            .font(.headline)
                                            .multilineTextAlignment(.leading)
                                        Text("\(file.kind.rawValue) • \(file.pageCount) page(s)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()
                                    StatusBadge(text: file.status.rawValue)
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(file.id == viewModel.selectedFileID ? Color.accentColor.opacity(0.10) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                PanelCard(
                    title: "Pages",
                    subtitle: "Page and status placeholders for the selected file."
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(viewModel.selectedFile?.pages ?? []) { page in
                            Button {
                                viewModel.selectPage(page.id)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(page.title)
                                            .font(.headline)
                                        Text("\(page.sensitiveRegions.count) region(s)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()
                                    StatusBadge(text: page.status.rawValue)
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(page.id == viewModel.selectedPageID ? Color.accentColor.opacity(0.10) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private var canvas: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Canvas")
                .font(.title2.weight(.semibold))

            PanelCard(
                title: viewModel.canvasTitle,
                subtitle: "Center canvas placeholder for future PDF or image rendering."
            ) {
                VStack(spacing: 18) {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color(nsColor: .underPageBackgroundColor))
                        .overlay {
                            VStack(spacing: 12) {
                                Image(systemName: "doc.viewfinder")
                                    .font(.system(size: 42))
                                    .foregroundStyle(.secondary)
                                Text("Page preview will render here in a later phase.")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 480)

                    HStack {
                        Label(viewModel.selectedFile?.displayName ?? "No file selected", systemImage: "doc.text")
                        Spacer()
                        Label(viewModel.selectedDocumentPage?.title ?? "No page selected", systemImage: "doc.plaintext")
                    }
                    .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(20)
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PanelCard(
                    title: "Inspector",
                    subtitle: "Right-side placeholder for mask settings and page details."
                ) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Mask Preset")
                            .font(.headline)

                        Picker("Mask Preset", selection: $viewModel.selectedPreset) {
                            ForEach(MaskPreset.allCases) { preset in
                                Text(preset.title).tag(preset)
                            }
                        }

                        Text(viewModel.selectedPreset.summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Divider()

                        Label("Selected file regions: \(viewModel.selectedFileRegionCount)", systemImage: "square.dashed")
                        Label("Total session regions: \(viewModel.totalRegionCount)", systemImage: "square.stack.3d.down.right")
                        Label(viewModel.maskPreviewSummary, systemImage: "rectangle.and.pencil.and.ellipsis")
                    }
                }

                PanelCard(
                    title: "Detection Status",
                    subtitle: "Service placeholders only. No OCR or barcode pass runs yet."
                ) {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(viewModel.ocrSummary, systemImage: "text.viewfinder")
                        Label(viewModel.barcodeSummary, systemImage: "barcode.viewfinder")
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
    }
}
