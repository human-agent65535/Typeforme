import SwiftUI

enum LanguageDisplay {
    static func summary(for ids: Set<String>, options: [ASRLanguageOption] = ASRLanguageSelection.all) -> String {
        let names = ASRLanguageSelection.displayNames(for: Array(ids), supportedOptions: options)
        if names.isEmpty { return NSLocalizedString("None", comment: "No languages selected") }
        if names.count <= 2 { return names.joined(separator: ", ") }
        return names.prefix(2).joined(separator: ", ") + " +\(names.count - 2)"
    }
}

struct LanguageSelectionView: View {
    @Binding var selection: Set<String>
    let options: [ASRLanguageOption]
    let showsPreviewSupport: Bool
    private let previewSupportByLanguageID: [String: Bool]
    @State private var searchText = ""

    init(
        selection: Binding<Set<String>>,
        options: [ASRLanguageOption] = ASRLanguageSelection.all,
        showsPreviewSupport: Bool = false
    ) {
        let resolvedOptions = options.isEmpty ? ASRLanguageSelection.all : options
        self._selection = selection
        self.options = resolvedOptions
        self.showsPreviewSupport = showsPreviewSupport
        if showsPreviewSupport {
            self.previewSupportByLanguageID = Dictionary(
                uniqueKeysWithValues: resolvedOptions.map { option in
                    (option.id, AppleSpeechPreviewSupport.supportsOnDevicePreview(languageID: option.id))
                }
            )
        } else {
            self.previewSupportByLanguageID = [:]
        }
    }

    var body: some View {
        List {
            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section("Common") {
                    ForEach(commonLanguages) { option in
                        languageRow(option)
                    }
                }

                Section("Supported Languages") {
                    ForEach(otherLanguages) { option in
                        languageRow(option)
                    }
                }
            } else {
                Section("Matches") {
                    ForEach(filteredLanguages) { option in
                        languageRow(option)
                    }
                }
            }
        }
        .navigationTitle("Languages")
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always))
        .onAppear(perform: clampSelection)
    }

    private var commonLanguages: [ASRLanguageOption] {
        options
            .filter(\.isCommon)
            .sorted { ($0.commonRank ?? .max) < ($1.commonRank ?? .max) }
    }

    private var otherLanguages: [ASRLanguageOption] {
        options.filter { !$0.isCommon }
    }

    private var filteredLanguages: [ASRLanguageOption] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return options }
        return options.filter { option in
            option.id.lowercased().contains(query)
                || option.displayName.lowercased().contains(query)
                || option.whisperCode.lowercased().contains(query)
        }
    }

    private func languageRow(_ option: ASRLanguageOption) -> some View {
        let supportsPreview = previewSupportByLanguageID[option.id] ?? false
        return Button {
            toggle(option.id)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.displayName)
                    Text(option.id)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if showsPreviewSupport {
                        previewBadge(supportsPreview: supportsPreview)
                    }
                }
                Spacer()
                if selection.contains(option.id) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
    }

    private func previewBadge(supportsPreview: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: supportsPreview ? "waveform.circle.fill" : "waveform.circle")
            if supportsPreview {
                Text("Preview")
            } else {
                Text("No preview")
            }
        }
        .font(.caption)
        .foregroundStyle(supportsPreview ? .green : .secondary)
    }

    private func toggle(_ id: String) {
        if selection.contains(id), selection.count > 1 {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
        clampSelection()
    }

    private func clampSelection() {
        selection = Set(ASRLanguageSelection.validatedIDs(Array(selection), supportedOptions: options))
    }
}
