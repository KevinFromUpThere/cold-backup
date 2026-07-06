#Requires -Version 5.1

<#
.SYNOPSIS
    Cold backup manager for media libraries using rotating hard drives.

.DESCRIPTION
    Maintains a SQLite index of all media files and copies unarchived
    files to drives labeled OFFLINE_XX as they are inserted into the cradle.

.EXAMPLE
    .\cold-backup.ps1 scan              # Index all source libraries
    .\cold-backup.ps1 backup            # Copy unarchived files to connected drives
    .\cold-backup.ps1 status            # Show backup progress and stats
    .\cold-backup.ps1 search "Avatar"   # Find a file or show
    .\cold-backup.ps1 drives            # List connected backup drives
    .\cold-backup.ps1 init-drive G:     # Format and label a new blank drive
    .\cold-backup.ps1 verify            # Check that archived files still exist on drives
#>

param(
    [Parameter(Position = 0)]
    [ValidateSet('scan', 'backup', 'status', 'search', 'drives', 'init-drive', 'verify')]
    [string]$Command = 'status',

    [Parameter(Position = 1, ValueFromRemainingArguments)]
    [string[]]$Arguments
)

# ── Configuration ─────────────────────────────────────────────────────────────
# Database is stored on your local machine, not on the backup drives.
$script:DbPath      = "$env:USERPROFILE\cold-backup\backup-index.db"
$script:DrivePrefix = 'OFFLINE_'
$script:BufferBytes = 10GB  # Keep this much free on each drive (safety margin)

# Source libraries — mapped from your docker-compose volume paths to Windows drive letters.
# Adjust drive letters if your media drives mount differently on this machine.
$script:Libraries = @(
    [PSCustomObject]@{ Path = 'T:\Kevflix_8TB_Internal_01\TV';    Type = 'TV';    Label = 'tv1_T'     }
    [PSCustomObject]@{ Path = 'H:\8TB_2_Media\TV';                Type = 'TV';    Label = 'tv2_H'     }
    [PSCustomObject]@{ Path = 'F:\KevFlix\TV Shows';              Type = 'TV';    Label = 'tv3_F'     }
    [PSCustomObject]@{ Path = 'E:\Media Overspill\TV Shows';      Type = 'TV';    Label = 'tv4_E'     }
    [PSCustomObject]@{ Path = 'T:\Kevflix_8TB_Internal_01\Movies'; Type = 'Movie'; Label = 'movies1_T' }
    [PSCustomObject]@{ Path = 'H:\8TB_2_Media\Movies';            Type = 'Movie'; Label = 'movies2_H' }
    [PSCustomObject]@{ Path = 'F:\KevFlix\Movies';                Type = 'Movie'; Label = 'movies3_F' }
    [PSCustomObject]@{ Path = 'E:\Media Overspill\Movies';        Type = 'Movie'; Label = 'movies4_E' }
    [PSCustomObject]@{ Path = 'T:\Kevflix_8TB_Internal_01\Music'; Type = 'Music'; Label = 'music1_T'  }
    [PSCustomObject]@{ Path = 'H:\8TB_2_Media\MP3';               Type = 'Music'; Label = 'music2_H'  }
)


# ── Module check ──────────────────────────────────────────────────────────────
function Require-PSSQLite {
    if (-not (Get-Module -ListAvailable -Name PSSQLite)) {
        Write-Host 'PSSQLite module not found. Installing from PSGallery (no admin needed)...' -ForegroundColor Yellow
        try {
            Install-Module PSSQLite -Scope CurrentUser -Force -ErrorAction Stop
            Write-Host 'PSSQLite installed.' -ForegroundColor Green
        } catch {
            Write-Error "Failed to install PSSQLite: $_`nRun manually: Install-Module PSSQLite -Scope CurrentUser"
            exit 1
        }
    }
    Import-Module PSSQLite -DisableNameChecking -ErrorAction Stop
}


# ── Database init ─────────────────────────────────────────────────────────────
function Initialize-Database {
    $dir = Split-Path $script:DbPath -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    Invoke-SqliteQuery -DataSource $script:DbPath -Query @'
CREATE TABLE IF NOT EXISTS files (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    source_path TEXT    NOT NULL UNIQUE,
    filename    TEXT    NOT NULL,
    type        TEXT    NOT NULL,
    library     TEXT    NOT NULL,
    size_bytes  INTEGER NOT NULL DEFAULT 0,
    modified    TEXT    NOT NULL,
    archived    INTEGER NOT NULL DEFAULT 0,
    drive_label TEXT,
    drive_path  TEXT,
    archived_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_archived ON files(archived);
CREATE INDEX IF NOT EXISTS idx_type     ON files(type);
CREATE INDEX IF NOT EXISTS idx_filename ON files(filename);
CREATE INDEX IF NOT EXISTS idx_library  ON files(library);

CREATE TABLE IF NOT EXISTS drives (
    label       TEXT PRIMARY KEY,
    letter      TEXT,
    total_bytes INTEGER,
    first_used  TEXT,
    last_used   TEXT
);
'@
}


# ── Scan ──────────────────────────────────────────────────────────────────────
function Invoke-Scan {
    Write-Host "`nScanning source libraries..." -ForegroundColor Cyan

    $beforeCount = (Invoke-SqliteQuery -DataSource $script:DbPath -Query `
        'SELECT COUNT(*) AS c FROM files').c
    $totalFiles  = 0

    foreach ($lib in $script:Libraries) {
        if (-not (Test-Path $lib.Path)) {
            Write-Warning "  Skipping (not accessible): $($lib.Path)"
            continue
        }
        Write-Host "  [$($lib.Label)] $($lib.Path)" -ForegroundColor Gray

        $files         = Get-ChildItem -Path $lib.Path -Recurse -File -ErrorAction SilentlyContinue
        $batchCount    = 0
        $inTransaction = $false

        try {
            foreach ($f in $files) {
                $totalFiles++
                $batchCount++

                if (-not $inTransaction) {
                    Invoke-SqliteQuery -DataSource $script:DbPath -Query 'BEGIN TRANSACTION'
                    $inTransaction = $true
                }

                Invoke-SqliteQuery -DataSource $script:DbPath -Query @'
INSERT OR IGNORE INTO files (source_path, filename, type, library, size_bytes, modified)
VALUES (@p, @n, @t, @l, @s, @m)
'@ -SqlParameters @{
                    p = $f.FullName
                    n = $f.Name
                    t = $lib.Type
                    l = $lib.Label
                    s = $f.Length
                    m = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
                }

                if ($batchCount -ge 500) {
                    Invoke-SqliteQuery -DataSource $script:DbPath -Query 'COMMIT'
                    $inTransaction = $false
                    $batchCount    = 0
                    Write-Host "    $totalFiles files scanned..." -ForegroundColor DarkGray
                }
            }
            if ($inTransaction) {
                Invoke-SqliteQuery -DataSource $script:DbPath -Query 'COMMIT'
                $inTransaction = $false
            }
        } catch {
            if ($inTransaction) {
                Invoke-SqliteQuery -DataSource $script:DbPath -Query 'ROLLBACK' -ErrorAction SilentlyContinue
            }
            Write-Error "Error scanning $($lib.Path): $_"
        }
    }

    $afterCount = (Invoke-SqliteQuery -DataSource $script:DbPath -Query `
        'SELECT COUNT(*) AS c FROM files').c

    Write-Host ("`nScan complete: {0} files scanned, {1} new entries added." -f `
        $totalFiles, ($afterCount - $beforeCount)) -ForegroundColor Green
}


# ── Backup ────────────────────────────────────────────────────────────────────
function Start-Backup {
    $drives = @(Get-OfflineDrives)
    if ($drives.Count -eq 0) {
        Write-Warning "No $($script:DrivePrefix)* drives detected. Insert a backup drive and retry."
        Write-Host "Run '.\cold-backup.ps1 drives' to see connected drives." -ForegroundColor Gray
        return
    }

    Write-Host "`nConnected backup drives:" -ForegroundColor Cyan
    foreach ($d in $drives) {
        Write-Host ("  {0}  {1,-12}  {2:F1} GB free of {3:F1} GB" -f `
            $d.Letter, $d.Label, $d.FreeBytes / 1GB, $d.TotalBytes / 1GB)
    }

    $grandTotal = 0
    $grandBytes = 0

    foreach ($drive in $drives) {
        # Re-query each drive pass so newly archived files are excluded
        $pending = @(Invoke-SqliteQuery -DataSource $script:DbPath -Query `
            'SELECT * FROM files WHERE archived = 0 ORDER BY type, size_bytes DESC')

        if ($pending.Count -eq 0) {
            Write-Host "`nAll files are archived — nothing left to copy!" -ForegroundColor Green
            return
        }

        $pendingGB = ($pending | Measure-Object -Property size_bytes -Sum).Sum / 1GB
        Write-Host ("`nCopying to {0} ({1})  — {2:F1} GB free, {3} pending files ({4:F1} GB)..." -f `
            $drive.Letter, $drive.Label, $drive.FreeBytes / 1GB, $pending.Count, $pendingGB) -ForegroundColor Cyan

        # Register drive in index
        Invoke-SqliteQuery -DataSource $script:DbPath -Query @'
INSERT INTO drives (label, letter, total_bytes, first_used, last_used)
VALUES (@label, @letter, @total, datetime('now'), datetime('now'))
ON CONFLICT(label) DO UPDATE SET letter = excluded.letter, last_used = excluded.last_used
'@ -SqlParameters @{ label = $drive.Label; letter = $drive.Letter; total = $drive.TotalBytes }

        $driveCopied = 0
        $driveBytes  = 0

        foreach ($file in $pending) {
            # Refresh free space every file (cheap, avoids over-filling)
            $vol = Get-Volume -DriveLetter $drive.Letter.TrimEnd(':') -ErrorAction SilentlyContinue
            if (-not $vol) { Write-Warning "Lost drive $($drive.Letter). Skipping remaining files for this drive."; break }

            if ($vol.SizeRemaining - $file.size_bytes -lt $script:BufferBytes) {
                Write-Host ("  Drive full (keeping {0} GB buffer). Moving to next drive." -f `
                    [math]::Round($script:BufferBytes / 1GB, 0)) -ForegroundColor Yellow
                break
            }

            if (-not (Test-Path -LiteralPath $file.source_path)) {
                Write-Warning "  Source missing, skipping: $($file.source_path)"
                continue
            }

            $lib = $script:Libraries | Where-Object { $_.Label -eq $file.library } | Select-Object -First 1
            if (-not $lib) {
                Write-Warning "  Unknown library '$($file.library)', skipping $($file.filename)"
                continue
            }

            $rel     = $file.source_path.Substring($lib.Path.Length).TrimStart('\/')
            $destDir = Join-Path "$($drive.Letter)\$($file.type)" (Split-Path $rel -Parent)
            $dest    = Join-Path $destDir $file.filename

            try {
                if (-not (Test-Path $destDir)) {
                    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
                }
                Copy-Item -LiteralPath $file.source_path -Destination $dest -Force -ErrorAction Stop

                Invoke-SqliteQuery -DataSource $script:DbPath -Query @'
UPDATE files
SET archived = 1, drive_label = @label, drive_path = @path, archived_at = datetime('now')
WHERE id = @id
'@ -SqlParameters @{ label = $drive.Label; path = $dest; id = $file.id }

                $driveCopied++
                $driveBytes += $file.size_bytes
                $grandTotal++
                $grandBytes += $file.size_bytes

                if ($driveCopied % 25 -eq 0) {
                    Write-Host ("    {0} files | {1:F2} GB copied to this drive" -f `
                        $driveCopied, $driveBytes / 1GB) -ForegroundColor DarkGray
                }
            } catch {
                Write-Warning "  Failed to copy $($file.filename): $_"
            }
        }

        Write-Host ("  Done with {0}: {1} files, {2:F2} GB written." -f `
            $drive.Label, $driveCopied, $driveBytes / 1GB) -ForegroundColor Green
    }

    Write-Host ("`nSession complete: {0} files, {1:F2} GB archived." -f `
        $grandTotal, $grandBytes / 1GB) -ForegroundColor Cyan

    # Show what's still pending after this session
    $rem = Invoke-SqliteQuery -DataSource $script:DbPath -Query `
        'SELECT COUNT(*) AS c, SUM(size_bytes) AS s FROM files WHERE archived = 0'
    if ($rem.c -gt 0) {
        $remBytes = if ($rem.s) { $rem.s } else { 0 }
        Write-Host ("Still pending: {0} files ({1:F1} GB) — insert more drives to continue." -f `
            $rem.c, $remBytes / 1GB) -ForegroundColor Yellow
    }
}


# ── Status ────────────────────────────────────────────────────────────────────
function Show-Status {
    $rows = @(Invoke-SqliteQuery -DataSource $script:DbPath -Query @'
SELECT
    type,
    COUNT(*)                                           AS total,
    SUM(CASE WHEN archived = 1 THEN 1    ELSE 0 END)  AS backed_up,
    SUM(size_bytes)                                    AS total_bytes,
    SUM(CASE WHEN archived = 1 THEN size_bytes END)    AS backed_bytes
FROM files
GROUP BY type
ORDER BY type
'@)

    if ($rows.Count -eq 0) {
        Write-Host "Index is empty. Run: .\cold-backup.ps1 scan" -ForegroundColor Yellow
        return
    }

    Write-Host "`n=== Cold Backup Status ===" -ForegroundColor Cyan
    Write-Host ("{0,-8}  {1,7}  {2,10}  {3,9}  {4,10}" -f 'Type', 'Files', 'Total', 'Backed %', 'Backed')
    Write-Host ('-' * 54)

    foreach ($r in $rows) {
        $pct     = if ($r.total -gt 0) { [int]($r.backed_up / $r.total * 100) } else { 0 }
        $backed  = if ($r.backed_bytes) { $r.backed_bytes } else { 0 }
        Write-Host ("{0,-8}  {1,7}  {2,9:F1}G  {3,7}%    {4,9:F1}G" -f `
            $r.type, $r.total, $r.total_bytes / 1GB, $pct, $backed / 1GB)
    }

    $rem = Invoke-SqliteQuery -DataSource $script:DbPath -Query `
        'SELECT COUNT(*) AS c, SUM(size_bytes) AS s FROM files WHERE archived = 0'
    $remBytes = if ($rem.s) { $rem.s } else { 0 }
    Write-Host ('-' * 54)
    Write-Host ("Remaining : {0,7} files  {1:F1} GB" -f $rem.c, $remBytes / 1GB) -ForegroundColor Yellow

    $drives = @(Invoke-SqliteQuery -DataSource $script:DbPath -Query 'SELECT * FROM drives ORDER BY label')
    if ($drives.Count -gt 0) {
        Write-Host "`n=== Drives in Index ===" -ForegroundColor Cyan
        foreach ($d in $drives) {
            $count = (Invoke-SqliteQuery -DataSource $script:DbPath -Query `
                'SELECT COUNT(*) AS c FROM files WHERE drive_label = @l' `
                -SqlParameters @{ l = $d.label }).c
            Write-Host ("  {0,-12}  last on {1}  {2} files  first: {3}" -f `
                $d.label, $d.letter, $count, $d.first_used)
        }
    }
    Write-Host ""
}


# ── Search ────────────────────────────────────────────────────────────────────
function Search-Files {
    param([string]$Query)

    if (-not $Query) {
        Write-Warning 'Usage: .\cold-backup.ps1 search "search term"'
        return
    }

    $results = @(Invoke-SqliteQuery -DataSource $script:DbPath -Query @'
SELECT filename, type, library, size_bytes, archived, drive_label, drive_path, source_path
FROM files
WHERE filename LIKE @q OR source_path LIKE @q
ORDER BY type, filename
LIMIT 100
'@ -SqlParameters @{ q = "%$Query%" })

    if ($results.Count -eq 0) {
        Write-Host "No results for '$Query'." -ForegroundColor Yellow
        return
    }

    $label = if ($results.Count -eq 100) { '100+ matches (showing first 100)' } else { "$($results.Count) match$(if($results.Count -ne 1){'es'})" }
    Write-Host "`nSearch: '$Query'  ($label)`n" -ForegroundColor Cyan

    foreach ($r in $results) {
        $sizeMB = [math]::Round($r.size_bytes / 1MB, 1)
        if ($r.archived) {
            Write-Host "  [OK] $($r.filename)  [$($r.type)]  ${sizeMB} MB" -ForegroundColor Green
            Write-Host "       Drive: $($r.drive_label)  →  $($r.drive_path)" -ForegroundColor DarkGray
        } else {
            Write-Host "  [--] $($r.filename)  [$($r.type)]  ${sizeMB} MB  NOT BACKED UP" -ForegroundColor Yellow
            Write-Host "       Source: $($r.source_path)" -ForegroundColor DarkGray
        }
    }
    Write-Host ""
}


# ── Drive helpers ─────────────────────────────────────────────────────────────
function Get-OfflineDrives {
    Get-Volume |
        Where-Object { $_.FileSystemLabel -like "$($script:DrivePrefix)*" -and $_.DriveLetter } |
        Sort-Object FileSystemLabel |
        ForEach-Object {
            [PSCustomObject]@{
                Label      = $_.FileSystemLabel
                Letter     = "$($_.DriveLetter):"
                TotalBytes = $_.Size
                FreeBytes  = $_.SizeRemaining
            }
        }
}

function Show-Drives {
    $drives = @(Get-OfflineDrives)

    if ($drives.Count -eq 0) {
        Write-Host "No $($script:DrivePrefix)* drives connected." -ForegroundColor Yellow
        Write-Host "Insert a formatted drive labeled OFFLINE_XX or run '.\cold-backup.ps1 init-drive <letter>'." -ForegroundColor Gray
        return
    }

    Write-Host "`n=== Connected Backup Drives ===" -ForegroundColor Cyan
    foreach ($d in $drives) {
        $used = $d.TotalBytes - $d.FreeBytes
        $pct  = if ($d.TotalBytes -gt 0) { [int]($used / $d.TotalBytes * 100) } else { 0 }
        $fill = [int]($pct / 5)
        $bar  = ('#' * $fill) + ('.' * (20 - $fill))
        Write-Host ("  {0}  {1,-12}  [{2}] {3,3}%  {4:F1}/{5:F1} GB" -f `
            $d.Letter, $d.Label, $bar, $pct, $used / 1GB, $d.TotalBytes / 1GB)
    }
    Write-Host ""
}


# ── Init drive ────────────────────────────────────────────────────────────────
function Initialize-BackupDrive {
    param([string]$DriveLetter)

    if (-not $DriveLetter) {
        Write-Warning 'Usage: .\cold-backup.ps1 init-drive <letter>  e.g.  init-drive G:'
        return
    }

    $letter = $DriveLetter.TrimEnd(':').ToUpper()
    $vol    = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
    if (-not $vol) { Write-Error "Drive $letter`: not found."; return }

    # Find the highest OFFLINE_ number already in use (drives + DB)
    $liveNums = @(Get-Volume |
        Where-Object { $_.FileSystemLabel -like "$($script:DrivePrefix)*" } |
        ForEach-Object { [int]($_.FileSystemLabel -replace '\D+', '') })

    $dbNums = @(Invoke-SqliteQuery -DataSource $script:DbPath -Query 'SELECT label FROM drives' |
        ForEach-Object { [int]($_.label -replace '\D+', '') })

    $allNums = @($liveNums + $dbNums) | Where-Object { $_ -gt 0 }
    $maxNum  = if ($allNums) { ($allNums | Measure-Object -Maximum).Maximum } else { 0 }
    $newNum  = $maxNum + 1
    $newLabel = "$($script:DrivePrefix){0:D2}" -f $newNum

    Write-Host "`nDrive $letter`: — current label: '$($vol.FileSystemLabel)'  size: $([math]::Round($vol.Size/1GB,1)) GB" -ForegroundColor Yellow
    Write-Host "Proposed new label: $newLabel" -ForegroundColor Cyan
    Write-Host "`n*** ALL DATA ON $letter`: WILL BE ERASED. ***" -ForegroundColor Red
    $confirm = Read-Host "Type '$newLabel' to confirm format, or press Enter to cancel"

    if ($confirm -ne $newLabel) { Write-Host "Cancelled." -ForegroundColor Gray; return }

    Format-Volume -DriveLetter $letter -FileSystem NTFS -NewFileSystemLabel $newLabel `
        -Confirm:$false -Force -ErrorAction Stop

    Write-Host "`nDrive $letter`: formatted as NTFS and labeled '$newLabel'. Ready for backup." -ForegroundColor Green
}


# ── Verify ────────────────────────────────────────────────────────────────────
function Invoke-Verify {
    $drives = @(Get-OfflineDrives)
    if ($drives.Count -eq 0) {
        Write-Warning "No OFFLINE_ drives connected. Insert drives to verify."
        return
    }

    $driveLabels = $drives.Label
    Write-Host "`nVerifying files on: $($driveLabels -join ', ')..." -ForegroundColor Cyan

    $archived = @(Invoke-SqliteQuery -DataSource $script:DbPath -Query @'
SELECT id, filename, size_bytes, drive_label, drive_path
FROM files
WHERE archived = 1 AND drive_label IN (SELECT label FROM drives)
'@)

    # Filter to only files on currently connected drives
    $toCheck = @($archived | Where-Object { $driveLabels -contains $_.drive_label })

    if ($toCheck.Count -eq 0) {
        Write-Host "No archived files found for connected drives." -ForegroundColor Yellow
        return
    }

    Write-Host "Checking $($toCheck.Count) files..." -ForegroundColor Gray
    $ok       = 0
    $missing  = 0
    $wrong    = 0
    $checked  = 0

    foreach ($f in $toCheck) {
        $checked++
        if ($checked % 100 -eq 0) { Write-Host "  $checked / $($toCheck.Count)..." -ForegroundColor DarkGray }

        if (-not (Test-Path -LiteralPath $f.drive_path)) {
            Write-Warning "  MISSING: $($f.drive_path)"
            $missing++
            continue
        }

        $actual = (Get-Item -LiteralPath $f.drive_path).Length
        if ($actual -ne $f.size_bytes) {
            Write-Warning ("  SIZE MISMATCH: {0}  expected {1} bytes, got {2}" -f `
                $f.drive_path, $f.size_bytes, $actual)
            $wrong++
        } else {
            $ok++
        }
    }

    Write-Host ("`nVerify complete: {0} OK  {1} missing  {2} size mismatch" -f $ok, $missing, $wrong) -ForegroundColor Cyan
    if ($missing -gt 0 -or $wrong -gt 0) {
        Write-Host "Run 'backup' to re-copy any problem files." -ForegroundColor Yellow
    }
}


# ── Entry point ───────────────────────────────────────────────────────────────
Require-PSSQLite
Initialize-Database

switch ($Command) {
    'scan'       { Invoke-Scan }
    'backup'     { Start-Backup }
    'status'     { Show-Status }
    'search'     { Search-Files -Query ($Arguments -join ' ') }
    'drives'     { Show-Drives }
    'init-drive' { Initialize-BackupDrive -DriveLetter ($Arguments | Select-Object -First 1) }
    'verify'     { Invoke-Verify }
    default      { Show-Status }
}
