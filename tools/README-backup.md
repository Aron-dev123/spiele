# Backup der 20ab-Spielstände

Es gibt zwei Wege. Der normale ist der **Snapshot ins Repo** (unten zuerst beschrieben),
das JSON-Backup darunter läuft nur, wenn man es bewusst startet.

---

## 1. Snapshot als .txt im Repo (der übliche Weg)

`20ab-snapshot.ps1` schreibt den aktuellen Stand als lesbare Textdatei nach
`spielstaende/20ab-stand_<datum>_<uhrzeit>.txt` und wird dann committet. Dadurch liegt
jede Sicherung versioniert auf GitHub.

```powershell
powershell -ExecutionPolicy Bypass -File "C:\Users\aron\Documents\spiele\tools\20ab-snapshot.ps1"
```

Aufbau der Datei:

- **Teil 1 – Übersicht:** Bestenliste mit Kontoständen, Spiele/Siege/Runden je Spieler,
  Spieler-IDs und eine Liste aller Spiele mit Siegern und Endpunkten.
- **Teil 2 – Rohdaten:** der vollständige Datenbankinhalt als JSON. **Nur damit** ist ein
  echtes Wiederherstellen möglich; die Übersicht allein reicht dafür nicht.

Es werden automatisch die letzten **5** Snapshots behalten, ältere Dateien werden gelöscht
(`-Keep 10` für mehr). Auch dieses Skript ist rein lesend gegenüber der Datenbank.

> Hinweis: Das Repo ist öffentlich, und Git behält jede Version dauerhaft. Ein gelöschter
> Snapshot verschwindet aus dem aktuellen Stand, bleibt aber in der Git-Historie lesbar.

---

## 2. JSON-Backup (optional, läuft aktuell nicht automatisch)

### Was das Skript macht

`20ab-backup.ps1` holt den kompletten Datenstand (`registry`, `activeSessions`,
`liveGames`, `cardStates`, `lastSessionMovement`) per einzelnem HTTP-GET aus der
Firebase-Datenbank und legt ihn als JSON-Datei unter `backups/` ab.

**Das Skript schreibt nichts in die Datenbank.** Es enthält keinen einzigen
schreibenden Firebase-Aufruf — es kann die Spielstände also nicht verändern oder löschen.

Abgelegt wird:

- `backups/20ab_<datum>_<uhrzeit>.json` — eine neue Datei pro Änderung
- `backups/20ab_latest.json` — immer der zuletzt gesicherte Stand
- `backups/backup.log` — Protokoll aller Läufe

Alte Sicherungen werden **nie** gelöscht oder überschrieben.

## Schutzmechanismen

Damit ein fehlgeschlagener Lauf niemals ein gutes Backup zerstört:

| Fall | Verhalten |
|---|---|
| Server nicht erreichbar / Timeout | Bricht ab, schreibt nichts |
| HTTP-Status ≠ 200 | Bricht ab, schreibt nichts |
| Antwort leer oder `null` | Bricht ab, schreibt nichts |
| Antwort ist kein gültiges JSON | Bricht ab, schreibt nichts |
| Keine Spieler in der Antwort | Bricht ab, schreibt nichts |
| Inhalt identisch zum letzten Backup | Keine neue Datei (spart Platz) |
| Weniger Spieler/Spiele als zuvor | Schreibt als **neue** Datei, protokolliert `VERDAECHTIG` |

## Manuell ausführen

```powershell
powershell -ExecutionPolicy Bypass -File "C:\Users\aron\Documents\spiele\tools\20ab-backup.ps1"
```

## Automatisch stündlich laufen lassen

Einmalig einrichten (läuft danach dauerhaft im Hintergrund):

```powershell
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument '-ExecutionPolicy Bypass -WindowStyle Hidden -NonInteractive -File "C:\Users\aron\Documents\spiele\tools\20ab-backup.ps1"'
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddMinutes(5) -RepetitionInterval (New-TimeSpan -Hours 1)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
Register-ScheduledTask -TaskName "20ab Spielstand-Backup" -Action $action -Trigger $trigger -Settings $settings -Description "Liest stuendlich die 20ab-Spielstaende aus Firebase und legt sie lokal als JSON-Sicherung ab. Rein lesend." -Force
```

Status prüfen:

```powershell
Get-ScheduledTask -TaskName "20ab Spielstand-Backup" | Get-ScheduledTaskInfo
```

Wieder entfernen:

```powershell
Unregister-ScheduledTask -TaskName "20ab Spielstand-Backup" -Confirm:$false
```

## Wichtig: Backups gehören nicht ins Repo

Die Sicherungen enthalten echte Namen und Geldstände der Mitspieler. Das Repo ist über
GitHub Pages öffentlich, deshalb ist `backups/` in `.gitignore` eingetragen. Diesen Eintrag
bitte drin lassen.

## Im Notfall zurückspielen

Bewusst **kein** fertiges Restore-Skript — ein Zurückspielen überschreibt den aktuellen
Stand und soll nie versehentlich passieren. Vorgehen, wenn es wirklich nötig ist:

1. Erst den *aktuellen* Stand sichern (Snapshot einmal laufen lassen), damit es auch
   vom kaputten Zustand eine Kopie gibt.
2. Die gewünschte Sicherung heraussuchen und prüfen (Spielerzahl, Kontostände, Datum im
   Dateinamen): entweder ein `.txt` aus `spielstaende/` — dort den JSON-Block **unterhalb**
   der Zeile `ROHDATEN` verwenden — oder eine `.json` aus `backups/`.
3. In der Firebase-Konsole unter *Realtime Database* den Knoten `20ab` auswählen und über
   *JSON importieren* die Datei einspielen — oder gezielt einzelne Teilknoten
   (z. B. nur `registry`) ersetzen, statt alles zu überschreiben.

Am besten vorher kurz Bescheid geben, dann kann das gemeinsam gemacht werden.
