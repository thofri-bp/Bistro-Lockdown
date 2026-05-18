# AppLocker baseline for front-desk Windows PCs

Dieses Repo enthaelt eine lokal ausrollbare AppLocker-Basis fuer Empfangs- und Buchungsrechner unter `Windows 10/11 Pro`. Die Regeln werden aus einer `JSON`-Datei erzeugt, zuerst im `AuditOnly`-Modus getestet und danach kontrolliert auf `Enabled` gestellt.

## TL;DR

Auf dem Windows-Zielrechner in einer PowerShell mit Administratorrechten:

```powershell
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process
.\scripts\Invoke-AppLockerBaseline.ps1 -Mode ValidateConfig
.\scripts\Invoke-AppLockerBaseline.ps1 -Mode GeneratePolicy -OutputPath .\out\applocker-preview.xml
.\scripts\Invoke-AppLockerBaseline.ps1 -Mode ApplyAudit
.\scripts\Invoke-AppLockerBaseline.ps1 -Mode ExportEffectivePolicy
```

Dann den Rechner im echten Betrieb testen und die AppLocker-Eventlogs einige Tage bis etwa eine Woche beobachten. Wenn alles passt:

```powershell
.\scripts\Invoke-AppLockerBaseline.ps1 -Mode ApplyEnforce
```

Die Idee dahinter:

- Standard-Windows-Komponenten und normal installierte Programme sollen weiterlaufen
- Fachanwendungen und benoetigte Updater sollen gezielt erlaubt werden
- normale Benutzer sollen nur freigegebene Programme starten koennen
- lokale Administratoren sollen fuer Wartung und Support arbeitsfaehig bleiben

## Inhalt des Repos

- `scripts/Invoke-AppLockerBaseline.ps1`
  Das Hauptskript. Es validiert die Konfiguration, erzeugt eine AppLocker-XML, wendet Audit- oder Enforce-Policies an und exportiert die effektive Policy.
- `config/applocker.config.json`
  Die zentrale Regeldefinition fuer erlaubte Pfade, einzelne Dateien und signierte Publisher.

## Voraussetzungen

Vor dem Einsatz sollte der Zielrechner diese Punkte erfuellen:

- `Windows 10 ab 2004` oder `Windows 11`
- lokale Administratorrechte fuer die Ausfuehrung des Skripts
- mindestens ein Test- oder Referenzrechner, auf dem die benoetigte Buchungssoftware bereits installiert ist
- Bediener arbeiten mit Standardnutzerkonten

## Sicherheitsmodell

Das Skript arbeitet jetzt ohne separate Benutzergruppe:

- Freigaberegeln werden fuer `Everyone` erzeugt
- lokale Administratoren erhalten zusaetzlich eine uneingeschraenkte Freigabe fuer Wartung
- nicht explizit erlaubte Programme bleiben fuer normale Benutzer blockiert, weil AppLocker als Allowlist arbeitet

Dadurch ist keine lokale Gruppe wie `FrontDeskUsers` mehr erforderlich.

## Empfohlener Ablauf

Die sicherste Einfuehrung besteht aus vier Schritten:

1. Referenzrechner vorbereiten
2. Konfiguration pflegen und validieren
3. Audit-Modus aktivieren und Eventlogs auswerten
4. Erst danach auf Enforce umstellen

## Schritt 1: Referenzrechner vorbereiten

Auf einem Musterrechner sollten bereits installiert und getestet sein:

- die Buchungs- oder Kassensoftware
- alle benoetigten Zusatztools
- gegebenenfalls Drucker- oder Scanner-Software
- benoetigte Updater oder Auto-Update-Komponenten

Wenn spaeter Programme fehlen, ist das nicht schlimm. Du kannst die JSON erweitern und die Policy neu erzeugen. Genau dafuer ist die Audit-Phase vorgesehen.

## Schritt 2: Konfiguration bearbeiten

Die Datei `config/applocker.config.json` ist die zentrale Steuerung.

### `modeDefaults`

Legt fest, welcher Modus verwendet wird, wenn `-Mode` nicht uebergeben wird.

```json
"modeDefaults": {
  "defaultMode": "AuditOnly"
}
```

Empfehlung:

- zuerst `AuditOnly`
- erst nach erfolgreicher Testphase `Enabled`

### `allowedPaths`

Hier erlaubst du komplette Verzeichnisse oder Pfadmuster. Das ist die einfachste und stabilste Freigabeart.

Beispiel:

```json
{
  "name": "Program Files",
  "path": "%PROGRAMFILES%\\*",
  "collections": ["Exe", "Msi", "Script"],
  "description": "Klassische 64-Bit-Installationen."
}
```

Typische Einsaetze:

- `%WINDIR%\\*` fuer Windows-Bestandteile
- `%PROGRAMFILES%\\*` fuer normale 64-Bit-Software
- `%PROGRAMFILES(X86)%\\*` fuer normale 32-Bit-Software

Wichtig:

- je breiter ein Pfad freigegeben wird, desto weniger restriktiv ist die Policy
- benutzerbeschreibbare Verzeichnisse wie `C:\Users\...`, `Downloads`, `Desktop`, `AppData` oder `Temp` sollten hier normalerweise nicht erlaubt werden

### `allowedFiles`

Hier erlaubst du einzelne Dateien, zum Beispiel eine konkrete Fachanwendung.

Beispiel:

```json
{
  "name": "Booking App",
  "path": "C:\\Program Files\\Vendor\\BookingApp\\BookingApp.exe",
  "collections": ["Exe"],
  "description": "Explizit freigegebene Fachanwendung."
}
```

Nutze `allowedFiles`, wenn:

- nur eine einzelne `.exe` freigegeben werden soll
- der Installationspfad nicht ueber einen breiten Basis-Pfad abgedeckt werden soll
- du ein Programm sehr gezielt erlauben willst

### `allowedPublishers`

Hier definierst du signaturbasierte Regeln fuer Hersteller. Das ist besonders hilfreich fuer Updater oder signierte Drittanbieter-Software.

Beispiel:

```json
{
  "name": "Vendor updater",
  "publisherName": "O=VENDOR GMBH, L=STADT, S=BUNDESLAND, C=DE",
  "productName": "Vendor Updater",
  "binaryName": "*",
  "lowVersion": "*",
  "highVersion": "*",
  "collections": ["Exe", "Msi"]
}
```

Empfehlung:

- Publisher-Regeln fuer Microsoft und klar bekannte Hersteller verwenden
- moeglichst nicht zu viele unbekannte oder sehr breite Publisher freigeben
- Produktnamen gezielt nutzen, wenn ein Hersteller viele verschiedene Programme signiert

Hinweis zum Sperrmodell:

- separate `blockedPaths` sind in dieser Version nicht mehr noetig
- alles, was nicht explizit ueber `allowedPaths`, `allowedFiles` oder `allowedPublishers` erlaubt ist, bleibt fuer normale Benutzer gesperrt

## Schritt 3: Konfiguration pruefen

Auf dem Ziel- oder Referenzrechner in einer PowerShell mit Administratorrechten:

```powershell
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process
.\scripts\Invoke-AppLockerBaseline.ps1 -Mode ValidateConfig
```

Der Modus `ValidateConfig` prueft:

- ob die JSON lesbar ist
- ob Pflichtfelder vorhanden sind
- ob nur unterstuetzte Rule-Collections verwendet werden

## Schritt 4: Vorschau-Policy erzeugen

Bevor du etwas aktivierst, kannst du die XML nur generieren:

```powershell
.\scripts\Invoke-AppLockerBaseline.ps1 -Mode GeneratePolicy -OutputPath .\out\applocker-preview.xml
```

Das ist sinnvoll, wenn du die resultierende Policy vorab dokumentieren oder pruefen willst.

## Schritt 5: Audit-Modus aktivieren

Jetzt wird die Policy angewendet, aber noch nicht erzwungen:

```powershell
.\scripts\Invoke-AppLockerBaseline.ps1 -Mode ApplyAudit
```

Dabei passiert:

- die XML wird erzeugt
- der Dienst `Application Identity` wird bei Bedarf auf `Automatic` gesetzt und gestartet
- die Policy wird lokal angewendet
- AppLocker protokolliert, was spaeter blockiert worden waere

## Schritt 6: Audit-Ereignisse auswerten

Fuer die Auswertung der Audit-Phase sind diese Logs relevant:

- `Microsoft-Windows-AppLocker/EXE and DLL`
- `Microsoft-Windows-AppLocker/MSI and Script`
- `Microsoft-Windows-AppLocker/Packaged app-Execution`

Beispiel fuer die letzten Eintraege:

```powershell
Get-WinEvent -LogName 'Microsoft-Windows-AppLocker/EXE and DLL' -MaxEvents 20 |
    Format-Table TimeCreated, Id, Message -AutoSize
```

Hilfreich ist waehrend der Audit-Phase ein klarer Testablauf:

- als Bedienkonto anmelden
- Buchungssoftware starten
- Druckvorgaenge und Scanner pruefen
- benoetigte Hilfsprogramme oeffnen
- Updater oder Auto-Start-Komponenten pruefen
- testweise eine `.exe` aus `Downloads` oder `Desktop` starten

Wenn AppLocker benoetigte Programme im Audit als problematisch zeigt:

- bei normal installierter Software eher `allowedFiles` oder `allowedPaths` ergaenzen
- bei signierten Updatern eher `allowedPublishers` ergaenzen
- danach die Policy erneut erzeugen und `ApplyAudit` noch einmal ausfuehren

## Schritt 7: Effektive Policy exportieren

Wenn du dokumentieren willst, was aktuell aktiv ist:

```powershell
.\scripts\Invoke-AppLockerBaseline.ps1 -Mode ExportEffectivePolicy
```

Die exportierte XML kannst du zum Vergleich, zur Doku oder fuer spaetere Analysen aufheben.

## Schritt 8: Enforcement aktivieren

Erst wenn die Audit-Phase sauber war:

```powershell
.\scripts\Invoke-AppLockerBaseline.ps1 -Mode ApplyEnforce
```

Ab diesem Zeitpunkt werden nicht erlaubte Starts fuer normale Benutzer tatsaechlich blockiert, waehrend Administratoren weiter ihre Wartungsfreigabe behalten.

## Verfuegbare Modi

- `ValidateConfig`
  Prueft die JSON-Struktur.
- `GeneratePolicy`
  Erzeugt nur die XML-Datei, ohne sie anzuwenden.
- `ApplyAudit`
  Erzeugt und aktiviert eine `AuditOnly`-Policy.
- `ApplyEnforce`
  Erzeugt und aktiviert eine erzwungene Policy.
- `ExportEffectivePolicy`
  Exportiert die aktuell wirksame lokale AppLocker-Konfiguration.

## Typische Anpassungen

### Neue Fachanwendung aufnehmen

Wenn ein Programm sauber unter `Program Files` installiert ist, reicht oft schon die bestehende Basisregel. Wenn es an einem Sonderpfad liegt, nimm es in `allowedFiles` auf.

### Updater freigeben

Wenn ein Updater nicht ueber `%PROGRAMFILES%` abgedeckt ist, ist eine Publisher-Regel oft die bessere Wahl als ein breiter Pfad.

### Benutzernahe Pfade absichern

Benutzernahe Verzeichnisse werden in dieser Variante nicht ueber explizite Deny-Regeln gesperrt, sondern dadurch abgesichert, dass sie nicht freigegeben werden.

## Wichtige Hinweise fuer den Produktiveinsatz

- immer zuerst im Audit-Modus testen
- Aenderungen nie direkt auf allen Rechnern gleichzeitig scharf schalten
- wenn moeglich zuerst einen einzelnen Test-PC im Live-Betrieb beobachten
- die Platzhalter in der Beispielkonfiguration muessen vor dem echten Einsatz ersetzt werden
- Publisher-Werte muessen zu den realen digitalen Signaturen der eingesetzten Software passen
- keine breiten Freigaben fuer `C:\Users\*` oder aehnliche benutzerschreibbare Pfade setzen

## Troubleshooting

### Eine benoetigte Anwendung startet im Audit nicht sauber durch

Eventlog pruefen und entscheiden:

- liegt die Datei in einem legitimen Programmpfad, dann `allowedFiles` oder `allowedPaths` anpassen
- handelt es sich um einen signierten Updater, dann `allowedPublishers` erweitern

### Administratoren werden unerwartet eingeschraenkt

Pruefen, ob versehentlich zu enge Freigaben fuer allgemeine Systempfade gesetzt wurden oder ob ein Admin mit einem normalen Benutzerkonto arbeitet. Die mitgelieferte Logik erzeugt zusaetzlich eine globale Admin-Freigabe.

### Eine Policy muss schnell dokumentiert oder verglichen werden

`ExportEffectivePolicy` verwenden und die XML sichern.

## Rueckbau und Notfallstrategie

Vor produktivem Rollout sollte immer ein lokaler Administratorzugang verfuegbar bleiben. Fuer kritische Systeme empfiehlt sich ausserdem:

- ein separater Wartungsaccount
- ein dokumentierter Vor-Ort-Zugang
- vorheriger Test auf einem baugleichen Geraet

Falls du spaeter einen expliziten Rueckbau- oder Reset-Ablauf im Skript haben willst, kann ich den als zusaetzlichen Modus noch einbauen.
