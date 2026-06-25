# Anvil — App-Overlays / Profile (Phase 3)

Wenn nach der Baseline-Härtung **Dienste/Tools** auf den Server kommen, ergänzt
Anvil deren Absicherung über **Profile** — additiv, idempotent und rückbaubar.
Anvil **installiert keine Apps**; es härtet vorhandene Dienste.

## Aktivieren

In `config/anvil.conf`:
```bash
ANVIL_PROFILES=(reverse_proxy container_host)
```
Danach `sudo ./bootstrap.sh apply` (oder gezielt `--tags profiles`). Ein erneuter
Lauf wendet die Profile additiv an; ein **entfernter** Eintrag wird beim nächsten
Lauf wieder **zurückgebaut** (Drop-in/Audit/Ingress entfernt).

## Was ein Profil härtet (einheitliches Muster)

| Bereich | Wirkung |
|---|---|
| **Firewall-Ingress/Egress** | nur die benötigten Ports per ufw |
| **systemd-Sandbox** | Drop-in `…/<unit>.service.d/anvil-sandbox.conf` (NoNewPrivileges, ProtectSystem=strict, PrivateTmp, CapabilityBoundingSet …) |
| **AppArmor** | vorhandene Profile in den enforce-Modus |
| **Dateirechte** | restriktive Owner/Mode auf Config-/Daten-/Secret-Pfade |
| **auditd** | dienstspezifische Watches (`/etc/audit/rules.d/anvil-profile-<name>.rules`) |

**Restart-Politik:** Ändert sich das Sandbox-Drop-in, wird der Dienst neu gestartet
(Sandbox sofort aktiv). Ausnahme `container_host`: **dockerd wird nicht** automatisch
neugestartet (würde Container stoppen) → ntfy meldet „Restart nötig".

## Mitgelieferte Profile

### `reverse_proxy` (Default: Caddy)
Ingress 80/443 (+ HTTP/3 UDP 443), Sandbox mit `CAP_NET_BIND_SERVICE`, Rechte auf
`/etc/caddy`, auditd-Watch. Für **Traefik**: in `profiles/reverse_proxy.yml`
`profile_service: traefik.service` und `ReadWritePaths` anpassen.
Läuft der Proxy als **Container**, greifen nur die Firewall-Teile — die Dienst-
Härtung kommt dann über die Container-Ebene.

### `container_host` (Docker)
- **daemon.json-Härtung** (in bestehende Config gemergt): `no-new-privileges`,
  `icc:false`, `live-restore:true`, `userland-proxy:false`, Log-Rotation. Anpassbar
  über `docker_hardening` (group_vars).
- **Docker umgeht ufw!** Veröffentlichte Ports (`-p 8080:80`) sind sonst trotz
  Firewall offen. Lösung (opt-in): `docker_restrict_published: true` +
  `docker_published_allow: [8080, 443]` → eine `DOCKER-USER`-Kette (default-deny +
  Allowlist) in `/etc/ufw/after.rules`. **Standardmäßig AUS**, da es Container-
  Netzwerk einschränken kann — bewusst aktivieren und testen.
- **Podman (rootless)** braucht dieses Profil weitgehend nicht (keine root-Daemon-,
  keine ufw-Bypass-Problematik) und ist die sicherere Alternative.

## Drift-Erkennung (läuft immer, nur Meldung)

Jeder Lauf vergleicht **lauschende Nicht-loopback-Ports** (`ss -tlnH`) mit den
**erwarteten** (SSH + `firewall_extra_rules` + Profil-Ingress). Ungedeckte Ports
landen im Report (`/var/log/anvil/reports/drift-<datum>.txt`) und als ntfy-
Warnung. **Es wird nichts blockiert** (`profiles_drift_detect: false` schaltet es ab).

## Eigenes Profil anlegen

`profiles/<name>.yml` (deklarativ):
```yaml
profile_service: meindienst.service        # optional
profile_ingress: [{ port: 8443, proto: tcp, comment: "api" }]
profile_egress: []
profile_apparmor: []                       # /etc/apparmor.d-Profile
profile_sandbox: { NoNewPrivileges: "true", ProtectSystem: strict, ... }
profile_paths: [{ path: /etc/meindienst, owner: root, group: root, mode: "0750" }]
profile_audit: [{ path: /etc/meindienst, perms: wa, key: meindienst }]
profile_restart: true
```
Dann `ANVIL_PROFILES=(... meindienst)`. Fehlt die Datei, warnt preflight und das
Profil wird übersprungen.

## Rückbau / Rollback

- Profil aus `ANVIL_PROFILES` entfernen + erneut laufen → Overlay wird sauber entfernt.
- `sudo ./bootstrap.sh --rollback` stellt die Konfiguration des letzten Backups wieder
  her und reaktiviert betroffene Dienste (daemon-reload + reload).
