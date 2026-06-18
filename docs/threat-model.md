# Anvil — Bedrohungsmodell & Scope

## Ziel

Anvil bringt einen frischen Debian-/Ubuntu-Server in einen gehärteten, auditierbaren
Grundzustand für **kritische Infrastruktur**. Es ersetzt keine kontinuierliche
Sicherheitsorganisation, sondern schafft eine reproduzierbare Baseline.

## Annahmen

- Anvil läuft **lokal** auf dem Zielserver mit root-Rechten (Pull-Modell).
- Das Repo wird über einen **vertrauenswürdigen** Kanal bezogen (git über HTTPS/SSH).
- `config/anvil.conf` enthält nur **öffentliche** SSH-Keys; echte Geheimnisse liegen
  ausschließlich verschlüsselt in `group_vars/all/vault.yml` (ansible-vault).
- Es existiert ein **Out-of-Band-Zugang** (Provider-/Hypervisor-Konsole) für Notfälle.

## Adressierte Bedrohungen

| Bedrohung | Gegenmaßnahme |
|---|---|
| Brute-Force/Passwort-Angriffe auf SSH | Key-only-Auth, Root-Login aus, fail2ban, ufw `limit` |
| Privilege Escalation über schwache Accounts | sudo-Härtung, root gesperrt, Account-Hygiene, PAM |
| Persistenz über manipulierte Systemdateien | AIDE, auditd, restriktive Dateirechte |
| Unsichere Defaults im Kernel/Netzstack | sysctl-Härtung, Modul-Blacklist |
| Veraltete, verwundbare Pakete | unattended-upgrades (Security) |
| Verlust der Verfügbarkeit durch defektes Kernel-Update | Boot-Resilienz / Kernel-Fallback |
| Unbemerkte sicherheitsrelevante Ereignisse | Gotify-Alarme, persistentes Logging |
| Falsche Zeit → fehlerhafte Logs/Zertifikate | chrony, optional NTS |
| Fehlkonfiguration sperrt Admin aus | preflight-Checks, Config-Backup, `--rollback`, reload statt restart |

## Bewusst NICHT im Scope (v1)

- **Anwendungs-/Dienst-Härtung** (Webserver, Datenbanken, Container-Workloads).
- **Netzwerk-Perimeter** (externe Firewalls, IDS/IPS, Segmentierung).
- **Physische Sicherheit** und vollständiger Schutz bei Angreifer mit Konsolenzugang
  (GRUB-Passwort ist optional und kein vollständiger Evil-Maid-Schutz).
- **Secret-Management-Backend** (Vault-Server, HSM) — Anvil nutzt ansible-vault-Dateien.
- **Zentrales SIEM** — nur Log-Weiterleitung wird vorbereitet (Toggle).
- **Multi-Distro** — ausschließlich Debian/Ubuntu.
- **Manipulierte Lieferkette** des Anvil-Repos selbst (Integrität des Repos wird angenommen).

## Restrisiken

- Ohne Hardware-Watchdog ist die automatische Fallback-Reaktion auf reine Kernel-Hänger
  von der Provider-Konsole abhängig.
- `os_pam_faillock` und `enable_grub_password` bergen bei Fehlkonfiguration ein
  Lockout-Risiko und sind daher standardmäßig deaktiviert.
- Gotify-Benachrichtigungen sind nur so zuverlässig wie der Gotify-Server; bei
  längeren Ausfällen greift der lokale Spool/Retry.
