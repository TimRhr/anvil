# ⚒️ Anvil — Server-Bootstrap & Hardening (Pull-Modell)

Anvil bringt einen frischen **Debian-/Ubuntu-Server** mit einem einzigen Befehl in einen
gehärteten Grundzustand — geeignet für **kritische Infrastruktur**. Das Tool kommt per
`git clone` auf den Server und richtet ihn **lokal** ein (Pull-Modell): ein dünnes Bash-Skript
installiert Ansible und führt die Härtung gegen `localhost` aus.

> Maßnahmen orientieren sich an **BSI IT-Grundschutz SYS.1.3** und **CIS Benchmark (Level 1/2)** —
> siehe [docs/compliance-matrix.md](docs/compliance-matrix.md).

---

## Was Anvil macht

| Bereich | Maßnahme |
|---|---|
| **Standard-User** | Legt einen Admin-User mit SSH-Key-Login und sudo an (Root-Passwort wird gesperrt). |
| **SSH** | Root-Login & Passwort-Auth aus, moderne Krypto, `AllowGroups ssh-users`, Banner. |
| **Firewall** | ufw: default deny incoming, SSH rate-limited (`limit`), loopback, IPv6. |
| **Zeit** | chrony mit mehreren Quellen, optional NTS (authentifizierte Zeit), Sync-Monitoring. |
| **Logging** | journald persistent, logrotate, auditd-Retention, optional Remote-Syslog. |
| **OS-Hardening** | sysctl, Kernel-Module, Mount-Optionen, PAM, Account-/Dateirechte, AppArmor, auditd, AIDE, fail2ban, unattended-upgrades. |
| **Boot-Resilienz** | Defektes Kernel-Update → automatischer Fallback auf den letzten funktionierenden Kernel + Gotify-Alarm. |
| **Benachrichtigung** | **Gotify** (HTTP-Push) für AIDE, fail2ban, Updates, Kernel-Fallback und Anvil-Läufe. |
| **Audit** | Lynis-Report + Compliance-Zusammenfassung. |

---

## Schnellstart

```bash
# 1. Auf dem frischen Server (als root oder via sudo-fähigem Cloud-User):
git clone <repo-url> /opt/anvil
cd /opt/anvil

# 2. Konfiguration anlegen (Admin-User + eigene SSH-Public-Keys):
cp config/anvil.conf.example config/anvil.conf
$EDITOR config/anvil.conf

# 3. Secrets (Gotify-URL/Token, optional GRUB-Passwort) in den Vault:
cp group_vars/all/vault.example.yml group_vars/all/vault.yml
ansible-vault encrypt group_vars/all/vault.yml      # Passwort vergeben
#  -> Passwort optional in ./.vault_pass ablegen (chmod 600), wird automatisch genutzt

# 4. Dry-Run (zeigt alle Änderungen, ändert nichts):
sudo ./bootstrap.sh --check

# 5. Härtung anwenden:
sudo ./bootstrap.sh apply
```

Nach dem Lauf:
- Login als Admin: `ssh -i <dein-key> -p <port> <admin-user>@<server>`
- `ssh root@<server>` und Passwort-Logins werden **abgelehnt**.
- Config-Backups liegen unter `/var/backups/anvil/<timestamp>/`.

> ⚠️ **Aussperr-Schutz:** Anvil legt den Admin-User samt deinen SSH-Keys an, **bevor** Root-/
> Passwort-Login deaktiviert wird, validiert `sshd` und macht nur ein `reload` (kein `restart`).
> Trotzdem: **vor dem ersten produktiven Lauf in einer Wegwerf-VM testen** und eine zweite
> SSH-Sitzung offen halten.

---

## Verwendung

```bash
sudo ./bootstrap.sh apply                 # vollständige Härtung (Default)
sudo ./bootstrap.sh --check               # Dry-Run (--check --diff)
sudo ./bootstrap.sh --tags ssh,firewall   # nur bestimmte Bereiche
sudo ./bootstrap.sh --only time_sync      # nur eine Rolle
sudo ./bootstrap.sh --rollback            # letztes Config-Backup wiederherstellen
sudo ./bootstrap.sh --reboot-if-needed    # nach Kernel-Update sicher rebooten
sudo ./bootstrap.sh --enable-timer        # Continuous Enforcement (ansible-pull) aktivieren
sudo ./bootstrap.sh --help
```

Feature-Toggles stehen in [group_vars/all/main.yml](group_vars/all/main.yml) und können in
`config/anvil.conf` übersteuert werden.

---

## Voraussetzungen

- Debian 11/12 oder Ubuntu 20.04/22.04/24.04
- root- bzw. sudo-Zugang
- Netzwerkzugang für die **einmalige** Ansible-Installation (danach läuft alles lokal/offline)
- Erreichbarer Gotify-Server für Benachrichtigungen (optional, aber empfohlen)

---

## Dokumentation

- [docs/runbook.md](docs/runbook.md) — Betrieb, Recovery, Aussperr-Wiederherstellung, Kernel-Fallback
- [docs/compliance-matrix.md](docs/compliance-matrix.md) — BSI ↔ CIS ↔ Anvil-Maßnahmen
- [docs/threat-model.md](docs/threat-model.md) — Annahmen, Scope, bewusste Grenzen

---

## Sicherheitshinweise

```
⚠️  group_vars/all/vault.yml  → nur verschlüsselt committen (ansible-vault)
⚠️  .vault_pass               → NIEMALS committen (.gitignore vorhanden)
⚠️  config/anvil.conf         → enthält nur PUBLIC Keys; Secrets gehören in den Vault
```
