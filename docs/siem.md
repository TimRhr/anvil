# Anvil — SIEM-Anbindung (optional)

Anvil kann Logs/Events optional an ein **SIEM** weiterleiten — pluggable über
`siem_provider`. Zwei Wege, je nach SIEM:

| Provider | Für wen | Wie |
|---|---|---|
| `syslog` | **jedes** SIEM (Wazuh, Graylog, Splunk, Elastic …) | rsyslog-Forward (verlustarme Disk-Queue) **+ auditd→syslog** |
| `wazuh` | **Wazuh** mit vollem Funktionsumfang | Wazuh-**Agent** (liest `audit.log`/Logs nativ, FIM, SCA, Active-Response) |
| `none` | aus (Default) | — |

## Variante A — generisch via Syslog (am einfachsten)

Funktioniert mit **jedem** SIEM, das Syslog annimmt. rsyslog leitet alles weiter,
was es sieht (auth/sshd/sudo/fail2ban/kernel …); zusätzlich werden **auditd-Events**
über das audisp-syslog-Plugin eingespeist.

```bash
# config/anvil.conf
ANVIL_SIEM_PROVIDER="syslog"
ANVIL_SIEM_HOST="siem.example.lan"
```
Feinheiten in `group_vars/all/main.yml`:
```yaml
siem_syslog_port: 514          # Wazuh-Syslog oft 514
siem_syslog_protocol: tcp      # tcp | tls | udp  (tls braucht Zertifikate)
siem_audit_forward: true       # auditd-Events mitschicken
```
**Wazuh als Syslog-Ziel:** im Manager einen Remote-Syslog-Eingang aktivieren
(`<remote><connection>syslog</connection><allowed-ips>…</allowed-ips></remote>`),
dann `ANVIL_SIEM_HOST` = Manager-IP. Einfach, aber ohne Agent-Features (FIM/SCA).

## Variante B — Wazuh-Agent (empfohlen für Wazuh)

Installiert den `wazuh-agent` aus dem offiziellen Wazuh-Repo und richtet ihn auf
den Manager aus. Der Agent liest `/var/log/audit/audit.log` und weitere Logs
**nativ** (kein Syslog-Plumbing) und bringt FIM, SCA und Active-Response mit.

```bash
# config/anvil.conf
ANVIL_SIEM_PROVIDER="wazuh"
ANVIL_SIEM_HOST="wazuh-manager.example.lan"
```
Optional in `group_vars/all/main.yml`:
```yaml
siem_wazuh_version: ""          # leer = neueste 4.x; oder z.B. "4.9.2-1"
siem_wazuh_agent_group: default
```
**Enrollment:** Verlangt dein Manager ein authd-Passwort, hinterlege es im Vault
(`vault_wazuh_registration_password`) — Anvil schreibt es nach
`/var/ossec/etc/authd.pass`. Ohne Passwort nutzt der Agent die Auto-Registrierung
des Managers. Nach dem Lauf:
```bash
sudo systemctl status wazuh-agent
sudo /var/ossec/bin/agent_control -l      # auf dem Manager: Agent sichtbar?
```

## Egress / Firewall

Im crown-Modus mit `firewall_egress_enforce=true` muss der SIEM-Port ausgehend
erlaubt sein — ergänze ihn in `firewall_egress_allow` (group_vars), z.B.
`{port: 1514, proto: tcp}` (Wazuh-Agent) bzw. den Syslog-Port.

## Hinweise

- `siem_provider` ersetzt das ältere Low-Level-Toggle `enable_remote_syslog` —
  **nicht beide** gleichzeitig auf dasselbe Ziel (sonst doppelte Weiterleitung).
- Abschalten: `ANVIL_SIEM_PROVIDER="none"` (der `syslog`-Forward bzw. Agent bleibt
  dann installiert; zum vollständigen Entfernen Paket/Conf manuell deinstallieren).
- Der Wazuh-Agent zieht aus dem Internet (packages.wazuh.com) — im abgeschotteten
  Netz vorher spiegeln.
