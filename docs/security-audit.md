# Anvil — Sicherheitsaudit (v1 Baseline)

Stand: 2026-06-18. Betrachtet wird der aktuelle Code (Pull-Modell, Debian/Ubuntu).
Perspektiven: **Supply Chain**, **Angreifer/Red Team**, **Operator/Blue Team**,
**Secrets**, **Verfügbarkeit**, **Compliance/Detektion**. Schweregrad: 🔴 hoch ·
🟠 mittel · 🟡 niedrig. Die IDs werden in der [ROADMAP.md](../ROADMAP.md) referenziert.

> Grundbefund: Die Baseline ist solide (key-only SSH, root aus, ufw default-deny
> incoming, sysctl/PAM/auditd/AIDE/fail2ban, Kernel-Fallback, Aussperr-Schutz,
> Lint sauber). Die folgenden Punkte sind das, was für einen **Kronjuwelen-Host**
> noch fehlt bzw. bewusst abgewogen wurde.

## 🔴 Hoch

| ID | Perspektive | Befund | Empfehlung |
|----|-------------|--------|------------|
| **SC-1** | Supply Chain | Der Continuous-Enforcement-Timer führt als root `git reset --hard origin/<branch>` + `bootstrap.sh apply` aus ([systemd/anvil-pull-run](../systemd/anvil-pull-run)). Wer das Repo kontrolliert (Kompromittierung, MITM des Fetch, geleakte Push-Credentials), erhält **root auf allen Servern**. Keine Commit-Signaturprüfung, kein gepinnter Stand. | **Als Restrisiko akzeptiert** (Single-Admin-/KMU-Betrieb, vertrauenswürdiges Repo — siehe [ROADMAP.md](../ROADMAP.md) Phase 4). Mitigation falls nötig: getaggten Stand pinnen, Read-only Deploy-Key, `git verify-commit`. |
| **SE-1** | Secrets | Pull-Modell-Schwäche: `.vault_pass` liegt **auf dem Host**, dessen Secrets es schützt. Eine Host-Kompromittierung gibt alle Vault-Secrets frei (das Vault-Passwort liegt daneben). | Secrets auf dem Host minimieren; Laufzeit-Abruf aus externem Store (SOPS-age mit TPM-/`systemd-creds`-geschütztem Schlüssel, oder Vault-Server). `.vault_pass` nicht persistent ablegen. → Phase 4 |
| **NW-1** | Netzwerk/Angreifer | Egress ist `allow` ([group_vars/all/main.yml](../group_vars/all/main.yml): `firewall_default_outgoing: allow`). Für Kronjuwelen ermöglicht das **Daten-Exfiltration und C2** ungehindert. | `default deny outgoing` + Allowlist (DNS, NTP, Paketspiegel, ntfy, ggf. Update-Proxy). → Phase 2 |
| **DT-1** | Detektion | Logs liegen nur **lokal** (Remote-Syslog ist Toggle, default aus). Ein Angreifer mit root kann auditd-/journald-Logs manipulieren/löschen. | Immutable **Remote-Logging by default** für diese Posture (rsyslog→SIEM, auditd-Remote-Plugin), möglichst WORM/append-only. → Phase 2/5 |
| **AU-1** | Auth | SSH ist key-only (gut), aber **einfaktoriell** (Besitz des Keys). Für Kronjuwelen fehlt ein zweiter Faktor. | FIDO2-Hardwarekeys (`sk-ssh-ed25519`) erzwingen oder `publickey,keyboard-interactive` mit TOTP; Zugang nur von Bastion (`Match Address`). → Phase 2 |

## 🟠 Mittel

| ID | Perspektive | Befund | Empfehlung |
|----|-------------|--------|------------|
| **PR-1** | Privileg | `load_config` **sourct** `config/anvil.conf` als root ([lib/common.sh](../lib/common.sh)). Der Guard blockt nur `$(`, Backticks, `eval`, `rm -rf` — eine Blockliste, kein Sandbox. Wer die Datei schreiben kann, bekommt root. | Strikter `key=value`-Parser statt `source`; Eigentum/Rechte (root:root 0640) erzwingen und prüfen. → Phase 4 |
| **PR-2** | Privileg | sudo fällt auf **NOPASSWD** zurück, wenn kein `admin_password_hash` gesetzt ist ([roles/base_user](../roles/base_user/tasks/main.yml)). Ein gestohlener SSH-Key ⇒ sofort root. | Für Kronjuwelen passwort- oder hardware-rückgesichertes sudo bevorzugen; NOPASSWD bewusst dokumentieren/abschaltbar. → Phase 2 |
| **AV-1** | Verfügbarkeit/Compliance | auditd-Aktionen sind `syslog` statt `halt`/`single` ([defaults](../roles/os_hardening/defaults/main.yml)) — bewusst verfügbarkeitsfreundlich, aber **unter strikter CIS L2** soll bei Audit-Ausfall keine ungeprüfte Aktivität laufen. | Posture-Schalter „availability" vs. „strict" (strict = `halt`), pro Umgebung wählbar. → Phase 2 |
| **RB-1** | Operator | `--rollback` stellt Dateien wieder her und lädt nur sshd+sysctl neu ([bootstrap.sh](../bootstrap.sh)); auditd/ufw/fail2ban/chrony/journald werden nicht neu gestartet. Backups liegen nur lokal. | Vollständige Service-Reaktivierung im Rollback; Konfig-Backups zusätzlich remote sichern. → Phase 3 |
| **AP-1** | Architektur | Monolithische Baseline ohne **App-Bewusstsein**: später installierte Dienste (Webserver, DB, Container) öffnen Ports, legen Nutzer an, brauchen AppArmor-Profile/systemd-Sandboxing/Firewall-Regeln. Anvil v1 deckt das nicht ab. | Schichten-/Overlay-Modell mit dienstspezifischen Profilen, erneut anwendbar. → Phase 3 (Kernanliegen des Nutzers) |
| **BO-1** | Boot/At-Rest | Keine Festplattenverschlüsselung (LUKS) und kein Secure/Measured Boot adressiert; GRUB-Passwort optional/aus. | LUKS bei Provisioning (nicht nachrüstbar) als Doku/Empfehlung; Secure-Boot-/TPM-Hinweise; GRUB-PW für Bare-Metal empfehlen. → Phase 2 |

## 🟡 Niedrig / Hygiene

| ID | Perspektive | Befund | Empfehlung |
|----|-------------|--------|------------|
| **MI-1** | Detektion | ntfy über HTTPS, aber ohne Cert-Pinning; bei Token-Leak Alerts spoofbar/unterdrückbar. | Token rotierbar halten; optional Pinning/mTLS; Heartbeat-Alarm zur Ausfallerkennung. |
| **MI-2** | Qualität | Nur Molecule-Gerüst, keine automatisierten Integrationstests auf echtem 24.04/26.04. | CI-Matrix + Molecule auf beiden Versionen, Idempotenz-/Fallback-Tests. → Phase 6 |
| **MI-3** | Härtung | Kein Kernel-`lockdown`-LSM, kein USB-Lockdown by default, AppArmor nur „enabled" (nicht flächig „enforce"). | Für Kronjuwelen: lockdown=confidentiality, usb-storage-Blacklist an, gezielt enforce. → Phase 2 |

## Positiv hervorzuheben

- Aussperr-Schutz mehrschichtig (preflight-Asserts, sshd `validate`, `reload` statt `restart`, Self-Test, Config-Backup/Rollback).
- Kernel-Fallback (One-shot + Boot-Assessment + panic/Watchdog) — adressiert Verfügbarkeit nach Updates.
- Sauberes Toggle-/Tag-System, vollständig lint-clean (shellcheck/yamllint/ansible-lint), idempotent.
- Secrets-Trennung (öffentliche Keys in `anvil.conf`, echte Geheimnisse in ansible-vault), `.vault_pass`/`vault.yml` korrekt in `.gitignore`-Logik.
