#!/usr/bin/env bash
# =============================================================================
# dev/dev.sh — TEMPORÄRES Entwickler-Werkzeug für Anvil.
#
#   ⚠️  NICHT in den prod-Branch übernehmen! Der gesamte dev/-Ordner wird vor
#       der Veröffentlichung entfernt (siehe dev/README.md).
#
# Testet verschiedene Settings-Presets (dev/presets/*.yml) schnell durch, ohne
# dass config/anvil.conf editiert werden muss. Sicher: 'apply' läuft NUR in
# einer multipass-Wegwerf-VM, niemals gegen den lokalen Host.
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
readonly REPO_ROOT
DEV_DIR="$REPO_ROOT/dev"
PRESET_DIR="$DEV_DIR/presets"
LINT_VENV="$DEV_DIR/.venv"

# shellcheck source=/dev/null
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/common.sh"

export ANSIBLE_CONFIG="$REPO_ROOT/ansible.cfg"
[[ -d "$REPO_ROOT/collections/ansible_collections" ]] && \
  export ANSIBLE_COLLECTIONS_PATH="$REPO_ROOT/collections"

usage() {
  cat <<'EOF'
dev/dev.sh — Anvil Entwickler-Harness (temporär, nicht für prod)

  dev/dev.sh <befehl> [argumente]

BEFEHLE:
  list                     Presets auflisten
  vars <preset>            Aufgelöste Posture-/Toggle-Variablen anzeigen (safe, schnell)
  lint                     shellcheck + yamllint + ansible-lint + --syntax-check
  check <preset>           Dry-Run (--check --diff) lokal (sudo nötig, KEINE Änderungen)
  apply <preset> <vm>      Preset in multipass-VM <vm> anwenden (+ Idempotenz-Check)
  matrix                   lint + 'vars' für ALLE Presets (schnelle Gesamtprüfung)
  vm-up <vm> [release]     multipass-VM erstellen (release: 24.04 | 26.04, Default 24.04)
  vm-rm <vm>               multipass-VM löschen
  -h | --help              Diese Hilfe

BEISPIELE:
  dev/dev.sh lint
  dev/dev.sh vars crown
  dev/dev.sh matrix
  dev/dev.sh vm-up anvil-dev 24.04
  dev/dev.sh apply crown anvil-dev
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

# --- Befehle ------------------------------------------------------------------
cmd_list() { list_presets; }

cmd_vars() {
  local f; f="$(preset_file "${1:-}")"
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
  ensure_lint_venv
  section "Dry-Run (--check --diff) — Preset $(basename "$f" .yml) — KEINE Änderungen"
  warn "Läuft gegen DIESEN Host im check-Modus (nur Vorschau, keine Änderungen)."
  sudo --preserve-env=ANSIBLE_CONFIG,ANSIBLE_COLLECTIONS_PATH \
    "$LINT_VENV/bin/ansible-playbook" -i "$REPO_ROOT/inventory.ini" "$REPO_ROOT/site.yml" \
    --check --diff -e "@$f"
}

cmd_vm_up() {
  local vm="${1:?VM-Name fehlt}" release="${2:-24.04}"
  require_cmd multipass || die "multipass nicht installiert."
  section "multipass-VM '$vm' (Ubuntu $release) erstellen"
  run multipass launch "$release" --name "$vm" --memory 2G --disk 12G --cpus 2
  ok "VM '$vm' bereit. Apply: dev/dev.sh apply <preset> $vm"
}

cmd_vm_rm() {
  local vm="${1:?VM-Name fehlt}"
  require_cmd multipass || die "multipass nicht installiert."
  run multipass delete --purge "$vm"
  ok "VM '$vm' gelöscht."
}

cmd_apply() {
  local f vm preset
  f="$(preset_file "${1:-}")"; preset="$(basename "$f" .yml)"
  vm="${2:-}"
  [[ -n "$vm" ]] || die "apply benötigt eine VM: dev/dev.sh apply $preset <vm>  (Sicherheit: kein localhost!)"
  require_cmd multipass || die "multipass nicht installiert."
  multipass info "$vm" >/dev/null 2>&1 || die "VM '$vm' existiert nicht. Erst: dev/dev.sh vm-up $vm"

  section "Apply Preset '$preset' in VM '$vm'"
  local tgz=/tmp/anvil-dev.tgz
  log "Repo paketieren (ohne .git/collections/dev/.venv) …"
  tar czf "$tgz" -C "$REPO_ROOT" \
    --exclude='./.git' --exclude='./collections' --exclude='./dev/.venv' \
    --exclude='./dev/.ansible-home' .
  run multipass transfer "$tgz" "$vm:/tmp/anvil-dev.tgz"
  run multipass transfer "$f" "$vm:/tmp/anvil-preset.yml"

  log "In der VM ausrollen …"
  # Single quotes gewollt: Variablen werden von der REMOTE-Shell expandiert.
  # shellcheck disable=SC2016
  multipass exec "$vm" -- sudo bash -euo pipefail -c '
    rm -rf /opt/anvil && mkdir -p /opt/anvil
    tar xzf /tmp/anvil-dev.tgz -C /opt/anvil
    command -v ansible-playbook >/dev/null 2>&1 || { export DEBIAN_FRONTEND=noninteractive; apt-get update -q && apt-get install -y --no-install-recommends ansible; }
    cd /opt/anvil
    echo "=== Lauf A (Konvergenz) ==="
    ANSIBLE_CONFIG=ansible.cfg ansible-playbook -i inventory.ini site.yml -e @/tmp/anvil-preset.yml
    echo "=== Lauf B (Idempotenz) ==="
    ANSIBLE_CONFIG=ansible.cfg ansible-playbook -i inventory.ini site.yml -e @/tmp/anvil-preset.yml | tee /tmp/anvil-runB.log
    rl="$(grep -E "ok=[0-9]+.*changed=[0-9]+" /tmp/anvil-runB.log | tail -n1)"
    ch="$(echo "$rl" | grep -oP "changed=\K[0-9]+")"; fa="$(echo "$rl" | grep -oP "failed=\K[0-9]+")"
    echo "Idempotenz: changed=$ch failed=$fa"
    [ "${ch:-1}" = "0" ] && [ "${fa:-1}" = "0" ] && echo "IDEMPOTENZ: PASS" || { echo "IDEMPOTENZ: FAIL"; exit 1; }
  '
  ok "Apply + Idempotenz in '$vm' abgeschlossen (Preset $preset). Zugang: multipass shell $vm"
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
  case "$cmd" in
    list)        cmd_list ;;
    vars)        cmd_vars "${1:-}" ;;
    lint)        cmd_lint ;;
    check)       cmd_check "${1:-}" ;;
    apply)       cmd_apply "${1:-}" "${2:-}" ;;
    matrix)      cmd_matrix ;;
    vm-up)       cmd_vm_up "${1:-}" "${2:-}" ;;
    vm-rm)       cmd_vm_rm "${1:-}" ;;
    -h|--help|"") usage ;;
    *)           die "Unbekannter Befehl: $cmd (siehe --help)" ;;
  esac
}

main "$@"
