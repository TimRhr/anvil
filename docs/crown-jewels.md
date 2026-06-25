# 👑 Anvil — Crown-Jewels-Posture

## Übersicht

Anvil kennt zwei **Posturen** (Härtungsstufen), gesteuert über die Variable
`anvil_posture` in [`config/anvil.conf`](../config/anvil.conf.example):

| Posture | Typ | Beschreibung |
|---------|-----|-------------|
| `baseline` (Default) | 🔧 Standard | Härtung nach BSI SYS.1.3 / CIS L1, verfügbarkeitsorientiert |
| `crown_jewels` | 🔐 Höchsthärtung | Aktiviert zusätzliche Sperrmaßnahmen für Kronjuwelen-Hosts |

### Leitprinzip

> *Posture hebt den Boden an* — eine Maßnahme greift, wenn der Nutzer sie
> explizit aktiviert ODER die crown-Posture sie verlangt. Lockout- und
> verfügbarkeitskritische Schritte sind **gegated** (Preflight-Checks, sauberer
> Fallback).

### Aktivierung

```bash
# config/anvil.conf
ANVIL_POSTURE="crown_jewels"

# Optional: MFA-Methode überschreiben
# ANVIL_SSH_MFA="totp"   # statt auto (→ fido2 im crown-Modus)
```

Dann Anvil wie gewohnt ausführen:

```bash
sudo ./bootstrap.sh
```

---

## Maßnahmen im Detail

### SSH-MFA (AU-1) — FIDO2 + TOTP

Im crown-Modus wird `auto` zu **FIDO2** aufgelöst. Zwei Verfahren:

#### FIDO2 (Hardware-Token)

Empfohlen. Verlangt `sk-ssh-ed25519@openssh.com`- oder
`sk-ecdsa-sha2-nistp256@openssh.com`-Keys in `admin_pubkeys`.

**Schlüssel erzeugen:**
```bash
ssh-keygen -t ed25519-sk -O resident -O application=ssh:anvil -C "admin@workstation"
```

**Lockout-Schutz:** Ohne `sk-`-Keys in `admin_pubkeys` wird FIDO2 **nicht**
erzwungen — Fallback auf `publickey` mit Warnung.

#### TOTP (OATH Toolkit — vendor-neutral, Open Source)

Alternativ via `ANVIL_SSH_MFA="totp"`. Anvil nutzt **`pam_oath`** (OATH Toolkit,
GPL) — kein herstellerspezifisches Tool; funktioniert mit jeder TOTP-App
(Aegis, FreeOTP, …). Secrets liegen root-verwaltet in `/etc/users.oath`.

**Wichtig:** Bei aktivem TOTP deaktiviert Anvil die UNIX-Passwortabfrage
(`@include common-auth`) im sshd-PAM-Stack — sonst würde zusätzlich das
Passwort verlangt (Lockout für key-only-Admins).

**Enrollment auf dem Zielhost (je Admin-User):**
```bash
# Secret erzeugen und je Admin-User in /etc/users.oath eintragen:
HEX="$(head -c 20 /dev/urandom | xxd -p -c40)"
echo "HOTP/T30/6 <admin-user> - $HEX" | sudo tee -a /etc/users.oath
sudo chmod 600 /etc/users.oath
# Base32-Secret für die TOTP-App anzeigen (in Authenticator-App eintragen):
oathtool --verbose --totp "$HEX"
```

**Nach Enrollment bestätigen** (sonst bleibt TOTP staged, kein Enforce):

```bash
# config/anvil.conf
ANVIL_SSH_MFA="totp"
```

Und in [`group_vars/all/main.yml`](../group_vars/all/main.yml):
```yaml
ssh_totp_enrolled: true
```

**Lockout-Schutz:** Ohne `ssh_totp_enrolled=true` wird TOTP **nicht** erzwungen.

#### Zugriffsbeschränkung auf Management-Netz

Optional via `ssh_allowed_cidrs` in
[`group_vars/all/main.yml`](../group_vars/all/main.yml):

```yaml
ssh_allowed_cidrs:
  - 10.0.0.0/8
  - 172.16.0.0/12
```

---

### Egress-Firewall (NW-1)

Im crown-Modus **vorbereitet, aber default `allow`** (kein Betriebsrisiko).

**Aktivierung:**
```yaml
# group_vars/all/main.yml
firewall_egress_enforce: true
```

Schaltet `ufw` auf `deny outgoing` um, mit Allowlist für:

| Port | Proto | Zweck |
|------|-------|-------|
| 53 | udp/tcp | DNS |
| 123 | udp | NTP |
| 80 | tcp | HTTP (Updates) |
| 443 | tcp | HTTPS (Updates, ntfy) |
| 6514 | tcp | Remote-Syslog (falls aktiviert) |

**Einschränkung:** Port 443/80 sind protokollagnostisch — echter
FQDN-basierter Egress-Schutz folgt in Phase ≥4 (Proxy).

---

### auditd-Posture (AV-1, DT-1)

| Aspekt | baseline | crown_jewels |
|--------|----------|--------------|
| Aktionen | `syslog` (verfügbarkeitsfreundlich) | `syslog` (unverändert) |
| Regelschutz | `-e 2` deaktiviert | `-e 2` aktiv (immutable) |
| Remote-Logging | Optional | Empfohlen, nicht erzwungen |

**Immutable-Modus:** `enable_auditd_immutable: true` aktiviert das `-e 2`-Flag
in den audit-Regeln. Nach dem Laden der Regeln sind diese **bis zum Reboot**
unveränderbar — schützt vor Deaktivierung durch Angreifer.

**Strikte Aktionen** (optional, bewusst nicht default):
```yaml
# group_vars/all/main.yml
auditd_admin_space_left_action: single   # oder: halt
auditd_disk_full_action: halt
```

---

### AppArmor Enforce (MI-3)

Im crown-Modus werden **alle vorhandenen AppArmor-Profile** via `aa-enforce`
in den Enforce-Modus gesetzt (`apparmor_enforce_all: true`).

**Problematisches Profil identifizieren und zurückstufen:**
```bash
sudo aa-complain /etc/apparmor.d/usr.bin.example
```

**Gesamten enforce-Modus zurücksetzen (Notfall):**
```bash
sudo aa-complain /etc/apparmor.d/*
```

---

### Kernel Lockdown LSM (MI-3)

Im crown-Modus wird `kernel_lockdown: "confidentiality"` gesetzt. Dies
deployt ein GRUB-Cmdline-Drop-in (`/etc/default/grub.d/99-anvil-lockdown.cfg`)
mit `lockdown=confidentiality` als Kernel-Parameter.

**Stufen:**

| Wert | Wirkung |
|------|---------|
| `""` (leer) | Deaktiviert (entfernt Drop-in) |
| `integrity` | Verhindert Kernel-Modifikation (kexec, /dev/mem) |
| `confidentiality` | Wie integrity + schützt Kernel-Speicher vor Lesezugriff |

**Wirksam nach Reboot:**
```bash
cat /sys/kernel/security/lockdown
# Erwartet: "[confidentiality]" oder "[integrity]"
```

**Hinweis:** Module-Laden bleibt in `confidentiality` möglich (solange
`kernel.modules_disabled` nicht gesetzt ist).

---

### kernel.modules_disabled (MI-3, OPT-IN)

⚠️ **Achtung:** Setzt `kernel.modules_disabled=1` via sysctl — verhindert das
Laden/Entladen **aller** Kernel-Module nach dem Setzen. Kann
`ufw`/`nftables`-Modulladen brechen. Einmal aktiviert, bleibt der Wert **bis
zum Reboot** bestehen, selbst wenn auf 0 zurückgesetzt.

```yaml
# group_vars/all/main.yml — bewusst opt-in, auch im crown default false
kernel_disable_module_loading: true   # nur setzen, wenn klar ist, was passiert
```

---

### Bootloader / GRUB-Passwort (BO-1)

Anvil läuft **post-install** ⇒ eine nachträgliche LUKS-Verschlüsselung ist
**nicht möglich**. Empfehlungen für die Erstinstallation:

#### LUKS (Full-Disk-Encryption)

```bash
# Beim Provisioning (vor erstem Anvil-Lauf):
# Partitionsschema mit LUKS:
# - /boot: ext4, 1-2GB
# - /: LUKS (cryptroot) → ext4/btrfs
# - swap: LUKS (cryptswap) → swap

# Beispiel (Ubuntu-Server-Installer):
# - /boot: 2GB ext4
# - /: 100% remaining, LUKS (cryptroot)
```

#### GRUB-Passwort

Im crown-Modus empfohlen, bleibt aber opt-in (Konsolen-Lockout-Risiko):

```bash
# config/anvil.conf
ENABLE_GRUB_PASSWORD=true
```

Passwort im Vault setzen:
```yaml
# group_vars/all/vault.yml
vault_grub_password: "sicherers-passwort"
```

#### Secure Boot / TPM Measured Boot

Falls der Host Secure Boot unterstützt:
- **Secure Boot aktivieren** im UEFI-Menü (oft ab Werk an)
- **TPM Measured Boot:** `systemd-cryptenroll` für automatisches LUKS-Entsperren
  via TPM (erfordert systemd 248+, Ubuntu 20.04+)

---

### Angriffsfläche — Attack Surface Report

Bei **jedem** Anvil-Lauf wird ein Angriffsflächen-Report erstellt
(`/var/log/anvil/reports/attack-surface-*.txt`):

- Lauschende Sockets (`ss -tulpn`)
- Aktive und fehlgeschlagene systemd-Units
- Posture-Aktivierungen (crown-Maßnahmen)
- ntfy-Benachrichtigung bei konfiguriertem ntfy

Optional können unerwünschte Dienste maskiert werden:

```yaml
# group_vars/all/main.yml
os_mask_services:
  - avahi-daemon.service
  - cups.service
```

> **Hinweis:** Aggressives automatisches Maskieren ist nicht Standard — Anvil
> priorisiert **Sichtbarkeit** (damit Admins entscheiden können), bevor Dienste
> blind deaktiviert werden. Per-Service-Sandboxing folgt in Phase 3.

---

## Zwischen Posturen wechseln

| Wechsel | Effekt | Risiko |
|---------|--------|--------|
| `baseline` → `crown_jewels` | Strengere Defaults werden aktiv | MFA-Lockout möglich ohne FIDO2-Keys/TOTP-Enrollment (abgefangen durch Preflight) |
| `crown_jewels` → `baseline` | Lockere Defaults, keine Deaktivierung von MFA | Manuelles Zurücksetzen von sshd_config, auditd-Regeln etc. nötig |

### Von crown zurück zu baseline

Ein reines Umstellen von `ANVIL_POSTURE="baseline"` **deaktiviert** crown-Maßnahmen
nicht automatisch (z.B. MFA bleibt aktiv). Notwendige Schritte:

1. **SSH-MFA:** `AuthenticationMethods` in
   `/etc/ssh/sshd_config.d/00-anvil-hardening.conf` manuell auf `publickey`
   setzen, dann `systemctl reload sshd`
2. **AppArmor:** `sudo aa-complain /etc/apparmor.d/*`
3. **Kernel Lockdown:** `rm /etc/default/grub.d/99-anvil-lockdown.cfg && update-grub`
4. **Egress:** `ufw default allow outgoing`
5. **auditd immutable:** `-e 2` aus Regeln entfernen, `augenrules --load`

---

## Sicherheitshinweise & Restrisiken

| Maßnahme | Restrisiko |
|----------|-----------|
| MFA FIDO2 | Hardware-Token-Verlust → Recovery-Prozess nötig (Fallback-Key) |
| MFA TOTP | Secret auf Admin-Gerät, kein Hardware-Anker |
| Egress (portbasiert) | Kein FQDN-Schutz — App in Phase 4 kann 443 für C2 missbrauchen |
| AppArmor enforce | Fehlerhaftes Profil kann Dienst lahmlegen → `aa-complain` |
| Kernel lockdown | Verhindert kexec/kdump — Kernel-Fallback über GRUB weiter möglich |
| kernel.modules_disabled | Bricht ufw/nftables — nur mit vorherigem Test aktivieren |
| auditd immutable | Regeländerungen erzwingen Reboot |
| GRUB-Passwort | Konsolen-Lockout bei falscher Konfiguration |

---

## Verifikation

Nach der Provisionierung im crown-Modus:

```bash
# Posture prüfen
grep anvil_posture /var/lib/anvil/state.json 2>/dev/null || echo "Kein State"

# FIDO2 / MFA
ssh -p 22 admin@host -o PreferredAuthentications=publickey

# AppArmor
aa-status --enforced | wc -l

# Kernel Lockdown
cat /sys/kernel/security/lockdown

# auditd immutable
grep -c '\-e 2' /etc/audit/rules.d/*.rules

# Attack Surface Report
ls -la /var/log/anvil/reports/

# Lynis (falls installiert)
lynis audit system --quick 2>/dev/null | grep "Hardening index"
```
