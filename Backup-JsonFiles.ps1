# ============================================================
#  Backup-JsonFiles.ps1
#  Copies all .json files in a directory to a \Json_Backup subfolder.
#  Existing backups are timestamped to avoid overwriting.
# ============================================================

param (
    [string]$SourceDir = (Get-Location).Path   # Defaults to current directory
)

# ── Validate source directory ────────────────────────────────
if (-not (Test-Path -Path $SourceDir -PathType Container)) {
    Write-Error "Source directory not found: '$SourceDir'"
    exit 1
}

# ── Resolve paths ────────────────────────────────────────────
$SourceDir  = (Resolve-Path $SourceDir).Path
$BackupDir  = Join-Path $SourceDir "Json_Backup"

# ── Create backup folder if it doesn't exist ─────────────────
if (-not (Test-Path -Path $BackupDir)) {
    New-Item -ItemType Directory -Path $BackupDir | Out-Null
    Write-Host "Created backup folder: $BackupDir" -ForegroundColor Cyan
}

# ── Find JSON files (top-level only; change -Depth or add -Recurse if needed) ──
$JsonFiles = Get-ChildItem -Path $SourceDir -Filter "*.json" -File

if ($JsonFiles.Count -eq 0) {
    Write-Host "No .json files found in '$SourceDir'." -ForegroundColor Yellow
    exit 0
}

# ── Copy each file ───────────────────────────────────────────
$timestamp  = Get-Date -Format "yyyyMMdd_HHmmss"
$copied     = 0
$skipped    = 0

foreach ($file in $JsonFiles) {
    $destPath = Join-Path $BackupDir $file.Name

    # If a backup already exists, rename it with a timestamp before overwriting
    if (Test-Path -Path $destPath) {
        $baseName    = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        $archiveName = "${baseName}_${timestamp}.json"
        $archivePath = Join-Path $BackupDir $archiveName

        Rename-Item -Path $destPath -NewName $archiveName
        Write-Host "  Archived previous backup → $archiveName" -ForegroundColor DarkGray
    }

    try {
        Copy-Item -Path $file.FullName -Destination $destPath -ErrorAction Stop
        Write-Host "  Backed up: $($file.Name)" -ForegroundColor Green
        $copied++
    } catch {
        Write-Warning "  Failed to copy '$($file.Name)': $_"
        $skipped++
    }
}

# ── Summary ──────────────────────────────────────────────────
Write-Host ""
Write-Host "────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "Backup complete." -ForegroundColor Cyan
Write-Host "  Files backed up : $copied"
Write-Host "  Files skipped   : $skipped"
Write-Host "  Backup location : $BackupDir"
Write-Host "────────────────────────────────────────" -ForegroundColor DarkGray
