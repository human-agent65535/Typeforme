import ActivityKit
import SwiftUI
import WidgetKit

@main
struct TypeformeLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        TypeformeLiveActivityWidget()
    }
}

struct TypeformeLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TypeformeDictationActivityAttributes.self) { context in
            TypeformeLiveActivityLockScreenView(state: context.state)
                .activityBackgroundTint(Color(.secondarySystemBackground))
                .activitySystemActionForegroundColor(.blue)
                .widgetURL(URL(string: "typeforme://microphone?action=standby"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    TypeformeLiveActivityCompactView(state: context.state)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TypeformeLiveActivityStatusBadge(phase: context.state.phase)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } compactLeading: {
                Image(systemName: iconName(for: context.state.phase))
                    .foregroundStyle(phaseTint(for: context.state.phase))
            } compactTrailing: {
                TypeformeLiveActivityStatusBadge(phase: context.state.phase, isCompact: true)
            } minimal: {
                Image(systemName: iconName(for: context.state.phase))
                    .foregroundStyle(phaseTint(for: context.state.phase))
            }
            .widgetURL(URL(string: "typeforme://microphone?action=standby"))
        }
    }
}

private struct TypeformeLiveActivityLockScreenView: View {
    let state: TypeformeDictationActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName(for: state.phase))
                .font(.title2.weight(.semibold))
                .foregroundStyle(phaseTint(for: state.phase))
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text("Typeforme")
                    .font(.headline)
                Text(title(for: state.phase))
                    .font(.subheadline.weight(.semibold))
                Text(state.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)
            TypeformeLiveActivityStatusBadge(phase: state.phase)
        }
        .padding(.vertical, 4)
    }
}

private struct TypeformeLiveActivityCompactView: View {
    let state: TypeformeDictationActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName(for: state.phase))
                .foregroundStyle(phaseTint(for: state.phase))
            Text(title(for: state.phase))
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
    }
}

private struct TypeformeLiveActivityStatusBadge: View {
    let phase: TypeformeDictationActivityPhase
    var isCompact = false

    var body: some View {
        Text(shortTitle(for: phase))
            .font(isCompact ? .caption2.weight(.bold) : .subheadline.weight(.semibold))
            .foregroundStyle(phaseTint(for: phase))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(width: isCompact ? 36 : 48, alignment: .trailing)
    }
}

private func title(for phase: TypeformeDictationActivityPhase) -> LocalizedStringKey {
    switch phase {
    case .ready: return "Ready"
    case .recording: return "Recording"
    case .transcribing: return "Transcribing"
    case .refining: return "Refining"
    case .result: return "Result Ready"
    case .issue: return "Needs Attention"
    }
}

private func shortTitle(for phase: TypeformeDictationActivityPhase) -> LocalizedStringKey {
    switch phase {
    case .ready: return "Ready"
    case .recording: return "Rec"
    case .transcribing: return "ASR"
    case .refining: return "Fix"
    case .result: return "Done"
    case .issue: return "Issue"
    }
}

private func iconName(for phase: TypeformeDictationActivityPhase) -> String {
    switch phase {
    case .ready: return "mic.circle"
    case .recording: return "waveform.circle.fill"
    case .transcribing: return "arrow.up.circle.fill"
    case .refining: return "wand.and.sparkles"
    case .result: return "checkmark.circle.fill"
    case .issue: return "exclamationmark.circle.fill"
    }
}

private func phaseTint(for phase: TypeformeDictationActivityPhase) -> Color {
    switch phase {
    case .ready: return .green
    case .recording: return .red
    case .transcribing: return .blue
    case .refining: return .purple
    case .result: return .green
    case .issue: return .orange
    }
}
