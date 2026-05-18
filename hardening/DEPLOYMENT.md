# Deployment und Pilot

## Standalone-Rechner

1. Dateien auf den Zielrechner kopieren.
2. `hardening-config.json` pruefen und anpassen.
3. Als Administrator starten:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Invoke-Hardening.ps1 -InstallScheduledTask
```

4. AppLocker-Ereignisse im Audit-Modus pruefen.
5. `EnforcementMode` spaeter auf `Enforce` setzen und Skript erneut laufen lassen.

## AD-Rechner

1. `MachineRole` auf `ADManaged` setzen.
2. `ApplyPolicyOnADManagedMachines` auf `false` lassen, wenn GPO fuehrend bleiben soll.
3. Dasselbe XML als Referenz fuer die GPO-Regeln verwenden.
4. Das Skript lokal mit `-ValidateOnly` oder ohne Policy-Import laufen lassen, damit Logging, Zeitdienst und Basis-Hardening weiterhin geprueft werden.

## Empfohlener Pilot

- 1 Standalone-Rechner
- 1 AD-Rechner
- 1 bis 2 Wochen Audit-Modus
- Event-Logs fuer AppLocker, Defender und Task-Scheduler pruefen
- Danach auf Enforce schalten und nur dann in die Breite gehen, wenn alle Geschaeftsanwendungen sauber starten

## Dinge ausserhalb des Skripts

- BIOS/UEFI-Passwort setzen
- USB-Boot deaktivieren
- BitLocker pruefen
- Physische Ports absichern, wenn Kunden direkt ans Geraet koennen
- Optional Shell-Ersatz oder Kiosk-Modus als zweite Ausbaustufe
