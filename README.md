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
- `config/applocker.v2.config.json`
  Eine schaerfere zweite Iteration auf Basis der ersten Audit-Woche mit gezielten Nicht-Microsoft-Freigaben.

## Voraussetzungen

Vor dem Einsatz sollte der Zielrechner diese Punkte erfuellen:

- `Windows 10 ab 2004` oder `Windows 11`
- lokale Administratorrechte fuer die Ausfuehrung des Skripts
- mindestens ein Test- oder Referenzrechner, auf dem die benoetigte Buchungssoftware bereits installiert ist
- Bediener arbeiten mit Standardnutzerkonten

## Wichtige Hinweise vor dem Start

### Immer als Administrator ausfuehren

Das Skript muss in einer `PowerShell mit Administratorrechten` gestartet werden, weil es die lokale AppLocker-Policy des Rechners setzt und den Dienst `Application Identity` verwaltet.

Wenn du das Skript ohne Erhoehung startest, sind typische Folgen:

- `Zugriff verweigert`
- `AppIDSvc` kann nicht konfiguriert werden
- die Policy laesst sich nicht setzen

### Ausfuehrung von Skripten erlauben

Viele Rechner blockieren PowerShell-Skripte standardmaessig ueber die Execution Policy. Fuer den Test reicht in der Regel:

```powershell
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process
```

Das gilt nur fuer das aktuelle PowerShell-Fenster. Alternativ kannst du das Skript direkt so starten:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\Invoke-AppLockerBaseline.ps1 -Mode ValidateConfig
```

### PowerShell-Version

Das Skript ist auf `Windows PowerShell 5.1` und neuere PowerShell-Versionen ausgelegt. Falls auf dem Rechner eine aeltere oder restriktive Umgebung aktiv ist, kannst du die Version so pruefen:

```powershell
$PSVersionTable
```

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

Fuer spaetere Haertung kannst du auch mit einer zweiten Iteration arbeiten:

- `applocker.config.json`
  Breitere Baseline fuer den ersten sicheren Audit-Lauf
- `applocker.v2.config.json`
  Engere Folgeversion mit aus dem Audit abgeleiteten Einzel-Freigaben

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

Wenn du bewusst mit einer anderen Konfiguration testen willst, gib sie explizit an:

```powershell
.\scripts\Invoke-AppLockerBaseline.ps1 -Mode ApplyAudit -ConfigPath .\config\applocker.v2.config.json
```

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

## Monitoring

Nach `ApplyAudit` oder `ApplyEnforce` kannst du den Zustand des Rechners mit diesen Befehlen schnell pruefen.

### AppLocker-Logs direkt anzeigen

Die letzten EXE- und DLL-Treffer:

```powershell
Get-WinEvent -LogName 'Microsoft-Windows-AppLocker/EXE and DLL' -MaxEvents 30 |
    Format-Table TimeCreated, Id, Message -AutoSize
```

Die letzten MSI- und Skript-Treffer:

```powershell
Get-WinEvent -LogName 'Microsoft-Windows-AppLocker/MSI and Script' -MaxEvents 30 |
    Format-Table TimeCreated, Id, Message -AutoSize
```

Die letzten Packaged-App-Treffer:

```powershell
Get-WinEvent -LogName 'Microsoft-Windows-AppLocker/Packaged app-Execution' -MaxEvents 30 |
    Format-Table TimeCreated, Id, Message -AutoSize
```

### Nur heutige Ereignisse anzeigen

```powershell
Get-WinEvent -LogName 'Microsoft-Windows-AppLocker/EXE and DLL' |
    Where-Object { $_.TimeCreated -ge (Get-Date).Date } |
    Format-Table TimeCreated, Id, Message -AutoSize
```

### Effektive Policy exportieren

Damit siehst du, was aktuell wirklich auf dem Rechner aktiv ist:

```powershell
.\scripts\Invoke-AppLockerBaseline.ps1 -Mode ExportEffectivePolicy
```

### Ganze Woche fuer Auswertung exportieren

Wenn du die Ergebnisse gesammelt mit mir oder intern auswerten willst, ist dieser Export am praktischsten. Er legt einen Zeitstempel-Ordner an und schreibt die letzten 7 Tage als CSV sowie die aktuelle Policy als XML hinein.

```powershell
$since = (Get-Date).AddDays(-7)
$outDir = ".\analysis-$(Get-Date -Format 'yyyy-MM-dd-HHmmss')"
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

.\scripts\Invoke-AppLockerBaseline.ps1 -Mode ExportEffectivePolicy -OutputPath (Join-Path $outDir 'effective-policy.xml')

Get-WinEvent -LogName 'Microsoft-Windows-AppLocker/EXE and DLL' |
    Where-Object { $_.TimeCreated -ge $since } |
    Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, MachineName, Message |
    Export-Csv -Path (Join-Path $outDir 'applocker-exe-dll-last7days.csv') -NoTypeInformation -Encoding UTF8

Get-WinEvent -LogName 'Microsoft-Windows-AppLocker/MSI and Script' |
    Where-Object { $_.TimeCreated -ge $since } |
    Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, MachineName, Message |
    Export-Csv -Path (Join-Path $outDir 'applocker-msi-script-last7days.csv') -NoTypeInformation -Encoding UTF8

Get-WinEvent -LogName 'Microsoft-Windows-AppLocker/Packaged app-Execution' |
    Where-Object { $_.TimeCreated -ge $since } |
    Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, MachineName, Message |
    Export-Csv -Path (Join-Path $outDir 'applocker-packagedapps-last7days.csv') -NoTypeInformation -Encoding UTF8

Get-Service AppIDSvc | Select-Object Name, Status, StartType |
    Export-Csv -Path (Join-Path $outDir 'appidsvc-status.csv') -NoTypeInformation -Encoding UTF8

Write-Host "Auswertung gespeichert in: $outDir"
```

Fuer die eigentliche Analyse sind meistens diese Dateien am wichtigsten:

- `applocker-exe-dll-last7days.csv`
- `applocker-msi-script-last7days.csv`
- `effective-policy.xml`

### Kompakter Export fuer wahrscheinliche Problemfaelle

Wenn du nicht alles sehen willst, sondern erst einmal die auffaelligeren Treffer, kannst du die Events der letzten 7 Tage nach typischen Schluesselwoertern filtern:

```powershell
$since = (Get-Date).AddDays(-7)
$pattern = 'Downloads|Desktop|Temp|AppData|Denied|blocked|prevented|MSI|Script|exe'

Get-WinEvent -LogName 'Microsoft-Windows-AppLocker/EXE and DLL' |
    Where-Object { $_.TimeCreated -ge $since -and $_.Message -match $pattern } |
    Select-Object TimeCreated, Id, Message |
    Export-Csv -Path .\applocker-problemfocus-exe.csv -NoTypeInformation -Encoding UTF8

Get-WinEvent -LogName 'Microsoft-Windows-AppLocker/MSI and Script' |
    Where-Object { $_.TimeCreated -ge $since -and $_.Message -match $pattern } |
    Select-Object TimeCreated, Id, Message |
    Export-Csv -Path .\applocker-problemfocus-msi-script.csv -NoTypeInformation -Encoding UTF8
```

Der volle Export ist besser fuer eine saubere Auswertung. Der kompakte Export ist eher ein schneller erster Blick.

### Dienststatus pruefen

AppLocker braucht den Dienst `Application Identity`.

```powershell
Get-Service AppIDSvc
```

Wenn alles passt, sollte der Dienst laufen oder mindestens korrekt fuer den Start vorbereitet sein.

### Praktischer Kurzablauf fuer die Kontrolle

```powershell
.\scripts\Invoke-AppLockerBaseline.ps1 -Mode ExportEffectivePolicy
Get-Service AppIDSvc
Get-WinEvent -LogName 'Microsoft-Windows-AppLocker/EXE and DLL' -MaxEvents 30 |
    Format-Table TimeCreated, Id, Message -AutoSize
```

### Worauf du im Monitoring achten solltest

- Welche Programme wuerden blockiert oder wurden blockiert
- ob die Buchungssoftware komplett startet
- ob Drucker-, Scanner- oder Kartenleser-Tools beteiligt sind
- ob Updater oder Hintergrunddienste aus ungewoehnlichen Pfaden laufen
- ob versehentlich etwas aus Benutzerprofilen gestartet werden soll

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

### Zweite Iteration aus Audit-Daten bauen

Ein bewaehrter Weg ist:

- `v1` mit breiterer Baseline eine Woche im Audit laufen lassen
- daraus die wirklich genutzten Nicht-Microsoft-Programme ableiten
- diese gezielt in `allowedFiles` oder `allowedPublishers` uebernehmen
- dann eine `v2` wieder eine Woche im Audit testen

Die mitgelieferte `config/applocker.v2.config.json` ist genau so aufgebaut und basiert auf den im ersten Audit beobachteten Programmen wie Firefox, Adobe Acrobat, Nextcloud und Intel-Hilfsprozessen.

## Wichtige Hinweise fuer den Produktiveinsatz

- immer zuerst im Audit-Modus testen
- Aenderungen nie direkt auf allen Rechnern gleichzeitig scharf schalten
- wenn moeglich zuerst einen einzelnen Test-PC im Live-Betrieb beobachten
- die Platzhalter in der Beispielkonfiguration muessen vor dem echten Einsatz ersetzt werden
- Publisher-Werte muessen zu den realen digitalen Signaturen der eingesetzten Software passen
- keine breiten Freigaben fuer `C:\Users\*` oder aehnliche benutzerschreibbare Pfade setzen

## Troubleshooting

### Das Ausfuehren von Skripts ist auf dem Rechner untersagt

Dann blockiert in der Regel die PowerShell-Execution-Policy. In einer PowerShell mit Administratorrechten:

```powershell
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process
```

Danach das Skript im selben Fenster erneut starten.

Wenn das nicht reicht:

```powershell
Get-ExecutionPolicy -List
```

Wenn dort `MachinePolicy` oder `UserPolicy` gesetzt ist, kommt die Sperre wahrscheinlich aus einer Gruppenrichtlinie.

### `AppIDSvc` kann nicht konfiguriert werden, Zugriff verweigert

Das deutet fast immer darauf hin, dass die PowerShell nicht wirklich erhoeht gestartet wurde oder dass der Dienst durch eine Richtlinie geschuetzt ist.

Pruefen:

```powershell
Get-Service AppIDSvc
sc.exe qc AppIDSvc
net session
```

Wenn `net session` mit `Systemfehler 5` endet, ist das Fenster nicht erhoeht.

### `ConvertFrom-Json`: Parameter `Depth` wurde nicht gefunden

Das tritt typischerweise unter `Windows PowerShell 5.1` auf. Das Skript ist dafuer inzwischen angepasst. Wenn die Meldung trotzdem erscheint, sicherstellen, dass wirklich die aktuelle Version des Skripts verwendet wird.

### `resolving file exception` beim Anwenden der Policy

Dieser Fehler trat auf, wenn `Set-AppLockerPolicy` nicht mit einem XML-Dateipfad, sondern mit XML-Inhalt gefuettert wurde. Das Skript wurde dafuer korrigiert.

Wenn die Meldung erneut auftaucht:

- sicherstellen, dass die aktuelle Skriptversion verwendet wird
- `GeneratePolicy` ausfuehren und pruefen, ob die XML-Datei wirklich erzeugt wurde
- danach `ApplyAudit` erneut starten

### `ValidateConfig` funktioniert, aber `ApplyAudit` nicht

Dann liegt das Problem meist nicht an der JSON, sondern an einem der folgenden Punkte:

- PowerShell nicht als Administrator gestartet
- `Application Identity`-Dienst kann nicht gesetzt oder gestartet werden
- lokale Sicherheitsrichtlinie oder Domaenenrichtlinie blockiert den Vorgang
- Pfad zur XML-Datei ist ungueltig oder nicht erreichbar

Ein sinnvoller Schnellcheck ist:

```powershell
.\scripts\Invoke-AppLockerBaseline.ps1 -Mode GeneratePolicy -OutputPath .\out\applocker-preview.xml
Get-Service AppIDSvc
```

### Eine benoetigte Anwendung startet im Audit nicht sauber durch

Eventlog pruefen und entscheiden:

- liegt die Datei in einem legitimen Programmpfad, dann `allowedFiles` oder `allowedPaths` anpassen
- handelt es sich um einen signierten Updater, dann `allowedPublishers` erweitern

### Mein eigenes PowerShell-Skript wuerde im Audit verhindert werden

Das ist bei einer engeren Policy oft erwartbar, wenn das Skript aus einem Benutzerprofil oder Dokumente-Ordner gestartet wird.

Typische Optionen:

- das Admin-Skript bewusst ausserhalb des normalen Benutzerkontexts ausfuehren
- das Skript aus einem geeigneten Admin-/Tooling-Pfad starten
- nur echte Betriebssoftware freigeben, nicht automatisch das gesamte Admin-Arbeitsverzeichnis

### Administratoren werden unerwartet eingeschraenkt

Pruefen, ob versehentlich zu enge Freigaben fuer allgemeine Systempfade gesetzt wurden oder ob ein Admin mit einem normalen Benutzerkonto arbeitet. Die mitgelieferte Logik erzeugt zusaetzlich eine globale Admin-Freigabe.

### Eine Policy muss schnell dokumentiert oder verglichen werden

`ExportEffectivePolicy` verwenden und die XML sichern.

## Rueckbau und Notfallstrategie

Vor produktivem Rollout sollte immer ein lokaler Administratorzugang verfuegbar bleiben. Fuer kritische Systeme empfiehlt sich ausserdem:

- ein separater Wartungsaccount
- ein dokumentierter Vor-Ort-Zugang
- vorheriger Test auf einem baugleichen Geraet

### AppLocker komplett rueckgaengig machen

Laut Microsoft entfernst du eine lokale AppLocker-Policy, indem du eine leere XML-Policy setzt. Das in einer PowerShell mit Administratorrechten:

```powershell
@'
<AppLockerPolicy Version="1" />
'@ | Set-Content -Path .\clear.xml -Encoding utf8

Set-AppLockerPolicy -XmlPolicy .\clear.xml
sc.exe config appidsvc start= demand
sc.exe stop appidsvc
```

Optional kannst du danach noch die erzeugte `clear.xml` wieder loeschen:

```powershell
Remove-Item .\clear.xml
```

Hinweis:

- das entfernt die lokal gesetzte AppLocker-Policy auf diesem Rechner
- falls Richtlinien per `GPO` oder `MDM` ausgerollt wurden, muessen sie dort entfernt werden
- Microsoft weist darauf hin, dass lokale und zentral verteilte Policies getrennt behandelt werden
