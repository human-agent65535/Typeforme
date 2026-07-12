#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

/usr/bin/python3 - "$ROOT" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
views = root / "iOS/TypeformeIOS/Views"
content = (views / "ContentView.swift").read_text()
home = (views / "HostHomeView.swift").read_text()
recording = (views / "HostRecordingCard.swift").read_text()
results = (views / "HostResultViews.swift").read_text()
project = (root / "iOS/TypeformeIOS.xcodeproj/project.pbxproj").read_text()

if len(content.splitlines()) > 160:
    raise AssertionError("ContentView regained main-surface implementation details")

for required in ("HostHomeView(", "PiPSourceViewMount()", "HostSettingsView("):
    if required not in content:
        raise AssertionError(f"ContentView lost root lifecycle ownership: {required}")

for forbidden in ("struct HeroRecordCard", "struct ResultCard", "struct RouteStatusBar"):
    if forbidden in content:
        raise AssertionError(f"ContentView regained child view ownership: {forbidden}")

for required in (
    "HeroRecordCard(audio: state.audioCoordinator)",
    "ModeChipsRow()",
    "LanguagesRow()",
    "ResultCard()",
    "RawTranscriptCard(expanded: $rawTranscriptExpanded)",
):
    if required not in home:
        raise AssertionError(f"HostHomeView lost home composition: {required}")

for forbidden in (
    "beginHostHoldRecording",
    "endHostHoldRecording",
    "toggleHostTapRecording",
):
    if forbidden in home:
        raise AssertionError(f"HostHomeView took recording behavior ownership: {forbidden}")

for required in (
    "beginHostHoldRecording",
    "endHostHoldRecording",
    "toggleHostTapRecording",
    '.accessibilityLabel("Recording Control")',
    ".accessibilityValue(state.inputMode.title)",
):
    if required not in recording:
        raise AssertionError(f"HostRecordingCard lost recording contract: {required}")

for required in (
    '.accessibilityLabel("Dictation result")',
    '.accessibilityLabel("Dismiss error")',
    'Text("Dictation result appears here after you speak.")',
):
    if required not in results:
        raise AssertionError(f"Host result surfaces lost accessibility contract: {required}")

mode_chips = home.split("private struct ModeChipsRow", 1)[1].split(
    "private struct ModeChip", 1
)[0]
if ".padding(.horizontal, 16)" in mode_chips:
    raise AssertionError("Mode chips regained duplicate horizontal inset")
for required in ("HStack(spacing: 6)", ".padding(.horizontal, 12)"):
    if required not in home:
        raise AssertionError(f"Mode chips lost compact default layout: {required}")

for required in (
    "dynamicTypeSize.isAccessibilitySize",
    "VStack(alignment: .leading, spacing: 6)",
    ".lineLimit(2)",
):
    if required not in home:
        raise AssertionError(f"Languages lost accessibility-size layout: {required}")

for required in (
    "dynamicTypeSize.isAccessibilitySize ? 180 : 120",
    ".fixedSize(horizontal: false, vertical: true)",
):
    if required not in results:
        raise AssertionError(f"Result card lost accessibility-size layout: {required}")

for source in (
    "HostHomeView.swift",
    "HostRecordingCard.swift",
    "HostResultViews.swift",
):
    if project.count(f"{source} in Sources") != 2:
        raise AssertionError(f"iOS project does not compile host source exactly once: {source}")

print("OK: iOS host view ownership invariants passed.")
PY
