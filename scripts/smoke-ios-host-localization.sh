#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EN="$ROOT/iOS/TypeformeIOS/en.lproj/Localizable.strings"
ZH="$ROOT/iOS/TypeformeIOS/zh-Hans.lproj/Localizable.strings"

plutil -lint "$EN" "$ZH" >/dev/null

/usr/bin/python3 - "$ROOT" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
en_path = root / "iOS/TypeformeIOS/en.lproj/Localizable.strings"
zh_path = root / "iOS/TypeformeIOS/zh-Hans.lproj/Localizable.strings"
settings = (root / "iOS/TypeformeIOS/Views/HostSettingsView.swift").read_text()
home = (root / "iOS/TypeformeIOS/Views/HostHomeView.swift").read_text()
recording = (root / "iOS/TypeformeIOS/Views/HostRecordingCard.swift").read_text()
setup = (root / "iOS/TypeformeIOS/Views/SetupAccessView.swift").read_text()
bridge_models = (root / "iOS/TypeformeIOS/Bridge/BridgeModels.swift").read_text()

entry_pattern = re.compile(r'^"([^"]+)"\s*=\s*"([^"]*)";', re.MULTILINE)

def load(path):
    entries = {}
    for key, value in entry_pattern.findall(path.read_text()):
        entries.setdefault(key, []).append(value)
    return entries

en = load(en_path)
zh = load(zh_path)

required = (
    "Settings",
    "Voice Dictation",
    "Text Keyboard",
    "Connected Mac",
    "Capture Mode & Permissions",
    "Capture mode and permissions",
    "Capture Mode",
    "Mac Processing",
    "Connected via Local",
    "Connected via Cloud",
    "Local route",
    "Cloud route",
    "Offline route",
    "Bridge route: %@",
    "Recording Control",
    "Dictation result",
    "Dictation result appears here after you speak.",
    "Dismiss error",
    "Pair the Mac Bridge first.",
    "Tap again when you're done.",
    "Keep holding while you speak.",
    "Result copied to the clipboard.",
    "Result inserted.",
    "Recording is local. Bridge will be resolved when you send.",
)
for key in required:
    for locale, entries in (("en", en), ("zh-Hans", zh)):
        values = entries.get(key, [])
        if len(values) != 1 or not values[0]:
            raise AssertionError(
                f"host localization must exist exactly once in {locale}: {key}"
            )

for required_source in (
    "private var primaryStatusTitle: LocalizedStringKey",
    "private var primaryStatusDetail: LocalizedStringKey",
    "let title: LocalizedStringKey",
    "let detail: LocalizedStringKey",
    "private var connectedMacDetail: LocalizedStringKey",
):
    if required_source not in settings:
        raise AssertionError(f"host setting summary bypasses localization: {required_source}")

for required_source in (
    'NSLocalizedString("Bridge route: %@"',
    'NSLocalizedString("Checking"',
    'NSLocalizedString("Offline"',
):
    if required_source not in home:
        raise AssertionError(f"host route summary bypasses localization: {required_source}")

for key in (
    "Pair the Mac Bridge first.",
    "Tap again when you're done.",
    "Keep holding while you speak.",
    "Result copied to the clipboard.",
    "Result inserted.",
    "Recording is local. Bridge will be resolved when you send.",
):
    if f'NSLocalizedString("{key}"' not in recording:
        raise AssertionError(f"host recording copy bypasses localization: {key}")

if 'NSLocalizedString(displayName, comment: "Correction mode title")' not in bridge_models:
    raise AssertionError("iOS correction mode titles bypass localization")
if 'navigationTitle("Capture Mode & Permissions")' not in setup:
    raise AssertionError("capture mode and permission title is inconsistent")
if "Setup & Access" in settings or "Setup & Access" in setup:
    raise AssertionError("retired setup title remains in host settings")

print("OK: iOS host localization coverage passed.")
PY
