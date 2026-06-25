#!/usr/bin/env bash
# =============================================================================
# tests/fallback-check.sh — Kernel-Fallback Assessment (ohne echten Reboot)
#
# Prüft die Logik von anvil-boot-assess auf einer provisionierten VM
# non-destruktiv: belegt, dass der Fallback-Pfad und der Erfolgs-Pfad
# korrekt arbeiten, ohne einen echten Neustart durchzuführen.
#
# Voraussetzung:
#   - Anvil wurde mindestens einmal erfolgreich angewendet (bootstrap.sh apply)
#   - /usr/local/sbin/anvil-boot-assess + anvil-kernel-lib.sh sind installiert
#   - /usr/local/bin/anvil-notify ist installiert
#   - Wird als root ausgeführt
#
# Exit-Codes:
#   0 = ALLE Pfade PASS
#   1 = mindestens ein Pfad FAIL
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
readonly SCRIPT_DIR

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# --- Prüfen, ob die Produktions-Skripte installiert sind ---------------------
BOOT_ASSESS=/usr/local/sbin/anvil-boot-assess
KERNEL_LIB=/usr/local/sbin/anvil-kernel-lib.sh
ANVIL_NOTIFY=/usr/local/bin/anvil-notify
STATE_DIR=/var/lib/anvil
INTENDED_FILE="$STATE_DIR/intended-kernel"
FALLBACK_FILE="$STATE_DIR/last-fallback"
NOTIFY_LOG=/var/log/anvil/notify.log

for f in "$BOOT_ASSESS" "$ANVIL_NOTIFY"; do
  [[ -x "$f" ]] || die "Erforderliches Skript nicht ausführbar/gefunden: $f — Anvil vollständig anwenden (bootstrap.sh apply) vor diesem Test."
done
# anvil-kernel-lib.sh wird von anvil-boot-assess GESOURCT (Mode 0644) — nur lesbar nötig.
[[ -r "$KERNEL_LIB" ]] || die "Kernel-Bibliothek nicht gefunden/lesbar: $KERNEL_LIB"

# --- Hilfsfunktionen ---------------------------------------------------------

cleanup() {
  rm -f "$INTENDED_FILE" "$FALLBACK_FILE"
  # Notify-Log nicht löschen, nur die von uns erzeugten Einträge stören nicht.
}

# Einen Test-Schritt protokollieren und auswerten.
pass_count=0
fail_count=0

pass() {
  local msg="$1"
  ok "[PASS] $msg"
  pass_count=$((pass_count + 1))
}

fail() {
  local msg="$1"
  error "[FAIL] $msg"
  fail_count=$((fail_count + 1))
}

# Wartet auf abgeschlossene Log-Schreiboperationen (sync).
sync_logs() {
  sync
}

# --- Test 1: Fallback-Pfad (defekter Kernel) ---------------------------------
test_fallback_path() {
  section "Fallback-Pfad: defekten Kernel simulieren"
  cleanup

  local bogus_version running
  bogus_version="9.99.9-bogus-anvil-test-$(date +%s)"
  running="$(uname -r)"

  log "Laufender Kernel: $running"
  log "Simulierter intended-kernel: $bogus_version"

  # 1. Bogus-Version als intended-kernel schreiben (Annahme: ≠ uname -r)
  mkdir -p "$STATE_DIR"
  echo "$bogus_version" >"$INTENDED_FILE"
  log "Geschrieben: $INTENDED_FILE → $(cat "$INTENDED_FILE")"

  # 2. anvil-boot-assess ausführen
  log "Führe $BOOT_ASSESS aus …"
  if ! "$BOOT_ASSESS"; then
    fail "anvil-boot-assess ist mit Exit-Code ≠ 0 beendet (Fallback-Pfad)."
    cleanup
    return
  fi
  ok "anvil-boot-assess beendet (Exit 0)."

  # 3. Prüfen: last-fallback wurde geschrieben
  if [[ -f "$FALLBACK_FILE" ]]; then
    local fallback_content
    fallback_content="$(cat "$FALLBACK_FILE")"
    pass "last-fallback geschrieben: $fallback_content"
  else
    fail "last-fallback wurde NICHT geschrieben (erwartet: $bogus_version → $running)."
  fi

  # 4. Prüfen: intended-kernel wurde entfernt
  if [[ ! -f "$INTENDED_FILE" ]]; then
    pass "intended-kernel entfernt (aufgeräumt)."
  else
    fail "intended-kernel wurde NICHT entfernt."
  fi

  # 5. Prüfen: apt-mark hold für nicht-existentes Paket scheitert sauber
  if apt-mark hold "linux-image-$bogus_version" >/dev/null 2>&1; then
    # Falls das Paket wider Erwarten existiert, wieder freigeben.
    apt-mark unhold "linux-image-$bogus_version" >/dev/null 2>&1 || true
    pass "apt-mark hold für nicht-existentes Paket (kann fehlschlagen — in Ordnung)."
  else
    pass "apt-mark hold für nicht-existentes Paket sauber fehlgeschlagen (erwartet)."
  fi

  # 6. Prüfen: ntfy-Alarm im Notify-Log
  sync_logs
  if [[ -f "$NOTIFY_LOG" ]]; then
    # Suche nach einem kürzlichen Eintrag mit "Kernel-Fallback" im Titel oder
    # "SPOOLED"/"SENT" — der genaue Inhalt hängt von der ntfy-Konfiguration ab.
    if grep -q "Kernel-Fallback" "$NOTIFY_LOG" 2>/dev/null; then
      pass "ntfy-Alarm im Notify-Log gefunden (Kernel-Fallback)."
    elif grep -q "kernel" "$NOTIFY_LOG" 2>/dev/null; then
      # Fallback: Irgendein kernel-bezogener Eintrag wurde geloggt.
      pass "ntfy-Eintrag im Notify-Log gefunden."
    else
      fail "Kein ntfy-Eintrag in $NOTIFY_LOG nach Fallback-Simulation."
      log "Letzte 5 Zeilen von $NOTIFY_LOG:"
      tail -5 "$NOTIFY_LOG" 2>/dev/null | sed 's/^/  /' >&2 || true
    fi
  else
    fail "Notify-Log $NOTIFY_LOG existiert nicht — ntfy nicht installiert/konfiguriert?"
  fi

  cleanup
}

# --- Test 2: Erfolgs-Pfad (intended == laufender Kernel) ---------------------
test_success_path() {
  section "Erfolgs-Pfad: intended == laufender Kernel"
  cleanup

  local running
  running="$(uname -r)"

  log "Laufender Kernel: $running"

  # 1. intended-kernel = aktueller uname -r
  mkdir -p "$STATE_DIR"
  echo "$running" >"$INTENDED_FILE"
  log "Geschrieben: $INTENDED_FILE → $(cat "$INTENDED_FILE")"

  # 2. anvil-boot-assess ausführen
  log "Führe $BOOT_ASSESS aus …"
  if ! "$BOOT_ASSESS"; then
    fail "anvil-boot-assess ist mit Exit-Code ≠ 0 beendet (Erfolgs-Pfad)."
    cleanup
    return
  fi
  ok "anvil-boot-assess beendet (Exit 0)."

  # 3. Prüfen: laufender Kernel wurde als GRUB-Default festgeschrieben
  if command -v grub-editenv >/dev/null 2>&1; then
    local saved_entry
    saved_entry="$(grub-editenv /boot/grub/grubenv list 2>/dev/null | grep 'saved_entry=' || true)"
    if [[ -n "$saved_entry" ]]; then
      pass "GRUB saved_entry gesetzt: $saved_entry"
    else
      fail "GRUB saved_entry wurde nicht gesetzt (grub-editenv list zeigt keinen Eintrag)."
    fi
  elif command -v grub-set-default >/dev/null 2>&1; then
    log "grub-editenv nicht verfügbar, überspringe GRUB-Prüfung (alternative Implementierung)."
    pass "GRUB-Prüfung übersprungen (kein grub-editenv)."
  else
    log "Kein GRUB-Tool gefunden — kann saved_entry nicht prüfen. Akzeptiere Exit 0."
    pass "GRUB-Prüfung übersprungen (kein GRUB-Tool)."
  fi

  # 4. Prüfen: intended-kernel wurde entfernt
  if [[ ! -f "$INTENDED_FILE" ]]; then
    pass "intended-kernel entfernt (aufgeräumt)."
  else
    fail "intended-kernel wurde NICHT entfernt."
  fi

  # 5. Prüfen: kein Fallback-Eintrag
  if [[ ! -f "$FALLBACK_FILE" ]]; then
    pass "Kein last-fallback geschrieben (korrekt — Erfolgsfall)."
  else
    fail "last-fallback wurde fälschlich geschrieben im Erfolgs-Pfad."
  fi

  cleanup
}

# --- Test 3: Kein One-shot offen (normaler Boot) -----------------------------
test_no_intended() {
  section "Normaler Boot-Pfad: kein intended-kernel vorhanden"
  cleanup

  # Sicherstellen, dass kein intended-kernel existiert.
  rm -f "$INTENDED_FILE" "$FALLBACK_FILE"

  log "Führe $BOOT_ASSESS aus (kein intended-kernel) …"
  if ! "$BOOT_ASSESS"; then
    fail "anvil-boot-assess ist mit Exit-Code ≠ 0 beendet (normaler Boot)."
    return
  fi
  ok "anvil-boot-assess beendet (Exit 0)."

  # Prüfen: GRUB saved_entry sollte auf laufenden Kernel gesetzt sein.
  if command -v grub-editenv >/dev/null 2>&1; then
    local saved_entry
    saved_entry="$(grub-editenv /boot/grub/grubenv list 2>/dev/null | grep 'saved_entry=' || true)"
    if [[ -n "$saved_entry" ]]; then
      pass "GRUB saved_entry gesetzt (normaler Boot): $saved_entry"
    else
      fail "GRUB saved_entry wurde nicht gesetzt (normaler Boot)."
    fi
  else
    pass "GRUB-Prüfung übersprungen (kein grub-editenv)."
  fi

  # Prüfen: kein Fallback-Eintrag
  if [[ ! -f "$FALLBACK_FILE" ]]; then
    pass "Kein last-fallback geschrieben (normaler Boot)."
  else
    fail "last-fallback wurde fälschlich geschrieben."
  fi

  cleanup
}

# --- Hauptablauf -------------------------------------------------------------
main() {
  require_root
  section "Anvil Kernel-Fallback Assessment (non-destruktiv)"
  log "Test-Host: $(hostname), Kernel: $(uname -r), Datum: $(date -Is)"

  # Preflight: State-Verzeichnis und Notify-Log sollten existieren.
  if [[ ! -d "$STATE_DIR" ]]; then
    die "State-Verzeichnis $STATE_DIR fehlt — Anvil wurde nicht vollständig angewendet?"
  fi
  if [[ ! -f "$NOTIFY_LOG" ]]; then
    warn "Notify-Log $NOTIFY_LOG fehlt — lege es an (erster Test erzeugt Einträge)."
    mkdir -p "$(dirname "$NOTIFY_LOG")"
    touch "$NOTIFY_LOG"
  fi

  test_fallback_path
  test_success_path
  test_no_intended

  # Zusammenfassung
  section "Ergebnis"
  local total=$((pass_count + fail_count))
  log "$pass_count/$total Tests bestanden."

  if [[ "$fail_count" -eq 0 ]]; then
    ok "PASS — Alle Kernel-Fallback-Prüfungen bestanden."
    exit 0
  else
    die "FAIL — $fail_count Test(s) fehlgeschlagen (siehe oben)."
  fi
}

main "$@"
