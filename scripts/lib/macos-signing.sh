#!/usr/bin/env bash

typeforme_find_codesign_identity() {
    local prefix="$1"
    local identities preferred
    identities="$(security find-identity -p codesigning -v 2>/dev/null \
        | sed -n "s/.*\"\(${prefix}[^\"]*\)\".*/\1/p" \
        || true)"
    if [ "$prefix" = "Apple Development:" ]; then
        # Prefer modern person-name development certificates over older
        # email-labelled ones. The latter can linger in the keychain after
        # revocation and still pass `security find-identity`, then helpers get
        # killed at runtime by Gatekeeper.
        preferred="$(printf '%s\n' "$identities" | grep -v '@' | head -n 1 || true)"
        if [ -n "$preferred" ]; then
            printf '%s\n' "$preferred"
            return
        fi
    fi
    printf '%s\n' "$identities" | head -n 1
}
