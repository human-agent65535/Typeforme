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
    let livePreviewEnabled: Bool
    let livePreviewRecognitionMode: KeyboardLivePreviewRecognitionMode?
    private let previewCapabilityByLanguageID: [String: AppleSpeechPreviewCapability]
    @State private var searchText = ""

    init(
        selection: Binding<Set<String>>,
        options: [ASRLanguageOption] = ASRLanguageSelection.all,
        livePreviewEnabled: Bool = true,
        livePreviewRecognitionMode: KeyboardLivePreviewRecognitionMode? = nil
    ) {
        let resolvedOptions = options.isEmpty ? ASRLanguageSelection.all : options
        self._selection = selection
        self.options = resolvedOptions
        self.livePreviewEnabled = livePreviewEnabled
        self.livePreviewRecognitionMode = livePreviewRecognitionMode
        if livePreviewRecognitionMode != nil {
            self.previewCapabilityByLanguageID = Dictionary(
                uniqueKeysWithValues: resolvedOptions.map { option in
                    (option.id, AppleSpeechPreviewSupport.capability(languageID: option.id))
                }
            )
        } else {
            self.previewCapabilityByLanguageID = [:]
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

                Section {
                    ForEach(otherLanguages) { option in
                        languageRow(option)
                    }
                } header: {
                    Text("Supported Languages")
                } footer: {
                    previewGuideFooter
                }
            } else {
                Section {
                    ForEach(filteredLanguages) { option in
                        languageRow(option)
                    }
                } header: {
                    Text("Matches")
                } footer: {
                    previewGuideFooter
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

    @ViewBuilder
    private var previewGuideFooter: some View {
        if livePreviewRecognitionMode != nil {
            Text("On-device preview availability is reported by iOS. Manage Dictation languages and system updates in iOS Settings.")
        }
    }

    private func languageRow(_ option: ASRLanguageOption) -> some View {
        let previewCapability = previewCapabilityByLanguageID[option.id] ?? .unsupported
        return Button {
            toggle(option.id)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.displayName)
                    Text(option.id)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let livePreviewRecognitionMode {
                        previewBadge(
                            capability: previewCapability,
                            livePreviewEnabled: livePreviewEnabled,
                            recognitionMode: livePreviewRecognitionMode
                        )
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

    private func previewBadge(
        capability: AppleSpeechPreviewCapability,
        livePreviewEnabled: Bool,
        recognitionMode: KeyboardLivePreviewRecognitionMode
    ) -> some View {
        let isActive = livePreviewEnabled && recognitionMode.canUse(capability)
        return HStack(spacing: 4) {
            Image(systemName: previewBadgeIcon(capability: capability))
            switch capability {
            case .onDevice:
                Text("On-device")
            case .cloud:
                Text("Cloud")
            case .unsupported:
                Text("No preview")
            }
        }
        .font(.caption)
        .foregroundStyle(previewBadgeColor(capability: capability, isActive: isActive))
    }

    private func previewBadgeIcon(capability: AppleSpeechPreviewCapability) -> String {
        switch capability {
        case .onDevice:
            return "lock.shield.fill"
        case .cloud:
            return "icloud"
        case .unsupported:
            return "waveform.circle"
        }
    }

    private func previewBadgeColor(capability: AppleSpeechPreviewCapability, isActive: Bool) -> Color {
        guard isActive else { return .secondary }
        switch capability {
        case .onDevice:
            return .green
        case .cloud:
            return .orange
        case .unsupported:
            return .secondary
        }
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
