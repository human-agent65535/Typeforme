#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

/usr/bin/python3 - "$ROOT" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
view = (root / "iOS/TypeformeIOS/Views/PairingView.swift").read_text()
service = (root / "iOS/TypeformeIOS/Bridge/BridgeService.swift").read_text()
app = (root / "iOS/TypeformeIOS/AppState.swift").read_text()

for forbidden in ("BridgeRouteResolver(", "BridgeClient("):
    if forbidden in view:
        raise AssertionError(f"PairingView regained network ownership: {forbidden}")

for required in (
    "appState.checkPairingRoutes(snapshot)",
    "appState.refreshPairingSettings(snapshot)",
    "LatestDraftOperationState<PairingConfig>",
    "pairingOperationCanApply(token, snapshot: snapshot)",
):
    if required not in view:
        raise AssertionError(f"PairingView no longer delegates through AppState: {required}")

for required in (
    "func checkPairingRoutes(_ config: PairingConfig)",
    "func refreshPairingSettings(_ config: PairingConfig)",
):
    if required not in service:
        raise AssertionError(f"BridgeService lost pairing operation ownership: {required}")

if "saveBridgeEndpoints" in view or "saveBridgeEndpoints" in app:
    raise AssertionError("route inspection must not persist an unsaved pairing draft")

print("OK: iOS pairing ownership invariants passed.")
PY
