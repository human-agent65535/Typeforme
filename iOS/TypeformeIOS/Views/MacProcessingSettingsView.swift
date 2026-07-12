import SwiftUI
import UIKit

private struct TimeoutSecondsRow: View {
    let title: String
    @Binding var seconds: Double
    let range: ClosedRange<Double>

    private let step = 0.5

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Button {
                    adjust(by: -step)
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .disabled(seconds <= range.lowerBound)
                .accessibilityLabel("Decrease \(title)")

                TextField(
                    "0.0",
                    value: clampedSeconds,
                    format: .number
                        .precision(.fractionLength(0...1))
                        .grouping(.never)
                )
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 64)

                Text("s")
                    .foregroundStyle(.secondary)

                Button {
                    adjust(by: step)
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .disabled(seconds >= range.upperBound)
                .accessibilityLabel("Increase \(title)")
            }
        }
    }

    private var clampedSeconds: Binding<Double> {
        Binding {
            seconds
        } set: { value in
            seconds = clamped(value)
        }
    }

    private func adjust(by delta: Double) {
        seconds = clamped(roundToStep(seconds + delta))
    }

    private func clamped(_ value: Double) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private func roundToStep(_ value: Double) -> Double {
        (value / step).rounded() * step
    }
}

private struct RecognitionSourceSettingsLabel: View {
    let title: String
    let source: RecognitionSource

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(source.qualitySpeedLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}

struct MacSettingsView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let onRepairPairing: () -> Void
    @State private var initialDraft: BridgeMacSettingsPayload?
    @State private var draft: BridgeMacSettingsPayload?
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showingDiscardConfirmation = false

    private var hasUnsavedChanges: Bool {
        guard let draft, let initialDraft else { return false }
        return !draft.hasSameEditableSettings(as: initialDraft)
    }

    private var macSettingsSaveButtonTitle: String {
        if selectedMacModelsNeedDownload {
            return NSLocalizedString("Save & Download", comment: "Save Mac settings and start model downloads on the Mac")
        }
        return NSLocalizedString("Save", comment: "Save Mac settings button")
    }

    private var visibleRecognitionSourceOptions: [BridgeSettingOption] {
        guard let draft else { return [] }
        return draft.recognitionSourceOptions
    }

    private var visibleEnabledRecognitionSources: [RecognitionSource] {
        guard let draft else { return [] }
        return draft.enabledSources
    }

    private var selectedMacModelsNeedDownload: Bool {
        selectedMacModelDownloadSummary != nil
    }

    private var visibleMacModelStatuses: [BridgeModelStatus] {
        guard let draft else { return [] }
        let selectedIDs = selectedMacModelStatusIDs(for: draft)
        return draft.modelStatuses.filter { selectedIDs.contains($0.id) || $0.installing }
    }

    private var selectedMacModelDownloadSummary: String? {
        guard let draft else { return nil }
        let statuses = draft.modelStatuses.reduce(into: [String: BridgeModelStatus]()) { result, status in
            result[status.id] = status
        }
        var missing: [String] = []
        for source in draft.enabledSources where source.hasModelConfiguration {
            let modelID = draft.asrModelID(for: source.rawValue)
            let status = statuses["asr:\(source.rawValue):\(modelID)"]
            if status?.installed != true {
                missing.append("\(source.displayName) model")
            }
        }
        if !isExternalCompatibleBackend(draft.correctionBackend) {
            let status = statuses["refine:\(draft.correctionBackend)"]
            if status?.installed != true {
                missing.append("refine model")
            }
        }
        guard !missing.isEmpty else { return nil }
        return "Save will start downloading on the Mac: \(missing.joined(separator: ", "))."
    }

    private func selectedMacModelStatusIDs(for draft: BridgeMacSettingsPayload) -> Set<String> {
        var ids = Set<String>()
        for source in draft.enabledSources where source.hasModelConfiguration {
            ids.insert("asr:\(source.rawValue):\(draft.asrModelID(for: source.rawValue))")
        }
        ids.insert("refine:\(draft.correctionBackend)")
        return ids
    }

    var body: some View {
        List {
            if let draft {
                Section {
                    Picker("Fast ASR Source", selection: fastASRSourceBinding) {
                        ForEach(visibleRecognitionSourceOptions) { option in
                            if let source = RecognitionSource(rawValue: option.id) {
                                Text(option.displayName).tag(source.rawValue)
                                    .disabled(!isFastASRSourceSelectable(source))
                            }
                        }
                    }
                    .pickerStyle(.menu)
                    if let issue = fastASRSourceIssue {
                        Text(issue)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Fast ASR")
                }

                Section {
                    ForEach(visibleRecognitionSourceOptions) { option in
                        if let source = RecognitionSource(rawValue: option.id) {
                            Toggle(isOn: recognitionSourceBinding(source)) {
                                RecognitionSourceSettingsLabel(
                                    title: option.displayName,
                                    source: source
                                )
                            }
                            .disabled(
                                isRecognitionSourceToggleDisabled(source)
                            )
                            if let reason = recognitionSourceDisabledReason(source) {
                                Text(reason)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    ForEach(visibleEnabledRecognitionSources.filter(\.hasModelConfiguration)) { source in
                        LabeledContent("\(source.displayName) Model") {
                            Text(asrModelDisplayName(for: source, in: draft))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                    }

                    TimeoutSecondsRow(
                        title: "ASR Timeout",
                        seconds: asrTimeoutSecondsBinding,
                        range: BridgeMacSettingsPayload.asrTimeoutSecondsRange
                    )

                    NavigationLink {
                        LanguageSelectionView(
                            selection: languageBinding,
                            options: draft.supportedLanguageOptionsForEnabledSources()
                        )
                    } label: {
                        HStack {
                            Text("Mac Default Languages")
                            Spacer()
                            Text(LanguageDisplay.summary(
                                for: Set(draft.languageIDs),
                                options: draft.supportedLanguageOptionsForEnabledSources()
                            ))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }
                    }
                } header: {
                    Text("Mac ASR")
                } footer: {
                    Text("Affects the paired Mac Bridge. Each ASR source is optional; dictation is unavailable when none are enabled.")
                }

                Section {
                    LabeledContent("Engine") {
                        Text(correctionBackendDisplayName(in: draft))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }

                    if isExternalCompatibleBackend(draft.correctionBackend) {
                        LabeledContent("External URL") {
                            Text(readOnlyExternalValue(draft.externalLLMBaseURL))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                        LabeledContent("External Model") {
                            Text(readOnlyExternalValue(draft.externalLLMModel))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                    }

                    TimeoutSecondsRow(
                        title: "Refine Timeout",
                        seconds: correctionTimeoutSecondsBinding,
                        range: BridgeMacSettingsPayload.correctionTimeoutSecondsRange
                    )

                    TimeoutSecondsRow(
                        title: "Model Startup Timeout",
                        seconds: correctionColdTimeoutSecondsBinding,
                        range: BridgeMacSettingsPayload.correctionColdTimeoutSecondsRange
                    )

                    Picker("Numbers", selection: numberOutputPreferenceBinding) {
                        ForEach(NumberOutputPreference.allCases) { preference in
                            Text(preference.title).tag(preference)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker("Punctuation", selection: punctuationPreferenceBinding) {
                        ForEach(PunctuationOutputPreference.allCases) { preference in
                            Text(preference.title).tag(preference)
                        }
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text("Mac Refine Engine")
                }

                Section("Vocabulary") {
                    NavigationLink {
                        ServerVocabularyView(entries: userDictionaryBinding)
                    } label: {
                        HStack {
                            Text("Dictation Vocabulary")
                            Spacer()
                            Text(vocabularySummary(for: draft.userDictionary))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                if !visibleMacModelStatuses.isEmpty {
                    Section {
                        ForEach(visibleMacModelStatuses) { status in
                            ModelStatusRow(status: status)
                        }
                    } header: {
                        Text("Models")
                    } footer: {
                        Text("Models live on the paired Mac. Selecting an uninstalled model triggers its download after Save.")
                    }
                }

            } else if isLoading || errorMessage == nil {
                Section {
                    HStack {
                        ProgressView()
                        Text("Loading dictation settings")
                    }
                }
            }

            if let errorMessage {
                Section {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)

                        VStack(spacing: 10) {
                            Button {
                                // load(force:) clears errorMessage itself.
                                Task { await load(force: true) }
                            } label: {
                                Label("Retry", systemImage: "arrow.clockwise")
                                    .frame(maxWidth: .infinity, minHeight: 38)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isLoading)

                            Button {
                                repairPairing(clearExisting: false)
                            } label: {
                                Label("Repair Pairing", systemImage: "qrcode.viewfinder")
                                    .frame(maxWidth: .infinity, minHeight: 38)
                            }
                            .buttonStyle(.bordered)

                            Button(role: .destructive) {
                                repairPairing(clearExisting: true)
                            } label: {
                                Label("Unpair", systemImage: "link.badge.minus")
                                    .frame(maxWidth: .infinity, minHeight: 38)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("Mac Processing")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(hasUnsavedChanges)
        .toolbar {
            // Decimal pads have no return key; without this the only way to
            // dismiss the keyboard is tapping a blank spot in the form.
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil,
                        from: nil,
                        for: nil
                    )
                }
            }
            ToolbarItem(placement: .cancellationAction) {
                if hasUnsavedChanges {
                    Button("Cancel") { showingDiscardConfirmation = true }
                        .disabled(isSaving)
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await finishEditing() }
                } label: {
                    HStack(spacing: 6) {
                        if isSaving {
                            ProgressView()
                                .scaleEffect(0.72)
                        }
                        Text(isSaving
                            ? NSLocalizedString("Saving…", comment: "Mac settings save in progress")
                            : macSettingsSaveButtonTitle)
                    }
                }
                .disabled(isSaving || !hasUnsavedChanges)
            }
        }
        .interactiveDismissDisabled(hasUnsavedChanges)
        .confirmationDialog(
            "Discard Mac settings changes?",
            isPresented: $showingDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("Discard Changes", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) { }
        } message: {
            Text("You have unsaved Mac settings changes that won't be pushed to the Mac.")
        }
        .task {
            await load(force: false)
        }
        .onAppear {
            state.isEditingMacSettings = true
        }
        .onDisappear {
            state.isEditingMacSettings = false
        }
    }

    private func repairPairing(clearExisting: Bool) {
        if clearExisting {
            Task {
                await state.unpair()
                dismiss()
                try? await Task.sleep(nanoseconds: 250_000_000)
                onRepairPairing()
            }
            return
        }
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            onRepairPairing()
        }
    }

    private func finishEditing() async {
        if hasUnsavedChanges {
            await save()
            if errorMessage == nil {
                dismiss()
            }
        } else {
            dismiss()
        }
    }

    private func recognitionSourceBinding(_ source: RecognitionSource) -> Binding<Bool> {
        Binding {
            return draft?.isRecognitionSourceEnabled(source) ?? false
        } set: { value in
            if value, isRecognitionSourceToggleDisabled(source) { return }
            updateDraft(normalize: true) { draft in
                draft.setRecognitionSource(source, enabled: value)
            }
        }
    }

    private var fastASRSourceBinding: Binding<String> {
        Binding {
            draft?.fastASRSource ?? RecognitionSource.qwen.rawValue
        } set: { value in
            updateDraft(normalize: true) { draft in
                draft.fastASRSource = value
            }
        }
    }

    private var fastASRSourceIssue: String? {
        guard let draft else { return nil }
        let readiness = draft.fastASRReadiness
        return readiness.ready ? nil : readiness.reason
    }

    private func isFastASRSourceSelectable(_ source: RecognitionSource) -> Bool {
        guard let draft else { return false }
        guard draft.isRecognitionSourceEnabled(source) else { return false }
        return draft.sourceAvailability(for: source)?.ready == true
    }

    private func isRecognitionSourceToggleDisabled(_ source: RecognitionSource) -> Bool {
        guard source == .appleSpeech,
              let draft,
              !draft.isRecognitionSourceEnabled(.appleSpeech)
        else { return false }
        return draft.sourceAvailability(for: .appleSpeech)?.canEnable != true
    }

    private func recognitionSourceDisabledReason(_ source: RecognitionSource) -> String? {
        guard source == .appleSpeech,
              let draft,
              !draft.isRecognitionSourceEnabled(.appleSpeech),
              draft.sourceAvailability(for: .appleSpeech)?.canEnable != true
        else { return nil }
        return draft.sourceAvailability(for: .appleSpeech)?.reason
    }

    private func asrModelDisplayName(for source: RecognitionSource, in draft: BridgeMacSettingsPayload) -> String {
        let modelID = draft.asrModelID(for: source.rawValue)
        return draft.asrModelOptions(for: source.rawValue).first { $0.id == modelID }?.displayName
            ?? source.displayName
    }

    private func correctionBackendDisplayName(in draft: BridgeMacSettingsPayload) -> String {
        draft.correctionBackendOptions.first { $0.id == draft.correctionBackend }?.displayName
            ?? draft.correctionBackend
    }

    private func readOnlyExternalValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Not set" : trimmed
    }

    private func isExternalCompatibleBackend(_ backend: String) -> Bool {
        backend == "external_openai_compatible" || backend == "external_anthropic_compatible"
    }

    private var asrTimeoutSecondsBinding: Binding<Double> {
        Binding {
            draft?.asrTimeoutSec ?? 40
        } set: { value in
            updateDraft { draft in
                draft.asrTimeoutSec = BridgeMacSettingsPayload.clampedASRTimeoutSec(value)
            }
        }
    }

    private var correctionTimeoutSecondsBinding: Binding<Double> {
        Binding {
            Double(draft?.correctionTimeoutMs ?? 1500) / 1000
        } set: { value in
            updateDraft { draft in
                draft.correctionTimeoutMs = BridgeMacSettingsPayload.correctionTimeoutMs(fromSeconds: value)
            }
        }
    }

    private var correctionColdTimeoutSecondsBinding: Binding<Double> {
        Binding {
            Double(draft?.correctionColdTimeoutMs ?? 8000) / 1000
        } set: { value in
            updateDraft { draft in
                draft.correctionColdTimeoutMs = BridgeMacSettingsPayload.correctionColdTimeoutMs(fromSeconds: value)
            }
        }
    }

    private var numberOutputPreferenceBinding: Binding<NumberOutputPreference> {
        Binding {
            draft?.numberOutputPreference ?? .automatic
        } set: { value in
            updateDraft { draft in
                draft.numberOutputPreference = value
            }
        }
    }

    private var punctuationPreferenceBinding: Binding<PunctuationOutputPreference> {
        Binding {
            draft?.punctuationPreference ?? .normal
        } set: { value in
            updateDraft { draft in
                draft.punctuationPreference = value
            }
        }
    }

    private var languageBinding: Binding<Set<String>> {
        Binding {
            Set(draft?.languageIDs ?? [])
        } set: { value in
            guard var current = draft else { return }
            current.languageIDs = ASRLanguageSelection.validatedIDs(
                Array(value),
                supportedOptions: current.supportedLanguageOptionsForEnabledSources()
            )
            draft = current
        }
    }

    private var userDictionaryBinding: Binding<[DictionaryEntry]> {
        Binding {
            draft?.userDictionary ?? []
        } set: { value in
            updateDraft(normalize: true) { draft in
                draft.userDictionary = value
            }
        }
    }

    private func updateDraft(
        normalize: Bool = false,
        _ mutate: (inout BridgeMacSettingsPayload) -> Void
    ) {
        guard var current = draft else { return }
        mutate(&current)
        if normalize {
            current.normalize()
        }
        draft = current
    }

    private func load(force: Bool) async {
        guard force || draft == nil else { return }
        isLoading = true
        errorMessage = nil
        do {
            let loaded = try await state.refreshMacSettings()
            draft = loaded
            initialDraft = loaded
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func save() async {
        guard let draft else { return }
        isSaving = true
        errorMessage = nil
        do {
            let updated = try await state.updateMacSettings(draft)
            self.draft = updated
            initialDraft = updated
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }

    private func vocabularySummary(for entries: [DictionaryEntry]) -> String {
        entries.count == 1 ? "1 entry" : "\(entries.count) entries"
    }
}

/// One Mac-side model with install state. `detail` carries the Mac's
/// human-readable status (progress, failure reason) and is shown verbatim.
private struct ModelStatusRow: View {
    let status: BridgeModelStatus

    var body: some View {
        HStack(spacing: 10) {
            statusIcon
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.displayName)
                    .font(.subheadline)
                if !detailText.isEmpty {
                    Text(detailText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Text(status.kind == "asr" ? "ASR" : "Refine")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color(.tertiarySystemFill)))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var detailText: String {
        status.detail.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    private var statusIcon: some View {
        if status.installing {
            ProgressView()
                .controlSize(.small)
        } else if status.installed {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            Image(systemName: "arrow.down.circle.dotted")
                .foregroundStyle(.orange)
        }
    }
}

private struct ServerVocabularyView: View {
    @Binding var entries: [DictionaryEntry]
    @State private var newSurface = ""
    @State private var selectedType = "person"
    @State private var customType = ""
    @FocusState private var isNewSurfaceFocused: Bool

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("New word or phrase", text: $newSurface)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($isNewSurfaceFocused)

                    HStack(spacing: 10) {
                        Picker("Type", selection: $selectedType) {
                            ForEach(DictionaryEntry.suggestedTypes, id: \.self) { type in
                                Text(DictionaryEntry.displayType(for: type)).tag(type)
                            }
                            Text("custom").tag("custom")
                        }
                        .pickerStyle(.menu)

                        if selectedType == "custom" {
                            TextField("Custom type", text: $customType)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }

                        Button {
                            addEntry()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.title3)
                        }
                        .buttonStyle(.borderless)
                        .disabled(!canAddEntry)
                    }
                }
            }

            Section(entriesHeader) {
                if entries.isEmpty {
                    Text("No vocabulary entries")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(entries) { entry in
                        NavigationLink {
                            ServerVocabularyEntryEditorView(entry: entry) { updated in
                                updateEntry(updated)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.surface)
                                    .foregroundStyle(.primary)
                                Text(entry.displayType)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete(perform: deleteEntries)
                }
            }
        }
        .navigationTitle("Dictation Vocabulary")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
        .onChange(of: entries) { _, value in
            let normalized = DictionaryEntry.normalizedEntries(value)
            if normalized != value {
                entries = normalized
            }
        }
    }

    private var entriesHeader: String {
        entries.count == 1 ? "1 Entry" : "\(entries.count) Entries"
    }

    private var resolvedType: String {
        selectedType == "custom" ? customType : selectedType
    }

    private var canAddEntry: Bool {
        !DictionaryEntry.cleanedSurface(newSurface).isEmpty &&
            (selectedType != "custom" || !customType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func addEntry() {
        let surface = DictionaryEntry.cleanedSurface(newSurface)
        guard !surface.isEmpty else { return }
        let entry = DictionaryEntry(
            type: resolvedType,
            surface: surface
        )
        entries = DictionaryEntry.normalizedEntries(entries + [entry])
        newSurface = ""
        isNewSurfaceFocused = true
    }

    private func deleteEntries(at offsets: IndexSet) {
        entries.remove(atOffsets: offsets)
    }

    private func updateEntry(_ updated: DictionaryEntry) {
        guard let index = entries.firstIndex(where: { $0.id == updated.id }) else { return }
        entries[index] = updated
        entries = DictionaryEntry.normalizedEntries(entries)
    }
}

private struct ServerVocabularyEntryEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let entry: DictionaryEntry
    let onSave: (DictionaryEntry) -> Void
    @State private var surface = ""
    @State private var selectedType = "other"
    @State private var customType = ""

    var body: some View {
        Form {
            Section("Word") {
                TextField("Word or phrase", text: $surface)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section("Type") {
                Picker("Type", selection: typeSelectionBinding) {
                    ForEach(DictionaryEntry.suggestedTypes, id: \.self) { type in
                        Text(DictionaryEntry.displayType(for: type)).tag(type)
                    }
                    Text("custom").tag("custom")
                }
                .pickerStyle(.menu)

                if selectedType == "custom" {
                    TextField("Custom type", text: customTypeBinding)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
        }
        .navigationTitle("Vocabulary Entry")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: syncTypeState)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    save()
                }
                .disabled(!canSave)
            }
        }
    }

    private var typeSelectionBinding: Binding<String> {
        Binding {
            selectedType
        } set: { value in
            selectedType = value
            if value == "custom" {
                customType = customType.isEmpty ? entry.type : customType
            } else {
                customType = ""
            }
        }
    }

    private var customTypeBinding: Binding<String> {
        Binding {
            customType
        } set: { value in
            customType = value
        }
    }

    private var resolvedType: String {
        selectedType == "custom" ? customType : selectedType
    }

    private var canSave: Bool {
        !DictionaryEntry.cleanedSurface(surface).isEmpty &&
            (selectedType != "custom" || !customType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func syncTypeState() {
        surface = entry.surface
        if DictionaryEntry.suggestedTypes.contains(entry.type) {
            selectedType = entry.type
            customType = ""
        } else {
            selectedType = "custom"
            customType = entry.type
        }
    }

    private func save() {
        guard canSave else { return }
        onSave(DictionaryEntry(
            id: entry.id,
            type: resolvedType,
            surface: surface
        ))
        dismiss()
    }

}

// MARK: - Chinese learning inspector

/// Read-only view of the phrases rime's self-learning has been fed. The
/// keyboard mirrors every committed multi-character Chinese phrase into the
/// App Group; the librime user dictionary itself lives in the extension
/// sandbox and cannot be read from the host.

