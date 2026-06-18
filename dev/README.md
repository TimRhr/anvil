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

```bash
dev/dev.sh list                  # Presets auflisten
dev/dev.sh vars crown            # aufgelöste Posture-/Toggle-Variablen anzeigen (safe)
dev/dev.sh lint                  # shellcheck + yamllint + ansible-lint + syntax-check
dev/dev.sh matrix                # lint + vars für ALLE Presets (schnelle Gesamtprüfung)
dev/dev.sh check crown           # lokaler Dry-Run (--check, KEINE Änderungen; sudo nötig)

# Voller Apply-Test nur in einer Wegwerf-VM (nie localhost):
dev/dev.sh vm-up anvil-dev 24.04
dev/dev.sh apply crown anvil-dev # Apply + automatischer Idempotenz-Check in der VM
dev/dev.sh vm-rm anvil-dev
```

## Presets (`dev/presets/`)

| Preset | Posture | Besonderheit |
|---|---|---|
| `baseline` | baseline | Standard-Härtung, alles default |
| `minimal` | baseline | schnell (AIDE/Lynis/Forensik/Updates aus) |
| `full` | baseline | alle Maßnahmen inkl. Forensik |
| `crown` | crown_jewels | MFA=auto (FIDO2; ohne sk-Key kein Enforce) |
| `crown-totp` | crown_jewels | TOTP via pam_oath (staged, kein Enforce) |
| `crown-egress` | crown_jewels | Egress-Firewall aktiv (deny outgoing) |

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
