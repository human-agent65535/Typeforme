#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

/usr/bin/python3 - "$ROOT" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
content = (root / "iOS/TypeformeIOS/Views/ContentView.swift").read_text()
host = (root / "iOS/TypeformeIOS/Views/HostSettingsView.swift").read_text()
setup = (root / "iOS/TypeformeIOS/Views/SetupAccessView.swift").read_text()
keyboard = (root / "iOS/TypeformeIOS/Views/KeyboardSettingsView.swift").read_text()
mac = (root / "iOS/TypeformeIOS/Views/MacProcessingSettingsView.swift").read_text()
pairing = (root / "iOS/TypeformeIOS/Views/PairingView.swift").read_text()
project = (root / "iOS/TypeformeIOS.xcodeproj/project.pbxproj").read_text()

content_view = content.split("struct ContentView: View", 1)[1]
if content_view.count(".sheet(isPresented:") != 1:
    raise AssertionError("ContentView must present one unified settings sheet")

for legacy_state in (
    "showingPairing",
    "showingDictationSettings",
    "showingKeyboardSettings",
    "showingSetupReadiness",
    "showingKeyboardGuide",
):
    if legacy_state in content_view:
        raise AssertionError(f"legacy settings presentation state returned: {legacy_state}")

voice = host.split("private struct VoiceDictationSettingsView", 1)[1].split(
    "private struct ConnectedMacSettingsView", 1
)[0]
for required in ('Picker("Default Mode"', "LivePreviewSettingsSection()"):
    if required not in voice:
        raise AssertionError(f"Voice Dictation lost iPhone-owned setting: {required}")

mac_settings = mac.split("struct MacSettingsView", 1)[1].split(
    "private struct ModelStatusRow", 1
)[0]
for forbidden in ('Picker("Default Mode"', "LivePreviewSettingsSection()"):
    if forbidden in mac_settings:
        raise AssertionError(f"Mac Processing regained an iPhone-owned setting: {forbidden}")

if 'Toggle("AI Writing", isOn: aiWritingEnabledBinding)' not in keyboard:
    raise AssertionError("AI Writing belongs in the iPhone keyboard settings")
if 'Toggle("AI Writing"' in mac_settings:
    raise AssertionError("Mac Processing must not own the keyboard AI Writing switch")
app = (root / "iOS/TypeformeIOS/AppState.swift").read_text()
for required in (
    'private static let keyboardAIWritingEnabledKey = "keyboard.aiWritingEnabled"',
    "self.keyboardAIWritingEnabled = UserDefaults.standard.bool(forKey: Self.keyboardAIWritingEnabledKey)",
    "aiWritingEnabled: keyboardAIWritingEnabled",
):
    if required not in app:
        raise AssertionError(f"AI Writing lost its iPhone-owned preference: {required}")
setter = app.split("func setKeyboardAIWritingEnabled", 1)[1].split("func setKeyboardChinesePunctuationStyle", 1)[0]
if "updateStoredBoolPreference(" not in setter or "publishKeyboardDefaults()" not in setter:
    raise AssertionError("AI Writing changes must persist and publish to the keyboard immediately")
mac_app = (root / "Sources/Typeforme/UI/SettingsTabs.swift").read_text()
if 'Toggle("AI Writing"' in mac_app:
    raise AssertionError("The Mac app must expose the conversion prompt, not the keyboard switch")

for required in (
    ".navigationBarBackButtonHidden(hasUnsavedChanges)",
    ".interactiveDismissDisabled(hasUnsavedChanges)",
    '"Discard Mac settings changes?"',
    ".disabled(isSaving || !hasUnsavedChanges)",
):
    if required not in mac_settings:
        raise AssertionError(f"Mac Processing lost save/discard protection: {required}")

for required in (
    "private struct KeyboardLearningSettingsView",
    "private struct ChineseLearningStatsView",
    "private struct TouchLearningStatsView",
):
    if required not in keyboard:
        raise AssertionError(f"Learning feature left its keyboard ownership boundary: {required}")

for required in (
    '.accessibilityLabel("Capture Mode")',
    ".accessibilityValue(state.keyboardDictationCaptureMode.title)",
):
    if required not in setup:
        raise AssertionError(f"Setup capture picker lost VoiceOver context: {required}")

if "NavigationStack" in pairing:
    raise AssertionError("PairingView must use the unified settings navigation stack")

for required in (
    ".navigationBarBackButtonHidden(true)",
    'Button("Cancel")',
    'Button("Save")',
):
    if required not in pairing:
        raise AssertionError(f"Pairing lost explicit commit semantics: {required}")

for source in (
    "HostSettingsView.swift",
    "SetupAccessView.swift",
    "KeyboardSettingsView.swift",
    "MacProcessingSettingsView.swift",
):
    if project.count(f"{source} in Sources") != 2:
        raise AssertionError(f"iOS project does not compile settings source exactly once: {source}")

print("OK: iOS settings ownership invariants passed.")
PY
