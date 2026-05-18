# Windows Hardening mit AppLocker

Dieses Verzeichnis enthaelt ein kleines, idempotentes PowerShell-Paket fuer kontrollierte Windows-Arbeitsgeraete.

## Inhalt

- `hardening/Invoke-Hardening.ps1`
  Zentrales Admin-Skript fuer Konfiguration, Drift-Korrektur, Logging und geplanten Task.
- `hardening/hardening-config.json`
  Soll-Zustand fuer Betriebsmodus, Zeitserver, USB, Browser, lokale Pfade und Task-Intervall.
- `hardening/apps-allowlist.json`
  Dokumentierte Allowlist fuer zusaetzliche Business-Programme und Publisher-Regeln.
- `hardening/applocker-policy.xml`
  Basis-AppLocker-Policy mit Default-Regeln fuer Windows und `Program Files`.

## Typischer Ablauf

1. Referenzrechner mit allen benoetigten Geschaeftsanwendungen vorbereiten.
2. `apps-allowlist.json` anpassen.
3. `hardening-config.json` anpassen.
4. Skript als Administrator im Audit-Modus starten:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\hardening\Invoke-Hardening.ps1 -InstallScheduledTask
```

5. AppLocker-Ereignisse auswerten.
6. `EnforcementMode` in der Konfiguration von `AuditOnly` auf `Enforce` stellen.

## AD und Standalone

- `MachineRole = "Standalone"`:
  Das Skript ist fuehrend und setzt Konfiguration aktiv durch.
- `MachineRole = "ADManaged"`:
  Das Skript dokumentiert und validiert den Zustand. AppLocker-Import kann optional deaktiviert bleiben, wenn GPO die Durchsetzung uebernimmt.

## Wichtige Hinweise

- Das Skript muss mit administrativen Rechten laufen.
- BIOS/UEFI-Passwort und Boot von USB sind bewusst **nicht** skriptgesteuert, sondern muessen manuell oder per Hersteller-Tool gesetzt werden.
- AppLocker sollte zuerst im Audit-Modus getestet werden, damit legitime Programme nicht versehentlich blockiert werden.
