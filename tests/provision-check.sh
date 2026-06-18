#!/usr/bin/env bash
# =============================================================================
# tests/provision-check.sh — Idempotenz-Prüfung für Anvil
#
# Führt bootstrap.sh apply zweimal aus und prüft, dass der zweite Lauf
# keine Änderungen mehr vornimmt (changed=0, failed=0).
#
# Voraussetzung:
#   - config/anvil.conf ist eingerichtet
#   - group_vars/all/vault.yml ist vorhanden und entschlüsselbar
#   - Wird als root ausgeführt (sudo)
#
# Exit-Codes:
#   0 = PASS (Idempotenz bestätigt)
#   1 = FAIL (es gab changed!=0 oder failed!=0)
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

# --- Repo-Wurzel ermitteln ---------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
readonly SCRIPT_DIR

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_root

# --- Konfiguration prüfen ----------------------------------------------------
[[ -f "$SCRIPT_DIR/config/anvil.conf" ]] || die "config/anvil.conf fehlt.
  → cp config/anvil.conf.example config/anvil.conf und ADMIN_USER + Pubkeys setzen."

[[ -f "$SCRIPT_DIR/group_vars/all/vault.yml" ]] || die "group_vars/all/vault.yml fehlt.
  → cp group_vars/all/vault.example.yml group_vars/all/vault.yml und ansible-vault encrypt ausführen."

section "Idempotenz-Check: Lauf A (Konvergenz)"
log "Erster Apply-Lauf — stellt den Soll-Zustand her."
if ! "$SCRIPT_DIR/bootstrap.sh" apply; then
  die "Lauf A (Konvergenz) fehlgeschlagen — Provisionierung nicht idempotent prüfbar."
fi
ok "Lauf A abgeschlossen."

section "Idempotenz-Check: Lauf B (zweiter Apply)"
log "Zweiter Apply-Lauf — erwartet: changed=0, failed=0."

# Zweiten Lauf ausführen und Output parsen (sowohl stdout als auch stderr erfassen).
# Wir fangen den Exit-Code separat, damit wir den Output auswerten können.
output="$("$SCRIPT_DIR/bootstrap.sh" apply 2>&1)" && rc=$? || rc=$?

# PLAY-RECAP-Statistikzeile direkt finden (Format:
#   localhost : ok=.. changed=.. unreachable=.. failed=.. ...).
# Robuster als das "PLAY RECAP ****"-Header zu matchen.
recap_line="$(printf '%s\n' "$output" | grep -E 'ok=[0-9]+.*changed=[0-9]+' | tail -n1 || true)"
changed="$(echo "$recap_line" | grep -oP 'changed=\K[0-9]+' || echo "?")"
failed="$(echo "$recap_line" | grep -oP 'failed=\K[0-9]+' || echo "?")"
unreachable="$(echo "$recap_line" | grep -oP 'unreachable=\K[0-9]+' || echo "0")"

log "PLAY RECAP: $recap_line"
log "changed=$changed, failed=$failed, unreachable=$unreachable"

if [[ "$changed" == "?" || "$failed" == "?" ]]; then
  warn "Konnte PLAY RECAP nicht parsen — zeige vollständige Ausgabe:"
  echo "$output" >&2
  die "Idempotenz-Check: PARSE-FEHLER"
fi

if [[ "$rc" -ne 0 ]]; then
  die "Idempotenz-Check: FEHLGESCHLAGEN — Lauf B exit-code $rc (siehe oben)."
fi

if [[ "$changed" -ne 0 ]]; then
  warn "Idempotenz verletzt: $changed Task(s) meldeten 'changed' im zweiten Lauf."
  warn "Wiederhole mit 'bootstrap.sh apply' einzeln oder mit -v (verbose),"
  warn "um die nicht-idempotenten Tasks zu identifizieren."
  die "Idempotenz-Check: FAIL — changed=$changed (erwartet: 0)"
fi

if [[ "$failed" -ne 0 ]]; then
  die "Idempotenz-Check: FAIL — failed=$failed (erwartet: 0)"
fi

section "Ergebnis"
ok "Idempotenz bestätigt: changed=0, failed=0, unreachable=$unreachable."
ok "PASS — Der zweite Apply-Lauf hat nichts verändert."
exit 0
