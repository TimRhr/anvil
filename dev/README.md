# dev/ — Entwickler-Harness (TEMPORÄR)

> ⚠️ **Nicht für Produktion.** Der gesamte `dev/`-Ordner wird **vor** der
> Veröffentlichung in den prod-Branch entfernt:
> ```bash
> git rm -r --cached dev/ && rm -rf dev/   # vor dem prod-Merge
> ```
> `dev/` enthält Test-Presets mit **Dummy-SSH-Keys** und gehört nicht in ein
> Produktiv-Repo.

Zweck: verschiedene Settings-Kombinationen schnell durchtesten, **ohne**
`config/anvil.conf` ständig zu editieren. Presets sind Ansible-Extra-Vars-Dateien
(`dev/presets/*.yml`), die direkt an das Playbook übergeben werden.

## Benutzung

`dev.sh` wird **direkt auf dem Test-Host** ausgeführt. Sichere Befehle (verändern
nichts) gehen überall; `apply`/`vm-matrix`/`totp-test` **härten den lokalen Host**
und sind daher nur in einer **Wegwerf-VM** gedacht (Sicherheitsabfrage schützt davor).

### Sichere Befehle (auch auf dem Arbeitsrechner)

```bash
dev/dev.sh list                  # Presets auflisten
dev/dev.sh vars crown            # aufgelöste Posture-/Toggle-Variablen anzeigen
dev/dev.sh lint                  # shellcheck + yamllint + ansible-lint + syntax-check
dev/dev.sh matrix                # lint + vars für ALLE Presets
dev/dev.sh check crown           # lokaler Dry-Run (--check, KEINE Änderungen; sudo nötig)
```

### Verändernde Befehle — IN DER VM ausführen

Repo in die VM holen (z.B. `git clone` oder kopieren), dann **in der VM**:

```bash
cd /pfad/zu/anvil
dev/dev.sh apply crown           # dieses Preset auf DIESEM Host anwenden + Idempotenz-Check
dev/dev.sh vm-matrix             # ALLE unkritischen Presets nacheinander
dev/dev.sh totp-test             # End-to-End-TOTP-Test (pam_oath) via pamtester
```

Vor Änderungen fragt `dev.sh` nach dem **Hostnamen** (Schutz vor versehentlichem
Härten des Arbeitsrechners). Nicht-interaktiv erzwingen:

```bash
ANVIL_DEV_FORCE=1 dev/dev.sh vm-matrix
```

## Presets (`dev/presets/`)

| Preset | Posture | Besonderheit |
|---|---|---|
| `baseline` | baseline | Standard-Härtung, alles default |
| `minimal` | baseline | schnell (AIDE/Lynis/Forensik/Updates aus) |
| `full` | baseline | alle Maßnahmen inkl. Forensik |
| `crown` | crown_jewels | MFA=auto (FIDO2; ohne sk-Key kein Enforce) |
| `crown-totp` | crown_jewels | TOTP via pam_oath (staged, kein Enforce) |
| `crown-totp-enrolled` | crown_jewels | TOTP **enforced** — nur via `totp-test` nutzen (legt Test-Secret an) |
| `crown-egress` | crown_jewels | Egress-Firewall aktiv (deny outgoing) |

### End-to-End-TOTP-Test

`dev/dev.sh totp-test <vm>` legt ein deterministisches Test-Secret in
`/etc/users.oath` an, wendet `crown-totp-enrolled` an und prüft den PAM-Stack
**wirklich** durch: `pamtester sshd devadmin authenticate` mit einem von
`oathtool` erzeugten gültigen OTP (muss bestehen) und einem falschen OTP (muss
abgelehnt werden). Belegt, dass pam_oath + die common-auth-Deaktivierung
korrekt greifen — ohne echte SSH-Sitzung und ohne Lockout-Risiko.

Eigenes Szenario: eine Datei nach `dev/presets/<name>.yml` legen (Extra-Vars,
mind. `admin_user` + `admin_pubkeys` + `anvil_posture`).

## Sicherheit

- `apply` verlangt **immer** einen VM-Namen und läuft über multipass — niemals
  gegen den lokalen Host (kein versehentliches Härten des Arbeitsrechners).
- `check` läuft lokal nur im `--check`-Modus (keine Änderungen).
- `vars` und `lint` verändern nichts.
- Die Presets stellen Gotify still (`notify_enabled: false`) und nutzen
  Dummy-Keys; FIDO2/TOTP werden ohne echten Faktor **nicht** erzwungen.

## Hinweise

- `dev/.venv/` und `dev/.ansible-home/` werden von `dev.sh lint` automatisch
  angelegt (gitignored).
- Vor dem prod-Publish: `dev/` löschen (siehe oben).
