import Foundation
import SwiftUI

struct KeyboardSettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        List {
            Section {
                Toggle("Enable Chinese Input", isOn: chineseInputEnabledBinding)
            } footer: {
                Text("Turn off to make the text keyboard English-only and hide the Chinese/English switch key.")
            }
            Section {
                Picker("Dictionary", selection: rimeDictionaryTierBinding) {
                    ForEach(KeyboardRimeDictionaryTier.allCases) { tier in
                        Text(tier.title).tag(tier)
                    }
                }
                Toggle("Pinyin Correction", isOn: rimeCorrectionBinding)
                Picker("Default text input", selection: defaultTextInputLanguageBinding) {
                    ForEach(KeyboardDefaultTextInputLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
                Picker("Punctuation", selection: chinesePunctuationBinding) {
                    ForEach(KeyboardChinesePunctuationStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
            } header: {
                Text("Chinese Input")
            } footer: {
                Text("Changes apply immediately after Full Access is enabled.")
            }
            .disabled(!state.keyboardChineseInputEnabled)
            Section {
                Toggle("Character Preview", isOn: characterPreviewBinding)
            } header: {
                Text("Typing")
            }
            Section {
                Toggle("Key Sound", isOn: keySoundBinding)
                Toggle("Key Haptics", isOn: keyHapticsBinding)
            } header: {
                Text("Feedback")
            } footer: {
                Text("Key sound also follows the system keyboard click setting in Settings → Sounds & Haptics.")
            }
            Section {
                Toggle("Auto-Capitalization", isOn: autoCapitalizationBinding)
            } header: {
                Text("English")
            } footer: {
                Text("Only active when the keyboard is in English mode.")
            }
            Section {
                NavigationLink {
                    KeyboardLearningSettingsView()
                } label: {
                    SettingsRowLabel(
                        icon: "chart.line.uptrend.xyaxis",
                        title: "Learning",
                        detail: "Chinese dictionary and touch adaptation"
                    )
                }
            }
        }
        .navigationTitle("Text Keyboard")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var autoCapitalizationBinding: Binding<Bool> {
        Binding {
            state.keyboardAutoCapitalizationEnabled
        } set: { enabled in
            state.setKeyboardAutoCapitalizationEnabled(enabled)
        }
    }

    private var characterPreviewBinding: Binding<Bool> {
        Binding {
            state.keyboardCharacterPreviewEnabled
        } set: { enabled in
            state.setKeyboardCharacterPreviewEnabled(enabled)
        }
    }

    private var keySoundBinding: Binding<Bool> {
        Binding {
            state.keyboardKeySoundEnabled
        } set: { enabled in
            state.setKeyboardKeySoundEnabled(enabled)
        }
    }

    private var keyHapticsBinding: Binding<Bool> {
        Binding {
            state.keyboardKeyHapticsEnabled
        } set: { enabled in
            state.setKeyboardKeyHapticsEnabled(enabled)
        }
    }

    private var rimeDictionaryTierBinding: Binding<KeyboardRimeDictionaryTier> {
        Binding {
            state.keyboardRimeDictionaryTier
        } set: { tier in
            state.setKeyboardRimeDictionaryTier(tier)
        }
    }

    private var chineseInputEnabledBinding: Binding<Bool> {
        Binding {
            state.keyboardChineseInputEnabled
        } set: { enabled in
            state.setKeyboardChineseInputEnabled(enabled)
        }
    }

    private var rimeCorrectionBinding: Binding<Bool> {
        Binding {
            state.keyboardRimeCorrectionEnabled
        } set: { enabled in
            state.setKeyboardRimeCorrectionEnabled(enabled)
        }
    }

    private var defaultTextInputLanguageBinding: Binding<KeyboardDefaultTextInputLanguage> {
        Binding {
            state.keyboardDefaultTextInputLanguage
        } set: { language in
            state.setKeyboardDefaultTextInputLanguage(language)
        }
    }

    private var chinesePunctuationBinding: Binding<KeyboardChinesePunctuationStyle> {
        Binding {
            state.keyboardChinesePunctuationStyle
        } set: { style in
            state.setKeyboardChinesePunctuationStyle(style)
        }
    }

}

private struct KeyboardLearningSettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        List {
            Section {
                Toggle("Chinese self-learning", isOn: rimeLearningBinding)
                    .disabled(!state.keyboardChineseInputEnabled)
                NavigationLink {
                    ChineseLearningStatsView()
                } label: {
                    Text("Chinese Learning Data")
                }
                Button(role: .destructive) {
                    state.resetKeyboardRimeLearning()
                } label: {
                    Text("Reset Chinese Learning")
                }
                .disabled(!state.keyboardChineseInputEnabled)
            } header: {
                Text("Chinese")
            } footer: {
                Text("Self-learning controls Rime's user dictionary.")
            }

            Section {
                Toggle("Touch learning", isOn: touchLearningBinding)
                NavigationLink {
                    TouchLearningStatsView()
                } label: {
                    Text("Touch Learning Data")
                }
                Button(role: .destructive) {
                    state.resetKeyboardTouchLearning()
                } label: {
                    Text("Reset Touch Learning")
                }
            } header: {
                Text("Touch")
            } footer: {
                Text("Touch learning adapts per-key tap offsets. When off, text keys use fixed midpoint hit routing.")
            }
        }
        .navigationTitle("Learning")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var rimeLearningBinding: Binding<Bool> {
        Binding {
            state.keyboardRimeLearningEnabled
        } set: { enabled in
            state.setKeyboardRimeLearningEnabled(enabled)
        }
    }

    private var touchLearningBinding: Binding<Bool> {
        Binding {
            state.keyboardTouchLearningEnabled
        } set: { enabled in
            state.setKeyboardTouchLearningEnabled(enabled)
        }
    }
}

struct LivePreviewSettingsSection: View {
    @Environment(AppState.self) private var state
    let title: LocalizedStringKey

    init(
        title: LocalizedStringKey = "iPhone Keyboard Preview"
    ) {
        self.title = title
    }

    var body: some View {
        Section {
            Toggle("Live Preview", isOn: livePreviewBinding)
                .disabled(state.isBusy || sourceOptions.isEmpty)
            if sourceOptions.count > 1 {
                Picker("Preview Source", selection: livePreviewSourceBinding) {
                    ForEach(sourceOptions) { source in
                        Text(sourceTitle(source))
                            .tag(source)
                    }
                }
                .pickerStyle(.menu)
                .disabled(!state.keyboardLivePreviewEnabled || state.isBusy)
            } else if let source = sourceOptions.first {
                LabeledContent("Preview Source") {
                    Text(sourceTitle(source))
                        .foregroundStyle(.secondary)
                }
                .disabled(!state.keyboardLivePreviewEnabled || state.isBusy)
            }
            if effectivePreviewSource == .appleSpeech {
                Picker("Preview Recognition", selection: livePreviewRecognitionModeBinding) {
                    ForEach(KeyboardLivePreviewRecognitionMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .disabled(!state.keyboardLivePreviewEnabled || state.isBusy)
            } else {
                LabeledContent("Preview Recognition") {
                    Text("Server-side")
                        .foregroundStyle(.secondary)
                }
                .disabled(!state.keyboardLivePreviewEnabled)
            }
        } header: {
            Text(title)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("This preview setting is local to the iPhone keyboard and applies immediately. It does not change the Mac live transcript setting.")
                Text(livePreviewFooter)
            }
        }
    }

    private var sourceOptions: [KeyboardLivePreviewSource] {
        state.keyboardLivePreviewSourceOptions
    }

    private var effectivePreviewSource: KeyboardLivePreviewSource? {
        if state.config.correctionMode == .fast {
            guard let macSettings = state.macSettings,
                  macSettings.fastASRReadiness.ready
            else { return nil }
            switch macSettings.fastRecognitionSource {
            case .appleSpeech:
                return .appleSpeech
            case .qwen:
                return .qwen
            case .nvidiaNemotron:
                return .nvidiaNemotron
            }
        }
        if sourceOptions.contains(state.keyboardLivePreviewSource) {
            return state.keyboardLivePreviewSource
        }
        return sourceOptions.first
    }

    private var livePreviewFooter: LocalizedStringKey {
        guard let source = effectivePreviewSource else {
            return "No live preview source is available for the current mode."
        }
        switch source {
        case .appleSpeech:
            return "Apple Speech preview runs on this iPhone."
        case .qwen:
            return "Qwen3-ASR preview runs on the Mac."
        case .nvidiaNemotron:
            return "NVIDIA Nemotron preview runs on the Mac."
        }
    }

    private func sourceTitle(_ source: KeyboardLivePreviewSource) -> String {
        source.title
    }

    private var livePreviewBinding: Binding<Bool> {
        Binding {
            state.keyboardLivePreviewEnabled
        } set: { enabled in
            state.setKeyboardLivePreviewEnabled(enabled)
        }
    }

    private var livePreviewSourceBinding: Binding<KeyboardLivePreviewSource> {
        Binding {
            effectivePreviewSource ?? state.keyboardLivePreviewSource
        } set: { source in
            guard sourceOptions.contains(source) else { return }
            state.setKeyboardLivePreviewSource(source)
        }
    }

    private var livePreviewRecognitionModeBinding: Binding<KeyboardLivePreviewRecognitionMode> {
        Binding {
            state.keyboardLivePreviewRecognitionMode
        } set: { mode in
            state.setKeyboardLivePreviewRecognitionMode(mode)
        }
    }
}

struct KeyboardGuideView: View {
    var body: some View {
        List {
            Section("Write Anywhere") {
                GuideStepRow(
                    icon: "mic.fill",
                    title: "Dictate",
                    detail: "Use Hold or Tap on the mic. With no selection, the result inserts at the cursor."
                )
                GuideStepRow(
                    icon: "keyboard",
                    title: "Text keyboard",
                    detail: "Tap the keyboard or mic button, or swipe sideways, to switch between voice and normal typing."
                )
                GuideStepRow(
                    icon: "text.cursor",
                    title: "Fix selected text",
                    detail: "Select text first, then dictate the replacement. Typeforme only replaces that selected span."
                )
                GuideStepRow(
                    icon: "wand.and.stars",
                    title: "Command edit",
                    detail: "Use the wand to say an edit instruction, like shorten, translate, or turn into bullets."
                )
            }

            Section("Refine") {
                GuideStepRow(
                    icon: "paintbrush",
                    title: "Refine existing text",
                    detail: "Use the style picker to rewrite selected text, a recent selection, or nearby input text."
                )
                GuideStepRow(
                    icon: "arrow.uturn.backward",
                    title: "Undo or cancel",
                    detail: "Undo restores the last refine. During recording, the same control cancels instead."
                )
                GuideStepRow(
                    icon: "exclamationmark.triangle",
                    title: "Result safety",
                    detail: "If the original target changes before the result returns, Typeforme copies the result instead of guessing."
                )
            }

            Section {
                GuideStepRow(
                    icon: "bolt.fill",
                    title: "Fast",
                    detail: "Insert the ASR transcript directly and skip refine."
                )
                GuideStepRow(
                    icon: "checkmark.circle",
                    title: "Clean",
                    detail: "Remove filler words and fix punctuation, spacing, and clear ASR mistakes."
                )
                GuideStepRow(
                    icon: "paintbrush.fill",
                    title: "Polish+",
                    detail: "Rewrite naturally while preserving intent and tone."
                )
                GuideStepRow(
                    icon: "list.bullet.rectangle",
                    title: "Structure+",
                    detail: "Restructure multi-item content while preserving intent."
                )
                GuideStepRow(
                    icon: "doc.text",
                    title: "Formal+",
                    detail: "Rewrite into professional prose while preserving intent."
                )
            } header: {
                Text("Modes")
            }

            Section("Preview & Settings") {
                GuideStepRow(
                    icon: "waveform",
                    title: "Live Preview",
                    detail: "Preview can show partial text while you speak. Choose its source in Voice Dictation settings."
                )
                GuideStepRow(
                    icon: "slider.horizontal.3",
                    title: "More settings",
                    detail: "iPhone preferences live under Voice Dictation and Text Keyboard. Mac recognition and refine options live under Connected Mac."
                )
                GuideStepRow(
                    icon: "exclamationmark.bubble",
                    title: "Issues",
                    detail: "Keyboard issues are also recorded in the host app, so you can review them after typing."
                )
            }
        }
        .navigationTitle("Keyboard Guide")
    }
}

private struct GuideStepRow: View {
    let icon: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.headline)
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct ChineseLearningStatsView: View {
    @State private var snapshot: KeyboardChineseLearningSnapshot?

    var body: some View {
        List {
            if let snapshot, !snapshot.entries.isEmpty {
                Section {
                    ForEach(snapshot.entries, id: \.text) { entry in
                        HStack {
                            Text(entry.text)
                            Spacer()
                            Text("\(entry.count)×")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(Self.relativeDate(entry.lastUsedAt))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .frame(minWidth: 64, alignment: .trailing)
                        }
                    }
                }
            } else {
                Section {
                    Text("No learning data yet.")
                    Text("Type Chinese on the Typeforme keyboard (Full Access required). Committed phrases of two or more characters appear here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Chinese Learning")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh learning data")
            }
        }
        .refreshable { reload() }
        .onAppear { reload() }
    }

    private func reload() {
        snapshot = KeyboardSharedDefaults.loadChineseLearningSnapshot()
    }

    private static func relativeDate(_ timestamp: TimeInterval) -> String {
        guard timestamp > 0 else { return "—" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: Date(timeIntervalSince1970: timestamp), relativeTo: Date())
    }
}

// MARK: - Touch learning inspector

/// Read-only view of the keyboard's per-key touch-offset learning. The
/// keyboard mirrors throttled stats into the App Group; without this view the
/// model was invisible and impossible to verify.
private struct TouchLearningStatsView: View {
    @State private var snapshot: KeyboardTouchLearningSnapshot?
    @State private var displayMode: TouchLearningDisplayMode = .centers

    private enum TouchLearningDisplayMode: String, CaseIterable, Identifiable {
        case centers = "Centers"
        case gaps = "Gaps"
        case bands = "Bands"

        var id: String { rawValue }

        var footerText: String {
            switch self {
            case .centers:
                return "The dot is where your taps for that key actually land (key tint = confidence). A dot off center means the keyboard is compensating for your finger's bias on that key."
            case .gaps:
                return "Gap colors show the spatial fallback route for the empty area between two keys. Chinese composing can still prefer Rime's pinyin-valid key before this fallback runs."
            case .bands:
                return "Orange strips show the narrow visible-key edge band where the learned spatial model can override geometric routing. Key centers remain anchored."
            }
        }
    }

    private enum GapWinner {
        case left
        case right
        case fallback
    }

    private struct GapDecision {
        let leftKey: String
        let rightKey: String
        let winner: GapWinner
        let leftSamples: Double
        let rightSamples: Double
        let leftBias: Double
        let rightBias: Double
        let margin: Double

        var routedKey: String? {
            switch winner {
            case .left:
                return leftKey
            case .right:
                return rightKey
            case .fallback:
                return nil
            }
        }
    }

    private static let keyRows: [[String]] = [
        ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
        ["a", "s", "d", "f", "g", "h", "j", "k", "l"],
        ["z", "x", "c", "v", "b", "n", "m"],
    ]
    /// Mirrors KeyboardTouchGapPolicy.fullConfidenceSamples: the sample count at
    /// which the keyboard trusts a key's learned mean at full weight. The dot
    /// in the map shows the *effective* offset (mean × confidence) — exactly
    /// what touch routing uses.
    private static let gutterRadiusPoints: CGFloat = 6
    private static let representativeKeyWidthPoints: CGFloat = 33
    private static let cellWidth: CGFloat = 30
    private static let cellHeight: CGFloat = 42
    private static let cellGapWidth: CGFloat = 8
    private static var edgeBandWidth: CGFloat {
        min(cellWidth * 0.35, max(3, cellWidth * gutterRadiusPoints / representativeKeyWidthPoints))
    }

    var body: some View {
        List {
            if let snapshot, !snapshot.keys.isEmpty {
                Section {
                    LabeledContent("Keys learned", value: "\(snapshot.keys.count)")
                    LabeledContent("Samples", value: "\(totalSamples(snapshot))")
                    LabeledContent("Updated", value: Self.relativeDate(snapshot.updatedAt))
                }
                Section {
                    Picker("Map", selection: $displayMode) {
                        ForEach(TouchLearningDisplayMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    keyboardMap(snapshot, mode: displayMode)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                } header: {
                    Text("Touch map")
                } footer: {
                    Text(displayMode.footerText)
                }
                if displayMode == .gaps {
                    Section("Pairwise gaps") {
                        ForEach(gapDecisions(snapshot), id: \.leftKey) { decision in
                            gapDecisionRow(decision)
                        }
                    }
                }
                Section("Per-key offsets") {
                    ForEach(sortedEntries(snapshot), id: \.0) { key, stats in
                        statsRow(key: key, stats: stats)
                    }
                }
            } else {
                Section {
                    Text("No learning data yet.")
                    Text("Type on the Typeforme keyboard (Full Access required). Accepted keys and backspace-corrections feed the model; data appears here after a few keystrokes.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Touch Learning")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh learning data")
            }
        }
        .refreshable { reload() }
        .onAppear { reload() }
    }

    private func reload() {
        snapshot = KeyboardSharedDefaults.loadTouchLearningSnapshot()
    }

    private func totalSamples(_ snapshot: KeyboardTouchLearningSnapshot) -> Int {
        Int(snapshot.keys.values.reduce(0) { $0 + $1.sampleCount }.rounded())
    }

    private func gapDecisions(_ snapshot: KeyboardTouchLearningSnapshot) -> [GapDecision] {
        Self.keyRows.flatMap { row in
            row.indices.dropLast().map { index in
                gapDecision(left: row[index], right: row[index + 1], snapshot: snapshot)
            }
        }
    }

    private func sortedEntries(_ snapshot: KeyboardTouchLearningSnapshot) -> [(String, KeyboardTouchLearningKeyStats)] {
        snapshot.keys.sorted { lhs, rhs in
            if lhs.value.sampleCount != rhs.value.sampleCount {
                return lhs.value.sampleCount > rhs.value.sampleCount
            }
            return lhs.key < rhs.key
        }
    }

    private func keyboardMap(_ snapshot: KeyboardTouchLearningSnapshot, mode: TouchLearningDisplayMode) -> some View {
        VStack(spacing: 5) {
            ForEach(Self.keyRows, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(row.indices, id: \.self) { index in
                        let key = row[index]
                        keyCell(
                            key: key,
                            stats: snapshot.keys[key],
                            mode: mode,
                            hasLeftNeighbor: index > row.startIndex,
                            hasRightNeighbor: index < row.index(before: row.endIndex)
                        )
                        if index < row.index(before: row.endIndex) {
                            gapCell(
                                decision: gapDecision(left: key, right: row[index + 1], snapshot: snapshot),
                                mode: mode
                            )
                        }
                    }
                }
            }
        }
    }

    private func keyCell(
        key: String,
        stats: KeyboardTouchLearningKeyStats?,
        mode: TouchLearningDisplayMode,
        hasLeftNeighbor: Bool,
        hasRightNeighbor: Bool
    ) -> some View {
        let confidence = min(1.0, (stats?.sampleCount ?? 0) / Self.fullConfidenceSamples)
        let dx = CGFloat((stats?.meanX ?? 0) * confidence) * Self.cellWidth
        let dy = CGFloat((stats?.meanY ?? 0) * confidence) * Self.cellHeight
        return ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor.opacity(0.08 + 0.30 * confidence))
            if mode == .bands {
                HStack(spacing: 0) {
                    if hasLeftNeighbor {
                        Rectangle()
                            .fill(Color.orange.opacity(0.28))
                            .frame(width: Self.edgeBandWidth)
                    }
                    Spacer(minLength: 0)
                    if hasRightNeighbor {
                        Rectangle()
                            .fill(Color.orange.opacity(0.28))
                            .frame(width: Self.edgeBandWidth)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            Text(key)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(stats == nil ? Color.secondary : Color.primary)
            if stats != nil, mode == .centers {
                Circle()
                    .fill(Color.red)
                    .frame(width: 5, height: 5)
                    .offset(x: dx, y: dy)
            }
        }
        .frame(width: Self.cellWidth, height: Self.cellHeight)
    }

    private func gapCell(decision: GapDecision, mode: TouchLearningDisplayMode) -> some View {
        let color: Color = {
            guard mode == .gaps else { return .clear }
            switch decision.winner {
            case .left:
                return .blue.opacity(0.55)
            case .right:
                return .green.opacity(0.55)
            case .fallback:
                return .gray.opacity(0.20)
            }
        }()
        return RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(color)
            .overlay {
                if mode == .gaps {
                    Text(decision.routedKey?.uppercased() ?? "-")
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)
                }
            }
            .frame(width: Self.cellGapWidth, height: Self.cellHeight)
            .accessibilityLabel(gapAccessibilityLabel(decision))
    }

    private func gapDecisionRow(_ decision: GapDecision) -> some View {
        HStack {
            Text("\(decision.leftKey.uppercased())/\(decision.rightKey.uppercased())")
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .frame(width: 44, alignment: .leading)
            Text(gapDecisionSummary(decision))
                .font(.subheadline)
            Spacer()
            Text(Self.percentLabel(decision.margin))
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private func statsRow(key: String, stats: KeyboardTouchLearningKeyStats) -> some View {
        HStack {
            Text(key.uppercased())
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .frame(width: 28, alignment: .leading)
            Text("\(Int(stats.sampleCount.rounded())) samples")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(Self.offsetLabel(stats))
                .font(.system(.subheadline, design: .monospaced))
        }
    }

    private func gapDecision(
        left: String,
        right: String,
        snapshot: KeyboardTouchLearningSnapshot
    ) -> GapDecision {
        let leftStats = snapshot.keys[left]
        let rightStats = snapshot.keys[right]
        let decision = KeyboardTouchGapPolicy.decide(
            left: Self.gapPolicyStats(leftStats),
            right: Self.gapPolicyStats(rightStats)
        )
        let leftBias = max(0, Self.effectiveMeanX(leftStats))
        let rightBias = max(0, -Self.effectiveMeanX(rightStats))
        let winner: GapWinner
        switch decision?.side {
        case .some(.left):
            winner = .left
        case .some(.right):
            winner = .right
        case .none:
            winner = .fallback
        }
        return GapDecision(
            leftKey: left,
            rightKey: right,
            winner: winner,
            leftSamples: leftStats?.sampleCount ?? 0,
            rightSamples: rightStats?.sampleCount ?? 0,
            leftBias: leftBias,
            rightBias: rightBias,
            margin: decision?.margin ?? abs(leftBias - rightBias)
        )
    }

    private func gapDecisionSummary(_ decision: GapDecision) -> String {
        if let routedKey = decision.routedKey {
            return "gap -> \(routedKey.uppercased())"
        }
        if max(decision.leftSamples, decision.rightSamples) < KeyboardTouchGapPolicy.minimumDecisionSamples {
            return "needs samples"
        }
        return "geometric"
    }

    private func gapAccessibilityLabel(_ decision: GapDecision) -> String {
        let summary = gapDecisionSummary(decision)
        return "\(decision.leftKey.uppercased()) \(decision.rightKey.uppercased()) gap, \(summary)"
    }

    private static func offsetLabel(_ stats: KeyboardTouchLearningKeyStats) -> String {
        String(
            format: "dx %+d%%  dy %+d%%",
            Int((stats.meanX * 100).rounded()),
            Int((stats.meanY * 100).rounded())
        )
    }

    private static func effectiveMeanX(_ stats: KeyboardTouchLearningKeyStats?) -> Double {
        KeyboardTouchGapPolicy.effectiveMeanX(gapPolicyStats(stats))
    }

    private static var fullConfidenceSamples: Double {
        KeyboardTouchGapPolicy.fullConfidenceSamples
    }

    private static func gapPolicyStats(_ stats: KeyboardTouchLearningKeyStats?) -> KeyboardTouchGapPolicy.KeyStats? {
        guard let stats else { return nil }
        return KeyboardTouchGapPolicy.KeyStats(sampleCount: stats.sampleCount, meanX: stats.meanX)
    }

    private static func percentLabel(_ value: Double) -> String {
        String(format: "%+d%%", Int((value * 100).rounded()))
    }

    private static func relativeDate(_ timestamp: TimeInterval) -> String {
        guard timestamp > 0 else { return "—" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: Date(timeIntervalSince1970: timestamp), relativeTo: Date())
    }
}

