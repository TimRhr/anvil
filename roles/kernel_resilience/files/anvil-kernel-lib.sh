#!/usr/bin/env bash
# =============================================================================
# anvil-kernel-lib.sh — gemeinsame Helfer für die Kernel-Fallback-Skripte
# Wird von anvil-prepare-kernel-reboot und anvil-boot-assess gesourct.
# =============================================================================

# Diese Variablen werden von den sourcenden Skripten genutzt (prepare/boot-assess).
# shellcheck disable=SC2034
ANVIL_STATE_DIR=/var/lib/anvil
# shellcheck disable=SC2034
ANVIL_INTENDED_FILE="$ANVIL_STATE_DIR/intended-kernel"
# shellcheck disable=SC2034
ANVIL_FALLBACK_FILE="$ANVIL_STATE_DIR/last-fallback"
GRUBENV=/boot/grub/grubenv
GRUBCFG=/boot/grub/grub.cfg

klog() { logger -t anvil-kernel "$*" 2>/dev/null || true; printf '%s\n' "$*" >&2; }

knotify() {
  local prio="$1" title="$2"; shift 2
  [[ -x /usr/local/bin/anvil-notify ]] &&
    /usr/local/bin/anvil-notify --priority "$prio" --title "$title" "$*" || true
}

# Neueste installierte Kernel-Version ermitteln
newest_kernel() {
  if command -v linux-version >/dev/null 2>&1; then
    linux-version list | sort -V | tail -n1
  else
    # shellcheck disable=SC2012
    ls -1 /boot/vmlinuz-* 2>/dev/null | sed 's#.*/vmlinuz-##' | sort -V | tail -n1
  fi
}

# GRUB-menuentry-ID für eine Kernel-Version aus grub.cfg holen (ohne Recovery)
grub_id_for_kernel() {
  local kver="$1"
  grep "menuentry_id_option" "$GRUBCFG" 2>/dev/null \
    | grep -F "$kver" \
    | grep -v recovery \
    | sed -nE "s/.*menuentry_id_option '([^']+)'.*/\1/p" \
    | head -n1
}

# Persistenten Default-Boot-Eintrag setzen
grub_set_default() {
  local id="$1"
  [[ -n "$id" ]] || return 1
  grub-set-default "$id" 2>/dev/null || grub-editenv "$GRUBENV" set saved_entry="$id"
}

# Einmaligen nächsten Boot setzen (one-shot, wird beim Booten verbraucht)
grub_reboot_once() {
  local id="$1"
  [[ -n "$id" ]] || return 1
  grub-reboot "$id" 2>/dev/null || grub-editenv "$GRUBENV" set next_entry="$id"
}

# recordfail/next_entry-Reste aufräumen
grub_clear_flags() {
  grub-editenv "$GRUBENV" unset recordfail 2>/dev/null || true
  grub-editenv "$GRUBENV" unset next_entry 2>/dev/null || true
}
