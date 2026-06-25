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
notify (ntfy), audit (Lynis). Lint sauber, idempotent.

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

## Phase 2 — „Kronjuwelen"-Höchsthärtung ☑

**Ziel:** maximale Mauern für den zentralen Host. Umgesetzt als **Posture-Schalter**
`anvil_posture: baseline | crown_jewels` (in `group_vars/all/main.yml`), der strengere
Defaults aktiviert — ohne den Aussperr-/Verfügbarkeitsschutz zu opfern.

- ☑ **Posture-Schalter (A)**: `config/anvil.conf` → `bootstrap.sh` → `group_vars/all/main.yml` →
  `roles/preflight`. `anvil_crown_jewels`-Bool für conditionals. Posture-Validierung in preflight.
- ☑ **SSH-MFA (AU-1, B)**: [`roles/ssh_hardening/tasks/mfa.yml`](roles/ssh_hardening/tasks/mfa.yml) —
  FIDO2 (`sk-ssh-ed25519`) und TOTP (`pam_oath` / OATH Toolkit, FOSS), lockout-sicher
  (Preflight prüft Keys/Enrollment vor Enforce). `ssh_allowed_cidrs` für
  Management-Netz-Beschränkung.
- ☑ **Egress-Firewall (NW-1, C)**: [`roles/firewall/tasks/main.yml`](roles/firewall/tasks/main.yml) —
  Allowlist-Variable mit DNS/NTP/HTTP/HTTPS, Remote-Syslog. **Default `allow`** (auch im
  crown-Modus); Schutz erst nach `firewall_egress_enforce=true`.
- ◐ **Immutable Remote-Logging (DT-1)**: `enable_remote_syslog` bleibt Toggle (optional,
  nicht erzwungen). Remote-Logging-Empfehlung in [`docs/crown-jewels.md`](docs/crown-jewels.md).
- ☑ **auditd-Posture (AV-1, D)**: `enable_auditd_immutable` wird im crown-Modus auf `true`
  gesetzt (Regel-Manipulationsschutz `-e 2`). Aktionen bleiben `syslog` (verfügbarkeits-
  freundlich, siehe [`docs/crown-jewels.md`](docs/crown-jewels.md) für Umstellung auf `halt`/`single`).
- ☑ **Privileg (PR-2, E)**: Preflight-Check im crown-Modus — assertiert entweder
  `admin_sudo_nopasswd: true` ODER `admin_password_hash` im Vault.
- ☑ **Kernel/Geräte (MI-3, F)**: AppArmor `enforce` für alle Profile (`apparmor_enforce_all`),
  `kernel_lockdown=confidentiality` via GRUB-Cmdline-Drop-in,
  `os_blacklist_usb_storage` aktiviert, `kernel_disable_module_loading` als OPT-IN
  (default false, auch im crown-Modus).
- ☑ **At-Rest/Boot (BO-1, G)**: LUKS/Secure-Boot/TPM-Empfehlungen in
  [`docs/crown-jewels.md`](docs/crown-jewels.md). GRUB-Passwort weiterhin opt-in.
- ☑ **Angriffsfläche (H)**: [`roles/os_hardening/tasks/attack_surface.yml`](roles/os_hardening/tasks/attack_surface.yml) —
  `ss -tulpn` + aktive systemd-Units scannen, Report nach `/var/log/anvil/reports/`,
  ntfy-Benachrichtigung. Optionales Maskieren via `os_mask_services`. Sandboxing → Phase 3.
- ☑ **Doku (I)**: [`docs/crown-jewels.md`](docs/crown-jewels.md) — Posture-Übersicht,
  Maßnahmen-Doku, MFA-Enrollment, Egress-Aktivierung, Umschalt-Hinweise, Restrisiken.

**Akzeptanz:** `anvil_posture=crown_jewels` aktiviert reproduzierbar die Höchsthärtung
(AppArmor enforce, USB aus, auditd immutable, MFA gemäß Methode, Egress vorbereitet,
Lockdown nach Reboot) — Aussperr-/Fallback-Schutz bleibt intakt, Verfügbarkeit gewahrt.

---

## Phase 3 — Schichten- & App-Modell (Wiederholbarkeit) ◐  ⭐ Kernanliegen

**Ziel:** Wenn später Tools/Dienste auf den Server kommen, läuft Anvil **erneut** und
**erweitert** die Härtung passend zur neuen Umgebung — additiv, idempotent, ohne die
Baseline zu brechen. Umgesetzt **datengetrieben**: deklarative `profiles/<name>.yml` +
generischer Motor [`roles/profiles`](roles/profiles). Doku: [docs/profiles.md](docs/profiles.md).

- ☑ **Overlay-Architektur**: Baseline bleibt; Auswahl via `ANVIL_PROFILES=(...)`. Erste
  Profile: [`reverse_proxy`](profiles/reverse_proxy.yml), [`container_host`](profiles/container_host.yml).
- ☑ **Pro Overlay einheitlich**: Firewall-Ingress/Egress, AppArmor-Enforce, systemd-Sandbox-
  Drop-in (NoNewPrivileges/ProtectSystem/…), Datei-/Secret-Rechte, dienstspezifische auditd-Regeln.
- ☑ **Diff-/Drift-bewusst**: jeder Lauf vergleicht `ss -tlnH` mit erwarteten Ports (SSH +
  Extra + Profile) und meldet ungedeckte Dienste via ntfy + Report (**nur Meldung**).
- ☑ **Container/Workloads**: `container_host` — daemon.json-Härtung (Merge), DOCKER-USER/ufw-
  Integration (opt-in, da Docker ufw umgeht), Podman-rootless als Empfehlung; dockerd kein Auto-Restart.
- ☑ **Re-Run-Sicherheit**: additiv/idempotent; `--tags profiles`; abgewählte Profile werden
  zurückgebaut (`remove_profile`); Baseline unverändert wiederholbar.
- ☑ **Rollback-Vervollständigung (RB-1)**: `--rollback` macht daemon-reload + reaktiviert
  betroffene Dienste (ufw/fail2ban/chrony/journald/auditd/sshd).
- ☐ **VM-Abnahme**: End-to-End in einer VM (Docker+Container, Caddy) — via `dev/dev.sh apply crown-profiles`.

**Akzeptanz:** Nach Installation eines neuen Dienstes hebt `sudo ./bootstrap.sh apply`
(mit aktivem Profil) genau dessen Absicherung an — Ports minimal, AppArmor/Sandbox aktiv,
Audit erweitert — und meldet etwaige nicht abgedeckte Dienste.

---

## Phase 4 — Continuous Compliance ◐

**Ziel:** belegbarer Sicherheitszustand mit minimalem Aufwand — ohne SIEM/SCAP-Infrastruktur.
Umgesetzt als Rolle [`roles/compliance`](roles/compliance): Status-Skript + wöchentlicher
systemd-Timer. Doku: [docs/runbook.md](docs/runbook.md#continuous-compliance-wöchentlicher-statusbericht).

- ☑ **Geplanter Selbst-Audit**: `anvil-status.timer` (Default `Sun *-*-* 04:00`, via
  `ANVIL_COMPLIANCE_SCHEDULE` änderbar) ruft [`anvil-status-report`](roles/compliance/files/anvil-status-report)
  auf → Lynis-Index **+ Trend** (↑/↓/→) aus `/var/lib/anvil/status-history`.
- ☑ **Voller ntfy-Statusbericht**: Lynis-Index/Trend + Security-Updates + Drift (offene
  Ports) + fail2ban-Bans + failed services + Reboot-/Kernel-Fallback-Status + Zeitsync +
  auditd; **Priorität eskaliert** (info→warn→alert). On-demand via `bootstrap.sh --status`.
- ☐ **OpenSCAP/CIS-Scan (optional)**: nur bei Bedarf als Zusatz zur `audit`-Rolle (HTML-Report).
- ☐ **VM-Abnahme**: Timer + Push in einer VM bestätigen (`dev/dev.sh apply` → `--status`).

Zentrales SIEM bleibt ein **Toggle** (`enable_remote_syslog`), kein Default.

**Akzeptanz:** Ein wiederkehrender Lauf liefert einen datierten Report + ntfy-Trend; manuelle
Auswertung genügt.

---
