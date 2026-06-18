#!/usr/bin/env bash
# =============================================================================
# lib/common.sh — Gemeinsame Bash-Helfer für Anvil
#
# Wird von bootstrap.sh gesourct. Enthält Logging, Fehlerbehandlung,
# OS-Erkennung, das Einlesen von config/anvil.conf sowie Backup/Rollback.
#
# Erwartet, dass die aufrufende Datei bereits `set -euo pipefail` gesetzt hat.
# =============================================================================

# --- Farben (nur wenn an ein Terminal ausgegeben wird) -----------------------
if [[ -t 2 ]]; then
  C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YLW=$'\033[0;33m'
  C_BLU=$'\033[0;34m'; C_BLD=$'\033[1m'; C_RST=$'\033[0m'
else
  C_RED=''; C_GRN=''; C_YLW=''; C_BLU=''; C_BLD=''; C_RST=''
fi

# Globales Logfile (von bootstrap.sh gesetzt). Fallback auf stderr-only.
ANVIL_LOGFILE="${ANVIL_LOGFILE:-}"

# --- Logging ------------------------------------------------------------------
_log_raw() {
  # $1 = farbiges Label, $2 = Klartext-Level, restliche = Nachricht
  local color="$1" level="$2"; shift 2
  local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '%s %s%-5s%s %s\n' "$ts" "$color" "$level" "$C_RST" "$*" >&2
  if [[ -n "$ANVIL_LOGFILE" ]]; then
    printf '%s %-5s %s\n' "$ts" "$level" "$*" >>"$ANVIL_LOGFILE" 2>/dev/null || true
  fi
}

log()   { _log_raw "$C_BLU" "INFO" "$@"; }
ok()    { _log_raw "$C_GRN" "OK"   "$@"; }
warn()  { _log_raw "$C_YLW" "WARN" "$@"; }
error() { _log_raw "$C_RED" "ERROR" "$@"; }

die() {
  # Beendet das Skript mit Fehlercode. $1 optional Exit-Code (Default 1).
  local code=1
  if [[ "${1:-}" =~ ^[0-9]+$ ]]; then code="$1"; shift; fi
  error "$@"
  exit "$code"
}

section() {
  printf '\n%s%s== %s ==%s\n' "$C_BLD" "$C_BLU" "$*" "$C_RST" >&2
  if [[ -n "$ANVIL_LOGFILE" ]]; then
    printf '\n== %s ==\n' "$*" >>"$ANVIL_LOGFILE" 2>/dev/null || true
  fi
}

# --- Befehl ausführen (mit Logging) ------------------------------------------
run() {
  log "→ $*"
  if ! "$@"; then
    die "Befehl fehlgeschlagen: $*"
  fi
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Anvil muss als root bzw. via sudo laufen (z.B. 'sudo ./bootstrap.sh')."
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1
}

# --- OS-Erkennung -------------------------------------------------------------
# Setzt globale Variablen: ANVIL_OS_ID, ANVIL_OS_VERSION_ID, ANVIL_OS_FAMILY
detect_os() {
  [[ -r /etc/os-release ]] || die "/etc/os-release nicht lesbar — OS nicht erkennbar."
  # shellcheck disable=SC1091
  . /etc/os-release
  ANVIL_OS_ID="${ID:-unknown}"
  ANVIL_OS_VERSION_ID="${VERSION_ID:-unknown}"
  ANVIL_OS_FAMILY="${ID_LIKE:-$ANVIL_OS_ID}"
  export ANVIL_OS_ID ANVIL_OS_VERSION_ID ANVIL_OS_FAMILY
}

assert_supported_os() {
  detect_os

  # Offiziell getestete Versionen pro Distribution.
  local -A tested_versions
  tested_versions[ubuntu]="20.04 22.04 24.04 26.04"
  tested_versions[debian]="11 12"

  case "$ANVIL_OS_ID" in
    debian|ubuntu)
      local versions="${tested_versions[$ANVIL_OS_ID]:-}"
      local found=false
      local v
      for v in $versions; do
        if [[ "$ANVIL_OS_VERSION_ID" == "$v" ]]; then
          found=true
          break
        fi
      done
      if $found; then
        ok "Erkanntes OS: ${PRETTY_NAME:-$ANVIL_OS_ID $ANVIL_OS_VERSION_ID} — getestet."
      else
        warn "OS '${PRETTY_NAME:-$ANVIL_OS_ID $ANVIL_OS_VERSION_ID}' nicht offiziell getestet (erwartet: $versions). Fahre trotzdem fort — bitte vor Produktivbetrieb verifizieren."
      fi
      ;;
    *)
      if [[ "$ANVIL_OS_FAMILY" == *debian* ]]; then
        warn "OS '$ANVIL_OS_ID' nicht offiziell getestet, aber Debian-kompatibel — fahre fort."
      else
        die "Nicht unterstütztes OS: '$ANVIL_OS_ID'. Anvil unterstützt nur Debian/Ubuntu."
      fi
      ;;
  esac
}

# --- config/anvil.conf einlesen ----------------------------------------------
# Liest die Bash-Konfigurationsdatei sicher ein und validiert Pflichtfelder.
# Setzt u.a. ADMIN_USER und das Array ADMIN_PUBKEYS.
load_config() {
  local conf="$1"
  [[ -f "$conf" ]] || die "Konfigurationsdatei fehlt: $conf
  → Vorlage kopieren: cp config/anvil.conf.example config/anvil.conf"

  # Defensive Prüfung gegen offensichtlich gefährliche Konstrukte.
  if grep -Eq '(\$\(|`|\beval\b|\brm[[:space:]]+-rf\b)' "$conf"; then
    die "Konfigurationsdatei enthält unzulässige Shell-Konstrukte: $conf"
  fi

  # shellcheck disable=SC1090
  . "$conf"

  ADMIN_USER="${ADMIN_USER:-}"
  [[ -n "$ADMIN_USER" ]] || die "ADMIN_USER ist in $conf nicht gesetzt."
  [[ "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] \
    || die "ADMIN_USER '$ADMIN_USER' ist kein gültiger Linux-Benutzername."

  if [[ "${#ADMIN_PUBKEYS[@]}" -eq 0 ]]; then
    die "ADMIN_PUBKEYS ist leer in $conf — ohne SSH-Key würdest du dich aussperren."
  fi
  validate_pubkeys
  ok "Konfiguration geladen: User='$ADMIN_USER', ${#ADMIN_PUBKEYS[@]} SSH-Key(s)."
}

# Prüft jeden Public-Key grob auf gültiges Format.
validate_pubkeys() {
  local key valid=0
  for key in "${ADMIN_PUBKEYS[@]}"; do
    [[ -z "${key// /}" ]] && continue
    if [[ "$key" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-[a-z0-9-]+|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-[a-z0-9-]+@openssh\.com)[[:space:]]+[A-Za-z0-9+/=]+ ]]; then
      valid=$((valid + 1))
    else
      die "Ungültiger SSH-Public-Key in ADMIN_PUBKEYS: '${key:0:40}...'"
    fi
  done
  [[ "$valid" -ge 1 ]] || die "Kein gültiger SSH-Public-Key gefunden."
}

# --- Vault-Passwort-Datei erkennen -------------------------------------------
# Gibt den --vault-password-file-Parameter zurück, falls .vault_pass existiert.
vault_args() {
  local repo_root="$1"
  if [[ -f "$repo_root/.vault_pass" ]]; then
    printf '%s' "--vault-password-file $repo_root/.vault_pass"
  fi
}

# --- Backup & Rollback --------------------------------------------------------
# Anvil-Rollen sichern geänderte Dateien selbst; dieser Helfer dient bootstrap.sh
# zum Auffinden/Wiederherstellen des jüngsten Backup-Satzes.
latest_backup_dir() {
  local base="${1:-/var/backups/anvil}"
  [[ -d "$base" ]] || return 1
  # Neuestes Unterverzeichnis (Zeitstempel-sortiert).
  find "$base" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort | tail -n1
}
