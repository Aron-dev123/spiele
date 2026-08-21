<#
    20ab-backup.ps1 - Sicherung der Spielstaende aus der Firebase-Datenbank.

    WICHTIG: Dieses Skript liest AUSSCHLIESSLICH. Es macht genau einen HTTP-GET auf die
    Datenbank und schreibt das Ergebnis in eine lokale Datei. Es gibt hier bewusst KEINEN
    einzigen schreibenden Zugriff auf Firebase - das Skript kann die Spielstaende also
    grundsaetzlich nicht veraendern oder loeschen.

    Sicherheitsnetze gegen "kaputtes Backup ueberschreibt gutes Backup":
      - Ein leerer oder fehlerhafter Download wird verworfen (kein Schreiben).
      - Die Antwort muss gueltiges JSON sein und eine nicht-leere registry enthalten.
      - Faellt die Spielerzahl gegenueber dem letzten Backup stark ab, wird die Sicherung
        zwar trotzdem geschrieben, aber deutlich als VERDAECHTIG protokolliert - alte
        Sicherungen bleiben dabei immer unangetastet (es wird nie eine geloescht).
      - Ist der Inhalt identisch zum letzten Backup, wird keine neue Datei angelegt.

    Aufruf: powershell -ExecutionPolicy Bypass -File "<Pfad>\20ab-backup.ps1"
#>

$ErrorActionPreference = "Stop"

$DbUrl      = "https://schaefer-games-default-rtdb.europe-west1.firebasedatabase.app/20ab.json"
$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$BackupDir  = Join-Path (Split-Path -Parent $ScriptDir) "backups"
$LatestFile = Join-Path $BackupDir "20ab_latest.json"
$LogFile    = Join-Path $BackupDir "backup.log"

function Write-Log([string]$Level, [string]$Message) {
    $line = ("{0}  [{1}]  {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message)
    Write-Output $line
    try { Add-Content -Path $LogFile -Value $line -Encoding utf8 } catch { }
}

function Get-Sha256([string]$Text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join "")
    } finally { $sha.Dispose() }
}

if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null }

# ---- 1. Daten holen (nur lesen) -------------------------------------------------------
try {
    $response = Invoke-WebRequest -Uri $DbUrl -UseBasicParsing -TimeoutSec 60
} catch {
    Write-Log "FEHLER" ("Download fehlgeschlagen, es wird nichts geschrieben: " + $_.Exception.Message)
    exit 1
}

if ($response.StatusCode -ne 200) {
    Write-Log "FEHLER" ("Unerwarteter HTTP-Status " + $response.StatusCode + " - es wird nichts geschrieben.")
    exit 1
}

$content = $response.Content
if ([string]::IsNullOrWhiteSpace($content) -or $content.Trim() -eq "null") {
    Write-Log "FEHLER" "Antwort war leer bzw. 'null' - es wird nichts geschrieben."
    exit 1
}

# ---- 2. Inhalt pruefen, bevor irgendetwas gespeichert wird -----------------------------
try {
    $data = $content | ConvertFrom-Json
} catch {
    Write-Log "FEHLER" "Antwort ist kein gueltiges JSON - es wird nichts geschrieben."
    exit 1
}

$registry = $data.registry
$playerCount = @($registry).Count
if ($null -eq $registry -or $playerCount -eq 0) {
    Write-Log "FEHLER" "Keine Spieler in der Antwort enthalten - es wird nichts geschrieben."
    exit 1
}

$gameCount = 0
foreach ($p in @($registry)) { if ($p.games) { $gameCount += @($p.games).Count } }

# ---- 3. Mit dem letzten Backup vergleichen --------------------------------------------
$hash = Get-Sha256 $content
if (Test-Path $LatestFile) {
    $previous = [System.IO.File]::ReadAllText($LatestFile)
    if ((Get-Sha256 $previous) -eq $hash) {
        Write-Log "OK" ("Unveraendert seit dem letzten Backup ({0} Spieler, {1} Spiel-Eintraege) - keine neue Datei noetig." -f $playerCount, $gameCount)
        exit 0
    }
    try {
        $prevData = $previous | ConvertFrom-Json
        $prevPlayers = @($prevData.registry).Count
        $prevGames = 0
        foreach ($p in @($prevData.registry)) { if ($p.games) { $prevGames += @($p.games).Count } }
        if ($playerCount -lt $prevPlayers -or $gameCount -lt $prevGames) {
            Write-Log "VERDAECHTIG" ("Datenbestand ist KLEINER als zuvor: Spieler {0} -> {1}, Spiele {2} -> {3}. Die Sicherung wird trotzdem als neue Datei abgelegt; alte Sicherungen bleiben erhalten." -f $prevPlayers, $playerCount, $prevGames, $gameCount)
        }
    } catch {
        Write-Log "WARNUNG" "Letztes Backup liess sich nicht zum Vergleich lesen - fahre trotzdem fort."
    }
}

# ---- 4. Schreiben (immer als NEUE Datei, es wird nie eine alte geloescht) ---------------
$stamp    = Get-Date -Format "yyyy-MM-dd_HHmmss"
$outFile  = Join-Path $BackupDir ("20ab_" + $stamp + ".json")
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($outFile, $content, $utf8NoBom)
[System.IO.File]::WriteAllText($LatestFile, $content, $utf8NoBom)

$sizeKb = [math]::Round(((Get-Item $outFile).Length / 1KB), 1)
Write-Log "OK" ("Backup geschrieben: {0} ({1} KB, {2} Spieler, {3} Spiel-Eintraege)" -f (Split-Path -Leaf $outFile), $sizeKb, $playerCount, $gameCount)
exit 0
