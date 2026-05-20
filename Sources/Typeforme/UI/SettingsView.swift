import SwiftUI

/// Settings UI with a stable custom sidebar. Avoids the system
/// NavigationSplitView sidebar-toggle button, which can float into the
/// titlebar for this LSUIElement-hosted settings window.
///
/// Top-level sections are kept at ≤5 to match Apple's System Settings
/// information density. Older Correction / Prompts / Vocabulary became
/// sub-tabs of `Modes`; ASR / Diagnostics became sub-tabs of `Advanced`;
/// the mode-specific Server / Bridge tabs merged into a single
/// `Connection` view that swaps content based on processingMode.
struct SettingsView: View {
    @ObservedObject var dictionary: UserDictionaryStore
    @State private var selection: Section = .general
    @AppStorage(AppSettings.Keys.processingMode) private var processingModeRaw = ProcessingMode.client.rawValue

    enum Section: String, CaseIterable, Identifiable, Hashable {
        case general    = "General"
        case modes      = "Modes"
        case recording  = "Recording"
        case connection = "Connection"
        case advanced   = "Advanced"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .general:    return "gearshape"
            case .modes:      return "text.badge.checkmark"
            case .recording:  return "waveform.circle"
            case .connection: return "antenna.radiowaves.left.and.right"
            case .advanced:   return "slider.horizontal.3"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 178)
                .background(Color(NSColor.controlBackgroundColor))

            Divider()

            VStack(spacing: 0) {
                HStack {
                    Text(LocalizedStringKey(effectiveSelection.rawValue))
                        .font(.title2.weight(.semibold))
                    Spacer()
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 14)

                Divider()

                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .onChange(of: processingModeRaw) { _, _ in
            if !visibleSections.contains(selection) {
                selection = .general
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(visibleSections) { section in
                Button {
                    selection = section
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: section.icon)
                            .frame(width: 18)
                        Text(LocalizedStringKey(section.rawValue))
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(selection == section ? Color.accentColor.opacity(0.18) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(selection == section ? Color.primary : Color.secondary)
            }
            Spacer()
        }
        .padding(10)
    }

    @ViewBuilder
    private var detail: some View {
        switch effectiveSelection {
        case .general:    GeneralSettingsView()
        case .modes:      ModesSettingsView(dictionary: dictionary)
        case .recording:  RecordingSettingsView()
        case .connection: ConnectionSettingsView()
        case .advanced:   AdvancedSettingsView()
        }
    }

    private var processingMode: ProcessingMode {
        ProcessingMode(rawValue: processingModeRaw) ?? .client
    }

    /// Modes (correction / prompts / vocabulary) is server-only — client
    /// installs talk to a remote bridge that owns those settings.
    private var visibleSections: [Section] {
        switch processingMode {
        case .server:
            return [.general, .modes, .recording, .connection, .advanced]
        case .client:
            return [.general, .recording, .connection, .advanced]
        }
    }

    private var effectiveSelection: Section {
        visibleSections.contains(selection) ? selection : .general
    }
}

// MARK: - Wrapper views

/// Inner segmented tab for grouping related per-section views together
/// without exploding the top-level sidebar. Identical visual treatment
/// across `Modes`, `Connection`, and `Advanced`.
private struct SubsectionPicker<Choice: Hashable & CaseIterable & RawRepresentable>: View
    where Choice.RawValue == String, Choice.AllCases: RandomAccessCollection
{
    @Binding var selection: Choice

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(Array(Choice.allCases), id: \.self) { choice in
                // Wrap in LocalizedStringKey so runtime rawValue lookups
                // hit the .strings table; bare Text(String) doesn't.
                Text(LocalizedStringKey(choice.rawValue)).tag(choice)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
    }
}

/// Correction + Prompts + Vocabulary collapsed into one sidebar entry.
/// Each retains its full original view; they just share a segmented
/// switcher at the top of the detail pane.
struct ModesSettingsView: View {
    @ObservedObject var dictionary: UserDictionaryStore
    @State private var subsection: Subsection = .correction

    enum Subsection: String, CaseIterable, Hashable {
        case correction = "Correction"
        case prompts    = "Prompts"
        case vocabulary = "Vocabulary"
    }

    var body: some View {
        VStack(spacing: 0) {
            SubsectionPicker(selection: $subsection)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch subsection {
        case .correction: CorrectionSettingsView()
        case .prompts:    PromptsSettingsView()
        case .vocabulary: DictionarySettingsView(store: dictionary)
        }
    }
}

/// Single "Connection" entry that morphs based on the active processing
/// mode: server installs see the Bridge config (model download, public
/// URL); client installs see the remote bridge URL + sync settings.
struct ConnectionSettingsView: View {
    @AppStorage(AppSettings.Keys.processingMode) private var processingModeRaw = ProcessingMode.client.rawValue

    var body: some View {
        switch ProcessingMode(rawValue: processingModeRaw) ?? .client {
        case .server: BridgeSettingsView()
        case .client: ClientServerSettingsView()
        }
    }
}

/// ASR + Diagnostics. ASR is server-only so the picker collapses on
/// client installs to a single Diagnostics view.
struct AdvancedSettingsView: View {
    @AppStorage(AppSettings.Keys.processingMode) private var processingModeRaw = ProcessingMode.client.rawValue
    @State private var subsection: Subsection = .asr

    enum Subsection: String, CaseIterable, Hashable {
        case asr         = "ASR"
        case diagnostics = "Diagnostics"
    }

    var body: some View {
        switch ProcessingMode(rawValue: processingModeRaw) ?? .client {
        case .server:
            VStack(spacing: 0) {
                SubsectionPicker(selection: $subsection)
                Divider()
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .client:
            DiagnosticsSettingsView()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch subsection {
        case .asr:         ASRSettingsView()
        case .diagnostics: DiagnosticsSettingsView()
        }
    }
}
