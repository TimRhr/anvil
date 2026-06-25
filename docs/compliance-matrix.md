# Compliance-Matrix — BSI IT-Grundschutz ↔ CIS ↔ Anvil

Diese Matrix ordnet die von Anvil umgesetzten Maßnahmen den Anforderungen aus
**BSI IT-Grundschutz (SYS.1.3 „Server unter Linux/Unix" u.a.)** und dem
**CIS Distribution Independent Linux Benchmark** zu. Sie ist eine Arbeitshilfe,
kein formales Zertifizierungsdokument.

| Bereich | Anvil-Umsetzung (Rolle/Tag) | BSI (Auswahl) | CIS (Auswahl) |
|---|---|---|---|
| Standard-User statt root | `base_user` | SYS.1.3.A1, ORP.4 | 5.4 |
| Root-Login (SSH) deaktiviert | `ssh_hardening` | SYS.1.3.A4 | 5.2.x |
| SSH nur mit Key, moderne Krypto | `ssh_hardening` | SYS.1.3.A4 | 5.2.x |
| Host-Firewall (ufw, default deny) | `firewall` | SYS.1.3.A3, NET.1 | 3.5 |
| Zeitsynchronisation (chrony/NTS) | `time_sync` | OPS.1.1.2, SYS.1.3 | 2.3 |
| Persistentes Logging / Retention | `logging` | OPS.1.1.5, DER.1 | 4.2 |
| Zentrale Log-Weiterleitung (opt.) | `logging` (remote) | OPS.1.1.5 | 4.2.3 |
| Kernel-/Netzwerk-sysctl-Härtung | `os_hardening:kernel` | SYS.1.3.A6 | 3.1–3.3 |
| Unsichere Kernel-Module sperren | `os_hardening:modules` | SYS.1.3.A6 | 1.1.1 |
| Mount-Optionen (nodev/nosuid/noexec) | `os_hardening:fs` | SYS.1.3 | 1.1.x |
| PAM Passwortqualität/History | `os_hardening:pam` | ORP.4.A8 | 5.4.1 |
| Account-Lockout (faillock, opt.) | `os_hardening:pam` | ORP.4 | 5.3 |
| login.defs / Passwort-Aging | `os_hardening:logindefs` | ORP.4.A9 | 5.5.1 |
| Kritische Dateirechte | `os_hardening:perms` | SYS.1.3 | 6.1 |
| Core-Dumps unterbinden | `os_hardening:limits` | SYS.1.3 | 1.5.1 |
| Shell-Timeout (TMOUT) | `os_hardening:shell` | SYS.1.3 | 5.5.4 |
| AppArmor (MAC) | `os_hardening:apparmor` | SYS.1.3.A6 | 1.6 |
| auditd (Audit-Logging) | `os_hardening:auditd` | OPS.1.1.5, DER.1 | 4.1 |
| Dateiintegrität (AIDE) | `os_hardening:aide` | SYS.1.3.A9, DER.1 | 1.4 |
| Brute-Force-Schutz (fail2ban) | `os_hardening:fail2ban` | DER.1 | — |
| Automatische Sicherheitsupdates | `os_hardening:updates` | OPS.1.1.3, SYS.1.3.A2 | 1.8 |
| Bootloader-Passwort (opt.) | `os_hardening:bootloader` | SYS.1.3.A5 | 1.7 |
| Warn-Banner | `os_hardening:banner` | — | 1.9 |
| Cron-Zugriffskontrolle | `os_hardening:cron` | SYS.1.3 | 5.1 |
| Boot-Resilienz / Kernel-Fallback | `kernel_resilience` | SYS.1.3.A2, NotfallM. | — |
| Sicherheits-Audit (Lynis) | `audit` | DER.3 | — |
| Benachrichtigung (ntfy) | `notify` | DER.1, OPS.1.1.5 | — |
| Config-Backup/Rollback | `preflight` + `bootstrap --rollback` | CON.3, OPS.1.1.4 | — |

> Lücken-/Reifegrad: Mit Lynis (`audit`-Rolle) wird nach jedem Lauf ein
> Hardening-Index erhoben. Offene Punkte aus dem Lynis-Report sollten im
> Betrieb nachgezogen werden (siehe `docs/runbook.md`).
