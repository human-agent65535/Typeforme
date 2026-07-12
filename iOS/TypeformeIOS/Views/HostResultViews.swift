import SwiftUI

struct ResultCard: View {
    @Environment(AppState.self) private var state
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        @Bindable var state = state
        let previewText = livePreviewText
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(showsLivePreview ? "Preview" : "Result", systemImage: showsLivePreview ? "waveform" : "text.alignleft")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if state.phase == .refining {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }
            if showsLivePreview {
                ScrollView {
                    Text(previewText)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(14)
                }
                .frame(minHeight: resultMinimumHeight, alignment: .topLeading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(.systemBackground))
                )
            } else {
                TextEditor(text: $state.resultText)
                    .frame(minHeight: resultMinimumHeight)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(.systemBackground))
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Dictation result")
                    .overlay(alignment: .topLeading) {
                        if !hasResult {
                            Text("Dictation result appears here after you speak.")
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 14)
                                .padding(.top, 16)
                                .allowsHitTesting(false)
                        }
                    }
            }
            HStack(spacing: 10) {
                Button {
                    state.copyResult()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(!hasResult)

                Button(role: .destructive) {
                    state.clearResult()
                } label: {
                    Label("Clear", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(!hasResult && state.rawTranscript.isEmpty)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private var hasResult: Bool {
        !state.resultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var resultMinimumHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 180 : 120
    }

    private var livePreviewText: String {
        state.livePartialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var showsLivePreview: Bool {
        guard !livePreviewText.isEmpty else { return false }
        switch state.phase {
        case .recording, .sending, .refining:
            return true
        default:
            return false
        }
    }
}

// MARK: - Raw transcript card

struct RawTranscriptCard: View {
    @Environment(AppState.self) private var state
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack {
                    Label("Raw transcript", systemImage: "waveform")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Hide raw transcript" : "Show raw transcript")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")

            if expanded {
                Group {
                    if state.rawTranscript.isEmpty {
                        Text("No raw transcript yet — start dictation to see the unedited recognition output here.")
                    } else {
                        Text(state.rawTranscript)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(.systemBackground))
                )
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }
}

// MARK: - Error banner

struct ErrorBanner: View {
    let message: String
    var canRepair = false
    var onRepair: () -> Void = {}
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            if canRepair {
                Button {
                    onRepair()
                } label: {
                    Label("Repair", systemImage: "wrench.and.screwdriver")
                        .labelStyle(.iconOnly)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Repair pairing")
            }
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss error")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.orange.opacity(0.32), lineWidth: 0.5)
        )
    }
}

// MARK: - Toast

struct ToastView: View {
    let message: String?

    var body: some View {
        if let message {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(message)
                    .font(.footnote.weight(.semibold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color(.separator), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.12), radius: 6, x: 0, y: 3)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
