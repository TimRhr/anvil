#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh — Anvil-Entrypoint (Pull-Modell)
#
# Bringt einen frischen Debian-/Ubuntu-Server lokal in einen gehärteten Zustand:
#   1. Vorbedingungen prüfen (root, OS, Config)
#   2. Ansible + Collections installieren (idempotent; offline-Fallback)
#   3. Härtungs-Playbook gegen localhost ausführen
#
# Verwendung:
#   sudo ./bootstrap.sh [apply] [--check] [--tags a,b] [--only rolle]
#                       [--rollback] [--reboot-if-needed] [--enable-timer URL]
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

# --- Repo-Wurzel ermitteln und Helfer laden ----------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
readonly SCRIPT_DIR
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

readonly CONFIG_FILE="$SCRIPT_DIR/config/anvil.conf"
readonly PLAYBOOK="$SCRIPT_DIR/site.yml"
readonly INVENTORY="$SCRIPT_DIR/inventory.ini"

# Temporäre Variablen-Datei (extra-vars). Wird per EXIT-Trap aufgeräumt — robust
# auch bei Fehlern/`die` und unter `set -u` (kein fragiler RETURN-Trap).
ANVIL_TMP_VARS=""
cleanup() { [[ -n "${ANVIL_TMP_VARS:-}" ]] && rm -f "$ANVIL_TMP_VARS"; return 0; }
trap cleanup EXIT

# --- Standardwerte für Optionen ----------------------------------------------
MODE="apply"            # apply | rollback | reboot | enable-timer
CHECK_MODE=false
ANSIBLE_TAGS=""
PULL_URL=""

usage() {
  cat <<'EOF'
Anvil — Server-Bootstrap & Hardening

  sudo ./bootstrap.sh [BEFEHL] [OPTIONEN]

BEFEHLE:
  apply                 Vollständige Härtung anwenden (Standard)
  --rollback            Letztes Config-Backup wiederherstellen
  --reboot-if-needed    Nach Kernel-Update sicher rebooten (Kernel-Fallback aktiv)
  --enable-timer URL    Continuous Enforcement via ansible-pull aktivieren
  --status              Sicherheitsstatus jetzt erzeugen + an Gotify senden

OPTIONEN:
  --check               Dry-Run (zeigt Änderungen, ändert nichts)
  --tags a,b,c          Nur bestimmte Bereiche (z.B. ssh,firewall,time)
  --only ROLLE          Nur eine Rolle (z.B. ssh_hardening) + preflight
  -h, --help            Diese Hilfe

BEISPIELE:
  sudo ./bootstrap.sh --check
  sudo ./bootstrap.sh apply
  sudo ./bootstrap.sh --tags ssh,firewall
  sudo ./bootstrap.sh --only time_sync
  sudo ./bootstrap.sh --reboot-if-needed
EOF
}

# --- Optionen parsen ----------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      apply)              MODE="apply" ;;
      --check|-n)         CHECK_MODE=true ;;
      --tags)             ANSIBLE_TAGS="${2:?--tags benötigt einen Wert}"; shift ;;
      --only)             ANSIBLE_TAGS="always,${2:?--only benötigt eine Rolle}"; shift ;;
      --rollback)         MODE="rollback" ;;
      --reboot-if-needed) MODE="reboot" ;;
      --enable-timer)     MODE="enable-timer"; PULL_URL="${2:?--enable-timer benötigt eine Repo-URL}"; shift ;;
      --status)           MODE="status" ;;
      -h|--help)          usage; exit 0 ;;
      *)                  die "Unbekannte Option: $1 (siehe --help)" ;;
    esac
    shift
  done
}

# --- Logging initialisieren ---------------------------------------------------
init_logging() {
  mkdir -p "$anvil_log_dir" 2>/dev/null || true
  ANVIL_LOGFILE="$anvil_log_dir/anvil-$(date '+%Y%m%d-%H%M%S').log"
  export ANVIL_LOGFILE
  : >"$ANVIL_LOGFILE" 2>/dev/null || ANVIL_LOGFILE=""
}

# --- Ansible installieren (idempotent, offline-Fallback) ---------------------
ensure_ansible() {
  if require_cmd ansible-playbook; then
    ok "Ansible bereits vorhanden ($(ansible-playbook --version 2>/dev/null | head -n1))."
  else
    section "Ansible-Installation"
    require_cmd apt-get || die "apt-get nicht gefunden — nur Debian/Ubuntu wird unterstützt."
    log "Installiere ansible, python3, curl, git via apt …"
    export DEBIAN_FRONTEND=noninteractive
    run apt-get update -q
    run apt-get install -y --no-install-recommends ansible python3 curl git
    require_cmd ansible-playbook || die "Ansible-Installation fehlgeschlagen."
    ok "Ansible installiert."
  fi

  # Das apt-Paket "ansible" bringt community.general/ansible.posix bereits in
  # passender Version mit. Nur nachinstallieren, wenn sie wirklich fehlen
  # (z.B. bei reinem ansible-core) — sonst nichts überschreiben.
  if ! ansible-galaxy collection list community.general >/dev/null 2>&1 \
     || ! ansible-galaxy collection list ansible.posix >/dev/null 2>&1; then
    log "Benötigte Collections fehlen — installiere aus requirements.yml …"
    if ! ansible-galaxy collection install -r "$SCRIPT_DIR/requirements.yml" \
         >>"${ANVIL_LOGFILE:-/dev/null}" 2>&1; then
      warn "Collections konnten nicht installiert werden (offline?). Nutze System-Collections."
    else
      ok "Collections installiert."
    fi
  else
    ok "Benötigte Collections vorhanden (System/apt-Bundle)."
  fi
}

# --- Extra-Vars-Datei (JSON) aus anvil.conf erzeugen -------------------------
# Übergibt Admin-User, Public-Keys und Toggles sauber an Ansible.
build_extra_vars() {
  local out="$1"
  local keys_json="" k esc
  for k in "${ADMIN_PUBKEYS[@]}"; do
    [[ -z "${k// /}" ]] && continue
    esc="${k//\\/\\\\}"; esc="${esc//\"/\\\"}"
    keys_json+="\"$esc\","
  done
  keys_json="[${keys_json%,}]"

  # App-Overlay-Profile (Bash-Array ANVIL_PROFILES) → JSON-Array.
  local profiles_json="" p
  for p in "${ANVIL_PROFILES[@]:-}"; do
    [[ -z "${p// /}" ]] && continue
    [[ "$p" =~ ^[a-z0-9_-]+$ ]] || die "Ungültiger Profilname in ANVIL_PROFILES: '$p'"
    profiles_json+="\"$p\","
  done
  profiles_json="[${profiles_json%,}]"

  # Bash-Bool (true/false-String) → JSON-Bool. $2 = Default, falls nicht gesetzt
  # (muss dem Default in group_vars/all/main.yml entsprechen!).
  jb() { local v="${!1:-$2}"; [[ "$v" == "true" ]] && echo true || echo false; }

  cat >"$out" <<EOF
{
  "admin_user": "${ADMIN_USER}",
  "admin_pubkeys": ${keys_json},
  "ssh_port": ${SSH_PORT:-22},
  "enable_fail2ban": $(jb ENABLE_FAIL2BAN true),
  "enable_aide": $(jb ENABLE_AIDE true),
  "enable_auto_updates": $(jb ENABLE_AUTO_UPDATES true),
  "enable_apparmor": $(jb ENABLE_APPARMOR true),
  "enable_auditd": $(jb ENABLE_AUDITD true),
  "enable_nts": $(jb ENABLE_NTS false),
  "enable_grub_password": $(jb ENABLE_GRUB_PASSWORD false),
  "enable_remote_syslog": $(jb ENABLE_REMOTE_SYSLOG false),
  "enable_watchdog": $(jb ENABLE_WATCHDOG true),
  "kernel_panic_reboot_seconds": ${KERNEL_PANIC_REBOOT_SECONDS:-10},
  "kernel_keep_count": ${KERNEL_KEEP_COUNT:-2},
  "anvil_hostname": "${ANVIL_HOSTNAME:-}",
  "timezone": "${ANVIL_TIMEZONE:-Europe/Berlin}",
  "anvil_posture": "${ANVIL_POSTURE:-baseline}",
  "ssh_mfa_method": "${ANVIL_SSH_MFA:-auto}",
  "compliance_oncalendar": "${ANVIL_COMPLIANCE_SCHEDULE:-Sun *-*-* 04:00:00}",
  "anvil_profiles": ${profiles_json}
}
EOF
}

# --- Best-effort-Benachrichtigung über installiertes anvil-notify -------------
notify() {
  local priority="$1" title="$2" message="$3"
  if [[ -x /usr/local/bin/anvil-notify ]]; then
    /usr/local/bin/anvil-notify --priority "$priority" --title "$title" "$message" \
      >>"${ANVIL_LOGFILE:-/dev/null}" 2>&1 || true
  fi
}

# --- Hauptablauf: Härtung anwenden -------------------------------------------
do_apply() {
  load_config "$CONFIG_FILE"
  ensure_ansible

  ANVIL_TMP_VARS="$(mktemp /tmp/anvil-vars.XXXXXX.json)"
  build_extra_vars "$ANVIL_TMP_VARS"

  local -a cmd=(ansible-playbook -i "$INVENTORY" "$PLAYBOOK" -e "@$ANVIL_TMP_VARS")
  # Word-Splitting ist hier gewollt: vault_args liefert 0 oder 2 Tokens.
  # shellcheck disable=SC2046,SC2207
  cmd+=($(vault_args "$SCRIPT_DIR"))
  [[ -n "$ANSIBLE_TAGS" ]] && cmd+=(--tags "$ANSIBLE_TAGS")
  if [[ "$CHECK_MODE" == true ]]; then
    cmd+=(--check --diff)
    section "Dry-Run (--check) — es werden KEINE Änderungen vorgenommen"
  else
    section "Anvil — Härtung wird angewendet"
  fi

  log "Starte: ${cmd[*]}"
  ANSIBLE_CONFIG="$SCRIPT_DIR/ansible.cfg" "${cmd[@]}" || {
    notify 9 "Anvil fehlgeschlagen" "Härtung auf $(hostname) abgebrochen — siehe $ANVIL_LOGFILE"
    die "Ansible-Lauf fehlgeschlagen. Bei SSH-Problemen: sudo $0 --rollback"
  }

  if [[ "$CHECK_MODE" != true ]]; then
    ok "Härtung abgeschlossen."
    if [[ -f /var/run/reboot-required ]]; then
      warn "Ein Reboot ist erforderlich (Kernel-Update). Sicher rebooten: sudo $0 --reboot-if-needed"
    fi
  else
    ok "Dry-Run abgeschlossen."
  fi
}

# --- Rollback: jüngstes Config-Backup wiederherstellen ------------------------
do_rollback() {
  local bdir; bdir="$(latest_backup_dir "$anvil_backup_dir" || true)"
  [[ -n "$bdir" && -d "$bdir" ]] || die "Kein Backup unter $anvil_backup_dir gefunden."
  section "Rollback aus $bdir"
  warn "Stelle gesicherte Konfigurationsdateien wieder her …"

  # Das Backup spiegelt absolute Pfade unter $bdir/files/.
  if [[ -d "$bdir/files" ]]; then
    ( cd "$bdir/files" && find . -type f -print0 |
        while IFS= read -r -d '' f; do
          dest="/${f#./}"
          install -D -m "$(stat -c '%a' "$f")" "$f" "$dest"
          printf 'wiederhergestellt: %s\n' "$dest" >&2
        done )
  fi

  # sshd-Konfiguration validieren und neu laden, falls betroffen.
  if sshd -t 2>/dev/null; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
  else
    warn "sshd-Konfiguration nach Rollback ungültig — bitte manuell prüfen!"
  fi
  sysctl --system >/dev/null 2>&1 || true

  # RB-1: systemd-Drop-ins neu einlesen und betroffene Dienste reaktivieren,
  # damit zurückgerollte Konfiguration auch greift (best effort).
  log "Reaktiviere betroffene Dienste …"
  systemctl daemon-reload 2>/dev/null || true
  local svc
  for svc in ufw fail2ban chrony systemd-journald; do
    systemctl reload "$svc" 2>/dev/null || systemctl try-restart "$svc" 2>/dev/null || true
  done
  service auditd restart 2>/dev/null || true

  ok "Rollback abgeschlossen. Bei Bedarf System neu starten."
}

# --- Sicherer Reboot nach Kernel-Update (Fallback-fähig) ---------------------
do_reboot() {
  local prep=/usr/local/sbin/anvil-prepare-kernel-reboot
  if [[ -x "$prep" ]]; then
    section "Sicherer Kernel-Reboot (One-shot mit Fallback)"
    run "$prep"
  else
    warn "Kernel-Resilience nicht installiert — führe normalen Reboot aus."
    section "Reboot"
    systemctl reboot
  fi
}

# --- Continuous Enforcement aktivieren ---------------------------------------
do_enable_timer() {
  [[ -n "$PULL_URL" ]] || die "Keine Repo-URL angegeben."
  ensure_ansible
  section "Continuous Enforcement aktivieren (Pull + Hardening)"
  install -d -m 0750 /etc/anvil
  {
    printf 'ANVIL_REPO_DIR=%s\n' "$SCRIPT_DIR"
    printf 'ANVIL_PULL_URL=%s\n' "$PULL_URL"
  } >/etc/anvil/pull-env
  chmod 0640 /etc/anvil/pull-env
  install -m 0755 "$SCRIPT_DIR/systemd/anvil-pull-run" /usr/local/sbin/anvil-pull-run
  install -m 0644 "$SCRIPT_DIR/systemd/anvil-pull.service" /etc/systemd/system/
  install -m 0644 "$SCRIPT_DIR/systemd/anvil-pull.timer" /etc/systemd/system/
  systemctl daemon-reload
  systemctl enable --now anvil-pull.timer
  ok "anvil-pull.timer aktiviert (Repo: $PULL_URL, Checkout: $SCRIPT_DIR)."
}

# --- Sicherheitsstatus on demand ---------------------------------------------
do_status() {
  local s=/usr/local/sbin/anvil-status-report
  [[ -x "$s" ]] || die "Status-Skript fehlt — erst 'sudo $0 apply' ausführen (installiert es)."
  section "Sicherheitsstatus erzeugen"
  exec "$s"
}

# --- main ---------------------------------------------------------------------
main() {
  parse_args "$@"
  require_root
  # group_vars-Pfade brauchen wir früh fürs Logging — Defaults setzen:
  anvil_log_dir="${anvil_log_dir:-/var/log/anvil}"
  anvil_backup_dir="${anvil_backup_dir:-/var/backups/anvil}"
  init_logging
  assert_supported_os

  case "$MODE" in
    apply)        do_apply ;;
    rollback)     do_rollback ;;
    reboot)       do_reboot ;;
    enable-timer) do_enable_timer ;;
    status)       do_status ;;
    *)            die "Unbekannter Modus: $MODE" ;;
  esac
}

main "$@"
