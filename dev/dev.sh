#!/usr/bin/env bash
# =============================================================================
# dev/dev.sh — TEMPORÄRES Entwickler-Werkzeug für Anvil.
#
#   ⚠️  NICHT in den prod-Branch übernehmen! Der gesamte dev/-Ordner wird vor
#       der Veröffentlichung entfernt (siehe dev/README.md).
#
# Testet verschiedene Settings-Presets (dev/presets/*.yml) schnell durch, ohne
# config/anvil.conf zu editieren. Gedacht für die Ausführung DIREKT IN EINER
# WEGWERF-VM: apply/vm-matrix/totp-test härten den LOKALEN Host.
#
#   ⚠️  Niemals auf dem Arbeitsrechner ausführen — eine Sicherheitsabfrage
#       schützt davor (Bestätigung per Hostname; ANVIL_DEV_FORCE=1 überspringt).
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
readonly REPO_ROOT
DEV_DIR="$REPO_ROOT/dev"
PRESET_DIR="$DEV_DIR/presets"
LINT_VENV="$DEV_DIR/.venv"
DEV_ADMIN="devadmin"        # Admin-User aller dev-Presets

# shellcheck source=/dev/null
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/common.sh"

export ANSIBLE_CONFIG="$REPO_ROOT/ansible.cfg"
[[ -d "$REPO_ROOT/collections/ansible_collections" ]] && \
  export ANSIBLE_COLLECTIONS_PATH="$REPO_ROOT/collections"

usage() {
  cat <<'EOF'
dev/dev.sh — Anvil Entwickler-Harness (temporär, NICHT für prod)

  dev/dev.sh <befehl> [argument]      (apply/vm-matrix/totp-test: IN DER VM ausführen!)

SICHERE BEFEHLE (verändern nichts):
  list                  Presets auflisten
  vars <preset>         Aufgelöste Posture-/Toggle-Variablen anzeigen
  lint                  shellcheck + yamllint + ansible-lint + --syntax-check
  matrix                lint + 'vars' für ALLE Presets
  check <preset>        Dry-Run (--check --diff) lokal (sudo nötig, KEINE Änderungen)

VERÄNDERN DIESEN HOST (nur in einer Wegwerf-VM!):
  apply <preset>        Preset auf DIESEM Host anwenden (+ Idempotenz-Check)
  vm-matrix             ALLE (unkritischen) Presets nacheinander anwenden
  totp-test             End-to-End-TOTP-Test (pam_oath) via pamtester

  -h | --help           Diese Hilfe

Sicherheit: apply/vm-matrix/totp-test fragen vor Änderungen nach dem Hostnamen.
Nicht-interaktiv erzwingen:  ANVIL_DEV_FORCE=1 dev/dev.sh apply <preset>
EOF
}

# --- Hilfsfunktionen ----------------------------------------------------------
list_presets() {
  find "$PRESET_DIR" -maxdepth 1 -name '*.yml' -printf '%f\n' 2>/dev/null \
    | sed 's/\.yml$//' | sort
}

preset_file() {
  local p="${1:-}"
  [[ -n "$p" ]] || die "Kein Preset angegeben. Verfügbar: $(list_presets | tr '\n' ' ')"
  local f="$PRESET_DIR/$p.yml"
  [[ -f "$f" ]] || die "Preset '$p' nicht gefunden. Verfügbar: $(list_presets | tr '\n' ' ')"
  printf '%s' "$f"
}

ensure_lint_venv() {
  if [[ ! -x "$LINT_VENV/bin/ansible-lint" ]]; then
    section "Lint-venv einrichten (einmalig)"
    require_cmd python3 || die "python3 nicht gefunden."
    # python3-venv (ensurepip) bei Bedarf automatisch nachinstallieren.
    if ! python3 -c 'import ensurepip' >/dev/null 2>&1; then
      log "python3-venv fehlt — installiere automatisch via apt …"
      sudo DEBIAN_FRONTEND=noninteractive apt-get update -q
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y python3-venv python3-pip
    fi
    run python3 -m venv "$LINT_VENV"
    run "$LINT_VENV/bin/pip" install --quiet --upgrade pip
    run "$LINT_VENV/bin/pip" install --quiet yamllint ansible-lint shellcheck-py
  fi
  if [[ ! -d "$REPO_ROOT/collections/ansible_collections" ]]; then
    log "Installiere Collections nach ./collections (für ansible-lint) …"
    "$LINT_VENV/bin/ansible-galaxy" collection install -r "$REPO_ROOT/requirements.yml" \
      -p "$REPO_ROOT/collections" >/dev/null 2>&1 || warn "Collections-Install fehlgeschlagen (offline?)."
    export ANSIBLE_COLLECTIONS_PATH="$REPO_ROOT/collections"
  fi
}

ensure_ansible() {
  require_cmd ansible-playbook && return 0
  log "ansible-playbook fehlt — installiere via apt …"
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -q
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ansible
}

# Playbook als root ausführen (become wird damit zum No-op; kein passwordless
# sudo für become nötig). Relevante Env-Variablen werden durchgereicht.
run_playbook() {
  sudo --preserve-env=ANSIBLE_CONFIG,ANSIBLE_COLLECTIONS_PATH ansible-playbook "$@"
}

# Sicherheitsabfrage vor lokalen Änderungen.
local_guard() {
  if [[ "${ANVIL_DEV_FORCE:-0}" == "1" ]]; then
    warn "ANVIL_DEV_FORCE=1 — Sicherheitsabfrage übersprungen. Host: $(hostname)"
    return 0
  fi
  warn "⚠️  Dieser Befehl VERÄNDERT DIESEN HOST: $(hostname)"
  warn "    Nur auf einem WEGWERF-Host/VM ausführen — NICHT auf dem Arbeitsrechner!"
  if [[ ! -t 0 ]]; then
    die "Nicht-interaktiv. Bestätige mit:  ANVIL_DEV_FORCE=1 dev/dev.sh ..."
  fi
  local ans
  read -rp "    Zur Bestätigung den Hostnamen eingeben ($(hostname)): " ans
  [[ "$ans" == "$(hostname)" ]] || die "Abgebrochen (Eingabe ≠ Hostname)."
}

# Ein Preset lokal anwenden (Lauf A + B) und Idempotenz prüfen. Returnt 0/1.
local_apply() {
  local f="$1" preset; preset="$(basename "$f" .yml)"
  section "$preset: Lauf A (Konvergenz)"
  run_playbook -i "$REPO_ROOT/inventory.ini" "$REPO_ROOT/site.yml" -e "@$f"
  section "$preset: Lauf B (Idempotenz)"
  local logf; logf="$(mktemp)"
  run_playbook -i "$REPO_ROOT/inventory.ini" "$REPO_ROOT/site.yml" -e "@$f" | tee "$logf"
  local rl ch fa
  rl="$(grep -E 'ok=[0-9]+.*changed=[0-9]+' "$logf" | tail -n1 || true)"
  ch="$(echo "$rl" | grep -oP 'changed=\K[0-9]+' || echo '?')"
  fa="$(echo "$rl" | grep -oP 'failed=\K[0-9]+' || echo '?')"
  rm -f "$logf"
  log "Idempotenz: changed=$ch failed=$fa"
  [[ "$ch" == "0" && "$fa" == "0" ]]
}

# --- Befehle ------------------------------------------------------------------
cmd_list() { list_presets; }

cmd_vars() {
  local f; f="$(preset_file "${1:-}")"
  ensure_ansible
  section "Aufgelöste Variablen — Preset $(basename "$f" .yml)"
  ansible-playbook -i "$REPO_ROOT/inventory.ini" "$DEV_DIR/dump-vars.yml" -e "@$f"
}

cmd_lint() {
  ensure_lint_venv
  cd "$REPO_ROOT"
  local rc=0
  section "shellcheck"
  "$LINT_VENV/bin/shellcheck" -x bootstrap.sh lib/common.sh dev/dev.sh \
    roles/notify/files/anvil-notify roles/notify/files/anvil-notify-retry \
    roles/kernel_resilience/files/anvil-* roles/os_hardening/files/anvil-* \
    systemd/anvil-pull-run tests/*.sh 2>&1 || rc=1
  section "yamllint"
  "$LINT_VENV/bin/yamllint" -c .yamllint.yml . || rc=1
  section "ansible-lint"
  HOME="$DEV_DIR/.ansible-home" "$LINT_VENV/bin/ansible-lint" -q || rc=1
  section "ansible-playbook --syntax-check"
  "$LINT_VENV/bin/ansible-playbook" --syntax-check -i inventory.ini site.yml || rc=1
  if [[ "$rc" -eq 0 ]]; then
    ok "Lint: ALLES SAUBER"
  else
    die "Lint: es gab Befunde (siehe oben)."
  fi
}

cmd_check() {
  local f; f="$(preset_file "${1:-}")"
  ensure_ansible
  section "Dry-Run (--check --diff) — Preset $(basename "$f" .yml) — KEINE Änderungen"
  run_playbook -i "$REPO_ROOT/inventory.ini" "$REPO_ROOT/site.yml" --check --diff -e "@$f"
}

cmd_apply() {
  local f; f="$(preset_file "${1:-}")"
  ensure_ansible
  local_guard
  section "Apply Preset '$(basename "$f" .yml)' auf $(hostname)"
  if local_apply "$f"; then
    ok "Apply + Idempotenz PASS (Preset $(basename "$f" .yml))."
  else
    die "Apply/Idempotenz FAIL — siehe oben. Bei SSH-Problemen: sudo $REPO_ROOT/bootstrap.sh --rollback"
  fi
}

# Alle (unkritischen) Presets nacheinander auf DIESEM Host.
cmd_vm_matrix() {
  ensure_ansible
  local_guard
  section "Matrix auf $(hostname) — alle Presets nacheinander"
  # crown-totp-enrolled bewusst NICHT dabei (würde SSH ohne Secret sperren -> totp-test).
  local order="baseline minimal full crown crown-totp crown-egress"
  local p f results="" failed=0
  for p in $order; do
    f="$PRESET_DIR/$p.yml"; [[ -f "$f" ]] || continue
    if local_apply "$f"; then results+="  ✓ $p\n"; ok "$p: PASS"
    else results+="  ✗ $p\n"; failed=1; warn "$p: FAIL"; fi
  done
  section "Matrix-Ergebnis"
  printf '%b' "$results" >&2
  if [[ "$failed" -eq 0 ]]; then ok "Matrix: ALLE PRESETS PASS"; else die "Matrix: es gab Fehlschläge."; fi
}

# End-to-End-TOTP-Test (pam_oath) auf DIESEM Host: Test-Secret anlegen, enforced
# anwenden, PAM-Stack prüfen und echten OTP mit pamtester validieren.
cmd_totp_test() {
  local f="$PRESET_DIR/crown-totp-enrolled.yml"
  [[ -f "$f" ]] || die "Preset crown-totp-enrolled fehlt."
  ensure_ansible
  local_guard
  section "End-to-End TOTP-Test (pam_oath) auf $(hostname)"
  local hex="3132333435363738393031323334353637383930"   # 20-Byte Test-Secret (hex)
  printf 'HOTP/T30/6 %s - %s\n' "$DEV_ADMIN" "$hex" | sudo tee /etc/users.oath >/dev/null
  sudo chmod 600 /etc/users.oath

  section "Apply crown-totp-enrolled (TOTP ENFORCED)"
  run_playbook -i "$REPO_ROOT/inventory.ini" "$REPO_ROOT/site.yml" -e "@$f"

  section "Konfig-Prüfung"
  if sudo grep -q 'pam_oath.so' /etc/pam.d/sshd; then ok "pam_oath im sshd-PAM"; else die "pam_oath fehlt"; fi
  if sudo grep -qE '^#@include common-auth' /etc/pam.d/sshd; then ok "common-auth deaktiviert"; else die "common-auth noch aktiv"; fi
  if sudo grep -q 'publickey,keyboard-interactive' /etc/ssh/sshd_config.d/00-anvil-hardening.conf; then
    ok "AuthenticationMethods publickey,keyboard-interactive"
  else
    die "AuthenticationMethods falsch"
  fi

  section "End-to-End PAM-Test (pamtester)"
  if ! require_cmd pamtester || ! require_cmd oathtool; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y pamtester oathtool >/dev/null
  fi
  local otp; otp="$(oathtool --totp "$hex")"
  log "korrekter OTP=$otp"
  if echo "$otp" | sudo pamtester sshd "$DEV_ADMIN" authenticate; then
    ok "korrekter OTP akzeptiert"
  else
    die "korrekter OTP ABGELEHNT"
  fi
  if echo "000000" | sudo pamtester sshd "$DEV_ADMIN" authenticate 2>/dev/null; then
    die "falscher OTP AKZEPTIERT (PAM unsicher!)"
  else
    ok "falscher OTP abgelehnt"
  fi
  ok "TOTP END-TO-END: PASS (Test-Secret in /etc/users.oath)."
}

cmd_matrix() {
  cmd_lint
  local p
  for p in $(list_presets); do
    cmd_vars "$p"
  done
  ok "Matrix abgeschlossen (Lint + vars für alle Presets)."
}

# --- main ---------------------------------------------------------------------
main() {
  local cmd="${1:-}"; shift || true
  cmd="${cmd#--}"   # akzeptiert auch --vm-matrix, --apply, …
  case "$cmd" in
    list)        cmd_list ;;
    vars)        cmd_vars "${1:-}" ;;
    lint)        cmd_lint ;;
    matrix)      cmd_matrix ;;
    check)       cmd_check "${1:-}" ;;
    apply)       cmd_apply "${1:-}" ;;
    vm-matrix)   cmd_vm_matrix ;;
    totp-test)   cmd_totp_test ;;
    -h|h|help|"") usage ;;
    *)           die "Unbekannter Befehl: $cmd (siehe --help)" ;;
  esac
}

main "$@"
