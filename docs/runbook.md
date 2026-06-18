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

## Provisionierung mit multipass (24.04 & 26.04)

### VM starten

```bash
# Ubuntu 24.04
multipass launch 24.04 --name anvil-2404 --memory 2G --disk 10G

# Ubuntu 26.04
multipass launch 26.04 --name anvil-2604 --memory 2G --disk 10G
```

### Anvil in die VM bringen

```bash
# Variante A — Transfer vom Host (Repo lokal geklont):
multipass transfer -r /opt/anvil anvil-2404:/opt/anvil

# Variante B — Direkt in der VM klonen (Netzugang vorausgesetzt):
multipass shell anvil-2404
# Im Gast:
sudo mkdir -p /opt && sudo chown ubuntu:ubuntu /opt
git clone <repo-url> /opt/anvil
```

### Konfiguration & Vault

```bash
multipass shell anvil-2404
cd /opt/anvil

# Config anlegen (Admin-User + eigenen SSH-Public-Key eintragen):
cp config/anvil.conf.example config/anvil.conf
$EDITOR config/anvil.conf

# Vault anlegen und verschlüsseln:
cp group_vars/all/vault.example.yml group_vars/all/vault.yml
ansible-vault encrypt group_vars/all/vault.yml      # Passwort vergeben
echo "MEIN-VAULT-PASSWORT" > .vault_pass && chmod 600 .vault_pass
```

> **SSH-Key in die VM bekommen:** entweder via `multipass transfer ~/.ssh/id_ed25519.pub anvil-2404:` (dann in der VM in `config/anvil.conf` eintragen), oder direkt in der Shell per `echo … >> config/anvil.conf`.

### Ausführen

```bash
sudo ./bootstrap.sh --check     # Dry-Run — zeigt Änderungen, ändert nichts
sudo ./bootstrap.sh apply       # Härtung anwenden
```

### Login verifizieren

```bash
# Vom Host aus:
ssh -i ~/.ssh/<dein-key> -p <port> <admin-user>@<vm-ip>

# VM-IP ermitteln:
multipass info anvil-2404 | grep IPv4
```

---

## Verifizierung (Idempotenz & Kernel-Fallback)

Nach erfolgreicher Provisionierung kann der gehärtete Zustand mit zwei Skripten geprüft werden.

### Idempotenz-Check

[`tests/provision-check.sh`](../tests/provision-check.sh) führt `bootstrap.sh apply` zweimal aus und prüft, dass der zweite Lauf **changed=0** und **failed=0** meldet.

```bash
# In der provisionierten VM:
cd /opt/anvil
sudo tests/provision-check.sh
```

**Erwartet:** `PASS — Der zweite Apply-Lauf hat nichts verändert.`

Schlägt der Test fehl, mit `-v` wiederholen, um die nicht-idempotenten Tasks zu identifizieren:
```bash
sudo ./bootstrap.sh apply -v 2>&1 | grep -E '(changed|failed)'
```

### Kernel-Fallback-Assessment

[`tests/fallback-check.sh`](../tests/fallback-check.sh) testet die Logik von `anvil-boot-assess` **ohne echten Reboot**, non-destruktiv:

```bash
# In der provisionierten VM:
cd /opt/anvil
sudo tests/fallback-check.sh
```

Geprüft werden drei Pfade:
1. **Fallback-Pfad:** Bogus-Kernel → `last-fallback` geschrieben, `intended-kernel` entfernt, Gotify-Eintrag im Log.
2. **Erfolgs-Pfad:** `intended-kernel == uname -r` → laufender Kernel als GRUB-Default, `intended-kernel` entfernt.
3. **Normaler Boot:** Kein `intended-kernel` → `saved_entry` gesetzt, kein Fallback.

**Erwartet:** `PASS — Alle Kernel-Fallback-Prüfungen bestanden.`

---

## Echter Kernel-Fallback-Test (manuell)

Dieser Test bootet die VM neu und prüft den realen Fallback-Mechanismus. **Nur in einer Test-VM durchführen.**

### Vorbereitung

```bash
# 1. Sicherstellen, dass mindestens 2 Kernel installiert sind:
dpkg -l 'linux-image-*' | grep '^ii' | wc -l     # sollte ≥ 2 sein

# 2. Aktuelle Boot-Reihenfolge notieren:
grub-editenv /boot/grub/grubenv list
```

### Defekten Kernel simulieren

Den neuen (neuesten) One-shot-Kernel künstlich „defekt" machen:

```bash
# Neueste Kernel-Version ermitteln und initrd manipulieren:
newest=$(ls -1 /boot/vmlinuz-* | sed 's#.*/vmlinuz-##' | sort -V | tail -n1)
sudo mv /boot/initrd.img-"$newest" /boot/initrd.img-"$newest".bak

# Oder: Boot-Parameter manipulieren, die zum Panic führen:
# sudo sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/&panic=-1 /' /etc/default/grub.d/99-anvil.cfg
# Achtung: obiger Eingriff erfordert update-grub und ist nicht idempotent!
```

### Reboot & Fallback auslösen

```bash
# One-shot auf neuen Kernel setzen + reboot:
sudo /opt/anvil/bootstrap.sh --reboot-if-needed

# Oder direkt (wenn bootstrap.sh nicht verfügbar):
sudo anvil-prepare-kernel-reboot
```

Die VM startet automatisch neu. Nach dem Boot:

```bash
# Prüfen, ob der Fallback eingeleitet wurde:
cat /var/lib/anvil/last-fallback          # zeigt: defekte Version -> aktuelle Version

# Gotify-Alarm prüfen:
grep -i 'fallback\|kernel' /var/log/anvil/notify.log

# Gesperrten Kernel anzeigen:
apt-mark showhold
```

**Erwartet:** VM bootet den alten (Known-Good) Kernel, `last-fallback` existiert, Gotify-Alarm mit `⚠️ Kernel-Fallback aktiv` ist im Log.

### Wiederherstellen

```bash
# Gesperrten Kernel freigeben (Versionsnummer aus last-fallback):
sudo apt-mark unhold linux-image-<defekte-version>

# Kaputte initrd wiederherstellen:
sudo mv /boot/initrd.img-<version>.bak /boot/initrd.img-<version>

# Erneuten Versuch starten:
sudo anvil-prepare-kernel-reboot
```

---

## Distributionsspezifika Ubuntu 26.04

Ubuntu 26.04 bringt einige Änderungen gegenüber 24.04, die beim Provisioning mit Anvil bereits berücksichtigt wurden. Hier eine Übersicht als Checkliste bei der Verifizierung.

### sudo-rs

Ubuntu 26.04 liefert **sudo-rs** (Rust-Implementierung) statt des klassischen sudo. Alle Anvil-Templates und Tasks sind damit kompatibel. Hintergrund:
- Anvil schreibt `/etc/sudoers.d/<user>` als per `visudo -cf` validiertes Template ([roles/base_user/templates/sudoers.j2](../roles/base_user/templates/sudoers.j2)) und setzt nur sudo-rs-kompatible Defaults (`timestamp_timeout`) — kein `timestamp_type`/`logfile`.
- `sudo -i` und `sudo -s` verhalten sich identisch.

### Fehlende/ersetzte Pakete

| Komponente | 24.04 | 26.04 | Status |
|---|---|---|---|
| sudo | sudo (C) | sudo-rs (Rust) | ✅ kompatibel (sudoers nur mit `timestamp_timeout`) |
| coreutils | GNU coreutils | ggf. uutils-coreutils (Rust) | ◐ kompatibel, nicht gesondert verifiziert |
| `community.general.yaml`-Callback | enthalten | entfernt | ✅ `ansible.cfg` nutzt `stdout_callback = default` + `result_format = yaml` |
| Deprecation-Noise | gering | erhöht (Collection-Deprecations) | ✅ via `deprecation_warnings = False` in `ansible.cfg` unterdrückt |

### Drop-in-Verzeichnisse

- `systemd/journald.conf.d/` existiert auf 26.04 von Haus aus — die `file`-Task in der logging-Rolle ist dennoch idempotent.
- `/etc/default/grub.d/` ebenfalls vorhanden — die kernel_resilience-Rolle legt es defensiv selbst an.

### Collection-Kompatibilität

Die in `requirements.yml` festgeschriebenen Collection-Versionen sind auf beiden Versionen getestet. Sollte eine Collection auf 26.04 fehlen, installiert `bootstrap.sh` sie automatisch aus `requirements.yml` nach.


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
| Sicherheitsstatus jetzt senden | `sudo ./bootstrap.sh --status` |

---

## Continuous Compliance (wöchentlicher Statusbericht)

Anvil installiert einen systemd-Timer **`anvil-status.timer`**, der wöchentlich einen
**Sicherheitsstatus** erzeugt und per **Gotify** meldet — ohne Login. Inhalt:
Lynis-Hardening-Index **+ Trend** (↑/↓/→), ausstehende Security-Updates, Drift (offene
Ports), fail2ban-Bans, fehlgeschlagene Dienste, Reboot-/Kernel-Fallback-Status, Zeitsync,
auditd-Status. Die Priorität eskaliert (info → warn → alert), sodass Probleme auffallen.

```bash
# Status sofort erzeugen (on demand):
sudo ./bootstrap.sh --status        # oder: sudo /usr/local/sbin/anvil-status-report

# Geplanten Lauf prüfen:
systemctl list-timers anvil-status.timer

# Voller Report + Verlauf:
ls /var/log/anvil/reports/status-*.txt
cat /var/lib/anvil/status-history          # datum,index,findings (Trend)
```

**Intervall ändern:** `ANVIL_COMPLIANCE_SCHEDULE` in `config/anvil.conf` (systemd-OnCalendar,
z.B. `daily` oder `Mon *-*-* 06:00:00`), dann `sudo ./bootstrap.sh apply`.
**Abschalten:** in `group_vars/all/main.yml` `compliance_schedule_enabled: false` →
nächster Lauf entfernt den Timer (das `--status`-Skript bleibt erhalten).

---

## Optionale, riskante Schalter

- `os_pam_faillock=true` — Account-Lockout über PAM. **Lockout-Risiko**: vorher
  Konsolenzugang sicherstellen.
- `enable_grub_password=true` — schützt den GRUB-Editor; bei Fehlkonfiguration
  Konsolen-Lockout möglich. `vault_grub_password` muss gesetzt sein.
- `os_blacklist_usb_storage=true` — sperrt USB-Massenspeicher (Vorsicht bei Bare-Metal).
