# 🗺️ Anvil — Roadmap

Ziel: Aus Anvil heraus **Ubuntu 24.04 und 26.04** Server von Grund auf aufsetzen
und **automatisch härten** — der Server ist der **Host der Kronjuwelen**, die Mauern
auf Höchststand. Später kommen Dienste/Tools auf den Server, die ebenfalls
abgesichert werden; Anvil muss **erneut laufen** können, um die Härtung zu
erneuern und an die neue Umgebung **anzupassen**.

Leitprinzipien: *Sicher per Default · Verfügbarkeit bewahren (Aussperr-/Boot-Schutz)
· Idempotent & wiederholbar · Alles auditierbar.* Verweise wie **(SC-1)** zeigen auf
[docs/security-audit.md](docs/security-audit.md).

Legende: ☐ offen · ◐ teilweise · ☑ erledigt.

---

## Phase 0 — Baseline (Status quo) ☑

Vorhanden: Pull-Bootstrap, preflight/Aussperr-Schutz + Rollback, base_user,
ssh_hardening, firewall (ufw), time_sync (chrony/NTS), logging (journald/Retention),
os_hardening (sysctl/Module/FS/PAM/accounts/perms/limits/shell/AppArmor/auditd/AIDE/
fail2ban/updates/bootloader/banner/cron), **kernel_resilience** (Fallback),
notify (Gotify), audit (Lynis). Lint sauber, idempotent.

---

## Phase 1 — Verifizierte Provisionierung 24.04 & 26.04 ◐

**Ziel:** reproduzierbarer Weg von der nackten VM zum gehärteten Host auf **beiden**
Ubuntu-Versionen, getestet.

- ☑ **Erstkontakt/Entry**: git clone + `bootstrap.sh apply` — dokumentiert in [docs/runbook.md](docs/runbook.md) (multipass-Sektion). Kein One-Line-Installer (→ Phase 4).
- ☑ **OS-Matrix absichern**: Provisioning auf 24.04 **und** 26.04 durchgespielt; bekannte 26.04-Spezifika in [docs/runbook.md](docs/runbook.md#distributionsspezifika-ubuntu-2604) dokumentiert (sudo-rs, ggf. uutils-coreutils, entfernte community.general-Plugins).
- ☑ **Idempotenz-Gate**: [`tests/provision-check.sh`](tests/provision-check.sh) prüft `changed=0` im zweiten Lauf. Auf 24.04 und 26.04 ausführbar.
- ☑ **Kernel-Fallback-Abnahme**: [`tests/fallback-check.sh`](tests/fallback-check.sh) testet Fallback-/Erfolgs-/Normalpfad non-destruktiv. Manueller Reboot-Test in [docs/runbook.md](docs/runbook.md#echter-kernel-fallback-test-manuell).
- ☑ **Provisioning-Runbook**: multipass-Kurzanleitung in [docs/runbook.md](docs/runbook.md#provisionierung-mit-multipass-2404--2604). Provider-spezifische Runbooks (Hetzner/Proxmox) folgen später.

**Akzeptanz:** je eine 24.04- und 26.04-VM gehen mit einem Befehl von „frisch" zu
„gehärtet, idempotent, Fallback getestet".

---

## Phase 2 — „Kronjuwelen"-Höchsthärtung ☐

**Ziel:** maximale Mauern für den zentralen Host. Umgesetzt als **Posture-Schalter**
`anvil_posture: baseline | crown_jewels` (in `group_vars/all/main.yml`), der strengere
Defaults aktiviert — ohne den Aussperr-/Verfügbarkeitsschutz zu opfern.

- ☐ **MFA für SSH (AU-1)**: neue Rolle/Tasks für `sk-ssh-ed25519` (FIDO2) bzw.
  `publickey,keyboard-interactive` + TOTP (`libpam-google-authenticator`);
  `Match Address` zur Beschränkung auf Bastion/Management-Netz.
- ☐ **Egress-Firewall (NW-1)**: `firewall_default_outgoing: deny` + Allowlist-Variable
  (`firewall_egress_allow`: DNS, NTP, Paketspiegel, Gotify). Erweiterung von
  [roles/firewall](roles/firewall/tasks/main.yml); ggf. nftables-Backend.
- ☐ **Immutable Remote-Logging by default (DT-1)**: rsyslog→SIEM + auditd-Remote-Plugin
  in der `crown_jewels`-Posture standardmäßig an; append-only/WORM-Hinweise.
- ☐ **Strikte auditd-Posture (AV-1)**: `auditd_*_action` in `crown_jewels` auf
  `halt`/`single`; Immutable-Rules (`-e 2`) an.
- ☐ **Privileg (PR-2)**: passwort-/hardware-rückgesichertes sudo, NOPASSWD nur explizit.
- ☐ **Kernel/Geräte (MI-3)**: `lockdown=confidentiality` (LSM), `usb-storage`-Blacklist an,
  AppArmor gezielt `enforce` für exponierte Profile, `kernel.modules_disabled` nach Boot.
- ☐ **At-Rest/Boot (BO-1)**: LUKS-Empfehlung fürs Provisioning (nicht nachrüstbar) +
  Secure-Boot/TPM-Measured-Boot-Doku; GRUB-Passwort für Bare-Metal empfehlen.
- ☐ **Angriffsfläche**: Dienste-Minimierung (laufende Sockets scannen, Unnötiges maskieren),
  `systemd`-Sandboxing für verbleibende Dienste.

**Akzeptanz:** `anvil_posture=crown_jewels` hebt Lynis-Index messbar an, Egress ist
default-deny, MFA erzwungen, Logs landen extern — Aussperr-/Fallback-Schutz bleibt intakt.

---

## Phase 3 — Schichten- & App-Modell (Wiederholbarkeit) ☐  ⭐ Kernanliegen

**Ziel:** Wenn später Tools/Dienste auf den Server kommen, läuft Anvil **erneut** und
**erweitert** die Härtung passend zur neuen Umgebung — additiv, idempotent, ohne die
Baseline zu brechen.

- ☐ **Overlay-Architektur**: Basis-Härtung bleibt; **Dienst-Overlays** als Rollen
  `profiles/<name>` (z.B. `webserver`, `database`, `reverse_proxy`, `container_host`).
  In `config/anvil.conf` deklarierbar: `ANVIL_PROFILES=(webserver database)`.
- ☐ **Pro Overlay einheitlich**: nur benötigte Firewall-Ports öffnen (Egress/Ingress),
  **dediziertes AppArmor-Profil**, **systemd-Sandboxing** (NoNewPrivileges, ProtectSystem,
  PrivateTmp, CapabilityBoundingSet …), eigener Service-User, Datei-/Secret-Rechte,
  dienstspezifische auditd-Regeln.
- ☐ **Diff-/Drift-bewusst**: erneuter Lauf erkennt neue offene Ports/Dienste
  (`ss -tlnp`) und **meldet ungehärtete Dienste** via Gotify (Lücke zwischen Ist und Profilen).
- ☐ **Container/Workloads**: Overlay für Docker/Podman (rootless bevorzugt, Daemon-Härtung,
  Netzwerk-Policy), Hinweis auf seccomp/AppArmor je Container.
- ☐ **Re-Run-Sicherheit**: Overlays sind rein additiv und idempotent; `--tags profile:<name>`
  zum gezielten (Neu-)Anwenden; Baseline-Rollen bleiben unverändert wiederholbar.
- ☐ **Rollback-Vervollständigung (RB-1)**: alle betroffenen Dienste nach Rollback reaktivieren.

**Akzeptanz:** Nach Installation eines neuen Dienstes hebt `sudo ./bootstrap.sh apply`
(mit aktivem Profil) genau dessen Absicherung an — Ports minimal, AppArmor/Sandbox aktiv,
Audit erweitert — und meldet etwaige nicht abgedeckte Dienste.

---

## Phase 4 — Supply-Chain & Secrets ☐

**Ziel:** Vertrauen in den Pull-Pfad und Secrets-at-Rest härten (adressiert SC-1, SE-1, PR-1).

- ☐ **Signierte Stände (SC-1)**: `anvil-pull-run` verifiziert Commit-/Tag-Signatur
  (`git verify-commit`, allowed_signers) und nagelt auf getaggten Stand statt `HEAD` fest;
  **Read-only Deploy-Key**, Branch-Protection, optional manuelle Freigabe vor Apply.
- ☐ **Strikter Config-Parser (PR-1)**: `config/anvil.conf` nicht mehr `source`n, sondern
  whitelist-basiert parsen; Eigentum/Rechte (root:root 0640) erzwingen & prüfen.
- ☐ **Secrets-at-Rest (SE-1)**: Laufzeit-Abruf statt persistentem `.vault_pass` —
  Option A `sops`+age mit TPM-/`systemd-creds`-gebundenem Schlüssel, Option B externer
  Vault-Server; Secrets auf dem Host minimieren, Rotation dokumentieren.
- ☐ **Heartbeat/Alert-Integrität (MI-1)**: Gotify-Token rotierbar, Heartbeat-Alarm,
  optional mTLS/Pinning.

**Akzeptanz:** Ein manipulierter Repo-Stand wird vom Timer **abgelehnt**; ein
Host-Compromise gibt nicht automatisch alle Secrets preis.

---

## Phase 5 — Observability & Continuous Compliance ☐

**Ziel:** belegbarer, fortlaufender Sicherheitszustand.

- ☐ **OpenSCAP/CIS-Scan** als optionale Erweiterung der `audit`-Rolle (HTML/XML-Report).
- ☐ **Geplante Prüfungen**: systemd-Timer für periodischen Lynis/OpenSCAP-Lauf + Gotify-Summary
  (Hardening-Index-Trend).
- ☐ **Zentrales Logging/SIEM** als empfohlener Default der Kronjuwelen-Posture (siehe DT-1).
- ☐ **Evidence/Reporting**: maschinenlesbare Reports unter `/var/log/anvil/reports/`,
  Mapping gegen [docs/compliance-matrix.md](docs/compliance-matrix.md).

**Akzeptanz:** Nach jedem Lauf liegt ein datierter Compliance-Report vor; Trend ist sichtbar.

---

## Phase 6 — Test- & Release-Engineering ☐

**Ziel:** Vertrauen in jede Änderung.

- ☐ **Molecule-Matrix** auf Ubuntu 24.04 **und** 26.04 (+ Debian 12) — Converge, **Idempotenz** (`changed=0`), Self-Tests.
- ☐ **Kernel-Fallback-Integrationstest** (defekter One-shot → Fallback) in einer VM-Pipeline.
- ☐ **CI-Reaktivierung**: `.github/workflows/lint.yml` mit `workflow`-Scope/SSH wieder ins Remote
  (aktuell lokal gitignored); Matrix-Jobs ergänzen.
- ☐ **Releases**: getaggte, **signierte** Versionen + `CHANGELOG.md`; der Pull-Timer (Phase 4)
  konsumiert nur getaggte Stände.

**Akzeptanz:** Grüne CI auf beiden Ubuntu-Versionen ist Pflicht-Gate für jeden Release-Tag.

---

## Priorisierung (Vorschlag)

1. **Phase 1** (Provisionierung 24.04/26.04 verifizieren) — Fundament.
2. **Phase 3** (Schichten-/App-Modell) — direkt der Nutzer-Wunsch „erneut laufen & anpassen".
3. **Phase 2** (Kronjuwelen-Posture) — Höchsthärtung.
4. **Phase 4** (Supply-Chain/Secrets) — kritisch, sobald der Pull-Timer produktiv läuft.
5. **Phase 5 + 6** parallel begleitend (Compliance-Nachweis & Test-Gates).
