# Anvil Runbook — Betrieb, Recovery & Notfälle

## Erstinbetriebnahme (frischer Server)

```bash
git clone <repo-url> /opt/anvil && cd /opt/anvil
cp config/anvil.conf.example config/anvil.conf      # ADMIN_USER + eigene Pubkeys
cp group_vars/all/vault.example.yml group_vars/all/vault.yml
ansible-vault encrypt group_vars/all/vault.yml      # Gotify-URL/Token eintragen
echo "DEIN-VAULT-PASSWORT" > .vault_pass && chmod 600 .vault_pass   # optional
sudo ./bootstrap.sh --check                         # Dry-Run
sudo ./bootstrap.sh apply                           # Härtung
```

**Vor dem ersten produktiven Lauf:** in einer Wegwerf-VM testen und während des
ersten Laufs eine **zweite SSH-Sitzung offen halten**.

---

## Aussperr-Wiederherstellung (SSH)

Anvil sichert vor jeder Änderung nach `/var/backups/anvil/<timestamp>/`. Wenn der
SSH-Zugang nach einem Lauf nicht funktioniert:

1. Über **Provider-/Hypervisor-Konsole** (oder Recovery) einloggen.
2. Rollback ausführen:
   ```bash
   cd /opt/anvil && sudo ./bootstrap.sh --rollback
   ```
   Das stellt u.a. `sshd_config`, sysctl, PAM und login.defs zurück und lädt sshd neu.
3. Prüfen: `sudo sshd -t && systemctl reload ssh`.

Häufige Ursachen: kein gültiger Key in `config/anvil.conf`, falscher `SSH_PORT`,
Firewall. Die `preflight`-Rolle verhindert die meisten dieser Fälle vorab.

---

## Kernel-Fallback (Boot-Resilienz)

### Funktionsweise
- **Auto-Reboot:** `kernel.panic={{N}}s` + (falls vorhanden) systemd-Watchdog sorgen
  dafür, dass ein panickender/hängender Kernel neu startet.
- **One-shot:** `anvil-prepare-kernel-reboot` bootet den neuen Kernel einmalig; der
  persistente Default bleibt der laufende (Known-Good) Kernel.
- **Assessment:** `anvil-boot-success.service` ruft nach dem Boot `anvil-boot-assess`:
  Erfolg → neuer Kernel wird Default; Fehlboot → Fallback auf Known-Good + **Gotify-Alarm**,
  defekter Kernel wird auf `hold` gesetzt.

### Sicher nach Kernel-Update neu starten
```bash
sudo /opt/anvil/bootstrap.sh --reboot-if-needed
# oder direkt:
sudo anvil-prepare-kernel-reboot
```

### Nach einem Fallback
```bash
cat /var/lib/anvil/last-fallback        # welcher Kernel scheiterte
apt-mark showhold                       # zeigt den gesperrten Kernel
# Ursache beheben, dann ggf. erneut versuchen:
sudo apt-mark unhold linux-image-<version>
sudo anvil-prepare-kernel-reboot
```

### Wichtig
- Mindestens **2 Kernel** vorhalten (Anvil deaktiviert das Autoremove alter Kernel).
- Hat die VM **kein `/dev/watchdog`**, fängt nur `kernel.panic` echte Panics ab; reine
  Hänger erfordern die Provider-Konsole zum Neustart.

---

## Benachrichtigungen (Gotify)

- Konfiguration: `/etc/anvil/notify.conf` (aus dem Vault).
- Test: `sudo anvil-notify --priority 5 --title "Test" "Hallo von $(hostname)"`
- Bei Gotify-Ausfall werden Nachrichten unter `/var/spool/anvil-notify/` gepuffert und
  von `anvil-notify-retry.timer` (alle 5 min) erneut zugestellt.
- Log: `/var/log/anvil/notify.log`.

---

## Regelbetrieb

| Aufgabe | Befehl |
|---|---|
| Erneut härten / Drift korrigieren | `sudo ./bootstrap.sh apply` |
| Nur einen Bereich | `sudo ./bootstrap.sh --tags ssh,firewall` |
| Dry-Run | `sudo ./bootstrap.sh --check` |
| Continuous Enforcement | `sudo ./bootstrap.sh --enable-timer <repo-url>` |
| Audit-Report ansehen | `ls /var/log/anvil/reports/` |
| fail2ban-Status | `sudo fail2ban-client status sshd` |
| Zeitsync prüfen | `chronyc tracking` |
| AIDE manuell prüfen | `sudo /etc/cron.daily/anvil-aide` |

---

## Optionale, riskante Schalter

- `os_pam_faillock=true` — Account-Lockout über PAM. **Lockout-Risiko**: vorher
  Konsolenzugang sicherstellen.
- `enable_grub_password=true` — schützt den GRUB-Editor; bei Fehlkonfiguration
  Konsolen-Lockout möglich. `vault_grub_password` muss gesetzt sein.
- `os_blacklist_usb_storage=true` — sperrt USB-Massenspeicher (Vorsicht bei Bare-Metal).
