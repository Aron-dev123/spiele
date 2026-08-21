<#
    20ab-snapshot.ps1 - Erzeugt eine lesbare Sicherungs-Textdatei der Spielstaende.

    Rein lesend: genau ein HTTP-GET auf die Datenbank, danach wird nur eine lokale
    Textdatei geschrieben. Kein schreibender Firebase-Zugriff.

    Aufbau der Datei:
      Teil 1  Lesbare Uebersicht (Kontostaende, Spiele, Auszeichnungen je Spieler)
      Teil 2  Vollstaendiger Rohdaten-Block als JSON - nur damit ist ein echtes
              Wiederherstellen moeglich, die Uebersicht allein reicht dafuer nicht.

    Parameter:
      -OutDir  Zielordner (Standard: <repo>\spielstaende)
      -Keep    Wieviele Snapshots behalten werden (Standard: 5, aeltere werden geloescht)
#>

param(
    [string]$OutDir,
    [int]$Keep = 5
)

$ErrorActionPreference = "Stop"

$DbUrl     = "https://schaefer-games-default-rtdb.europe-west1.firebasedatabase.app/20ab.json"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoDir   = Split-Path -Parent $ScriptDir
if (-not $OutDir) { $OutDir = Join-Path $RepoDir "spielstaende" }

# ---- Daten holen (nur lesen) + pruefen -------------------------------------------------
try {
    $response = Invoke-WebRequest -Uri $DbUrl -UseBasicParsing -TimeoutSec 60
} catch {
    Write-Output ("FEHLER: Download fehlgeschlagen, es wird nichts geschrieben: " + $_.Exception.Message)
    exit 1
}
if ($response.StatusCode -ne 200) {
    Write-Output ("FEHLER: HTTP-Status " + $response.StatusCode + " - es wird nichts geschrieben.")
    exit 1
}
$raw = $response.Content
if ([string]::IsNullOrWhiteSpace($raw) -or $raw.Trim() -eq "null") {
    Write-Output "FEHLER: Antwort war leer bzw. 'null' - es wird nichts geschrieben."
    exit 1
}
try { $data = $raw | ConvertFrom-Json } catch {
    Write-Output "FEHLER: Antwort ist kein gueltiges JSON - es wird nichts geschrieben."
    exit 1
}
$registry = @($data.registry)
if ($registry.Count -eq 0) {
    Write-Output "FEHLER: Keine Spieler in der Antwort - es wird nichts geschrieben."
    exit 1
}

# ---- Kennzahlen je Spieler aus der Spielhistorie ableiten -------------------------------
$rows = @()
$allGameIds = @{}
foreach ($p in $registry) {
    # Doppeltes @(...) ist Absicht: eine Pipeline mit genau EINEM Treffer liefert sonst ein
    # Einzelobjekt statt eines Arrays und .Count bleibt leer.
    $games = @(@($p.games) | Where-Object { $_ -and -not $_.deleted })
    foreach ($g in $games) { $allGameIds[$g.id] = $g.timestamp }
    $won = @($games | Where-Object { $_.won }).Count
    $rounds = 0
    foreach ($g in $games) { $rounds += @($g.rounds).Count }
    $best = $null
    if ($games.Count -gt 0) { $best = ($games | Measure-Object -Property moneyDelta -Maximum).Maximum }
    $rows += [pscustomobject]@{
        Name    = $p.name
        Id      = $p.id
        Stamm   = if ($p.stammSpieler) { "Stamm" } else { "Gast" }
        Saldo   = [math]::Round(([double]$p.session.balance), 2)
        Spiele  = $games.Count
        Siege   = $won
        Runden  = $rounds
        BestGew = if ($null -ne $best) { [math]::Round(([double]$best), 2) } else { 0 }
    }
}
$sorted = $rows | Sort-Object -Property Saldo -Descending

$sb = New-Object System.Text.StringBuilder
function Add-Line([string]$s) { [void]$sb.AppendLine($s) }

Add-Line "==============================================================================="
Add-Line " 20 AB - SICHERUNG DER SPIELSTAENDE"
Add-Line "==============================================================================="
Add-Line ("Erstellt am      : " + (Get-Date -Format "dd.MM.yyyy HH:mm:ss"))
Add-Line ("Quelle           : " + $DbUrl)
Add-Line ("Spieler          : " + $registry.Count)
Add-Line ("Spiele (gesamt)  : " + $allGameIds.Count)
$stamps = @($allGameIds.Values | Sort-Object)
if ($stamps.Count -gt 0) {
    Add-Line ("Aeltestes Spiel  : " + ([datetime]$stamps[0]).ToString("dd.MM.yyyy HH:mm"))
    Add-Line ("Neuestes Spiel   : " + ([datetime]$stamps[$stamps.Count-1]).ToString("dd.MM.yyyy HH:mm"))
}
Add-Line ""
Add-Line "-------------------------------------------------------------------------------"
Add-Line " BESTENLISTE / KONTOSTAENDE"
Add-Line "-------------------------------------------------------------------------------"
Add-Line ("{0,-4} {1,-12} {2,-6} {3,10} {4,7} {5,7} {6,7} {7,10}" -f "#", "Name", "Typ", "Saldo EUR", "Spiele", "Siege", "Runden", "BestesSp.")
$i = 1
foreach ($r in $sorted) {
    Add-Line ("{0,-4} {1,-12} {2,-6} {3,10} {4,7} {5,7} {6,7} {7,10}" -f $i, $r.Name, $r.Stamm, $r.Saldo, $r.Spiele, $r.Siege, $r.Runden, $r.BestGew)
    $i++
}
Add-Line ""
Add-Line "-------------------------------------------------------------------------------"
Add-Line " SPIELER-IDS (fuer die Zuordnung beim Wiederherstellen)"
Add-Line "-------------------------------------------------------------------------------"
foreach ($r in ($rows | Sort-Object Name)) { Add-Line ("{0,-14} {1}" -f $r.Name, $r.Id) }
Add-Line ""
Add-Line "-------------------------------------------------------------------------------"
Add-Line " EINZELNE SPIELE (neueste zuerst)"
Add-Line "-------------------------------------------------------------------------------"
$games = @()
foreach ($p in $registry) {
    foreach ($g in @($p.games)) {
        if ($g -and -not $g.deleted -and @($games | Where-Object { $_.id -eq $g.id }).Count -eq 0) { $games += $g }
    }
}
foreach ($g in ($games | Sort-Object { [datetime]$_.timestamp } -Descending)) {
    $namen = @($g.players | ForEach-Object { $_.name }) -join ", "
    $sieger = @()
    for ($k = 0; $k -lt @($g.players).Count; $k++) {
        if (@($g.winnerIndices) -contains $k) { $sieger += @($g.players)[$k].name }
    }
    $punkte = @($g.finalScores) -join " / "
    Add-Line ("{0}  Runden: {1,2}  Sieger: {2}" -f ([datetime]$g.timestamp).ToString("dd.MM.yyyy HH:mm"), @($g.rounds).Count, ($sieger -join " + "))
    Add-Line ("    Spieler: {0}" -f $namen)
    Add-Line ("    Endpunkte: {0}" -f $punkte)
}
Add-Line ""
Add-Line "==============================================================================="
Add-Line " ROHDATEN - vollstaendiger Datenbankinhalt als JSON"
Add-Line ""
Add-Line " NUR dieser Block erlaubt ein echtes Wiederherstellen. Die Uebersicht oben ist"
Add-Line " zum Nachschauen gedacht und reicht dafuer NICHT aus. Zum Zurueckspielen den"
Add-Line " kompletten JSON-Block unterhalb der naechsten Zeile verwenden."
Add-Line "==============================================================================="
Add-Line $raw

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$stamp   = Get-Date -Format "yyyy-MM-dd_HHmm"
$outFile = Join-Path $OutDir ("20ab-stand_" + $stamp + ".txt")
[System.IO.File]::WriteAllText($outFile, $sb.ToString(), (New-Object System.Text.UTF8Encoding $false))

$sizeKb = [math]::Round(((Get-Item $outFile).Length / 1KB), 1)
Write-Output ("Snapshot geschrieben: {0} ({1} KB, {2} Spieler, {3} Spiele)" -f (Split-Path -Leaf $outFile), $sizeKb, $registry.Count, $allGameIds.Count)

# ---- Alte Snapshots aufraeumen (nur die eigenen Dateien dieses Musters) -----------------
$all = @(Get-ChildItem -Path $OutDir -Filter "20ab-stand_*.txt" | Sort-Object Name -Descending)
if ($all.Count -gt $Keep) {
    foreach ($old in $all[$Keep..($all.Count-1)]) {
        Remove-Item $old.FullName -Force
        Write-Output ("Alten Snapshot entfernt: " + $old.Name)
    }
}
Write-Output ("Vorhandene Snapshots: " + (@(Get-ChildItem -Path $OutDir -Filter "20ab-stand_*.txt").Count) + " (max. " + $Keep + ")")
