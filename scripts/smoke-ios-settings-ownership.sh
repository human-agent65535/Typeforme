#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

/usr/bin/python3 - "$ROOT" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
content = (root / "iOS/TypeformeIOS/Views/ContentView.swift").read_text()
pairing = (root / "iOS/TypeformeIOS/Views/PairingView.swift").read_text()

content_view = content.split("struct ContentView: View", 1)[1].split(
    "private struct HostSettingsView", 1
)[0]
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

voice = content.split("private struct VoiceDictationSettingsView", 1)[1].split(
    "private struct ConnectedMacSettingsView", 1
)[0]
for required in ('Picker("Default Mode"', "LivePreviewSettingsSection()"):
    if required not in voice:
        raise AssertionError(f"Voice Dictation lost iPhone-owned setting: {required}")

mac = content.split("private struct MacSettingsView", 1)[1].split(
    "private struct ModelStatusRow", 1
)[0]
for forbidden in ('Picker("Default Mode"', "LivePreviewSettingsSection()"):
    if forbidden in mac:
        raise AssertionError(f"Mac Processing regained an iPhone-owned setting: {forbidden}")

if "NavigationStack" in pairing:
    raise AssertionError("PairingView must use the unified settings navigation stack")

print("OK: iOS settings ownership invariants passed.")
PY
