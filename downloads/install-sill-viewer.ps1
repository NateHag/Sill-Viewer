# Installs Sill Viewer for Windows and keeps it up to date from GitHub.
#
#   First time (PowerShell):
#     $f="$env:TEMP\install-sill-viewer.ps1"
#     iwr https://raw.githubusercontent.com/NateHag/Sill-Viewer/main/downloads/install-sill-viewer.ps1 -OutFile $f
#     powershell -ExecutionPolicy Bypass -File $f
#
# It installs to %LOCALAPPDATA%\Programs\SillViewer, adds "Sill Viewer" to the Start menu, and adds
# a scheduled task, "Sill Viewer Update", that checks every hour. A running viewer is restarted
# only when there is a new version. -Update is what the task runs; -Uninstall removes the task.
param([switch]$Update, [switch]$Force, [switch]$Uninstall)

$ErrorActionPreference = "Stop"
$Repo = "NateHag/Sill-Viewer"
$Dir = Join-Path $env:LOCALAPPDATA "Programs\SillViewer"
$State = Join-Path $Dir "installed-commit.txt"
$Self = Join-Path $Dir "update.ps1"
$Log = Join-Path $Dir "update.log"
$Task = "Sill Viewer Update"
$Exe = Join-Path $Dir "Sill Viewer.exe"

function Say($text) {
    $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $text
    if (-not $Update) { Write-Host $text }
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    Add-Content -Path $Log -Value $line
}

if ($Uninstall) {
    schtasks /Delete /TN $Task /F 2>$null | Out-Null
    Write-Host "The hourly update check is off. The viewer stays in $Dir."
    exit 0
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
try {
    # The commit as JSON: Windows PowerShell hands back other answer types as raw bytes.
    $sha = [string](Invoke-RestMethod -UseBasicParsing -Headers @{ "User-Agent" = "SillViewer-updater" } `
            -Uri "https://api.github.com/repos/$Repo/commits/main?per_page=1").sha
} catch {
    Say "Could not ask GitHub for the newest version: $($_.Exception.Message)"
    exit 0
}
if ($sha -notmatch '^[0-9a-f]{40}$') { Say "Unexpected answer from GitHub."; exit 0 }

$installed = if (Test-Path $State) { (Get-Content $State -Raw).Trim() } else { "" }

# The zip by commit, not by branch: GitHub's cache could hand out an older file for a few minutes.
$tmp = Join-Path $env:TEMP ("sillviewer-" + [guid]::NewGuid())
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
    $newer = $Force -or ($sha -ne $installed) -or -not (Test-Path $Exe)
    if ($newer) {
        $zip = Join-Path $tmp "viewer.zip"
        Invoke-WebRequest -UseBasicParsing -OutFile $zip -Uri "https://raw.githubusercontent.com/$Repo/$sha/downloads/SillViewer-windows.zip"
        Expand-Archive -Path $zip -DestinationPath $tmp -Force
        $src = Join-Path $tmp "SillViewer-windows"
        if (-not (Test-Path (Join-Path $src "Sill Viewer.exe"))) { throw "the download has no Sill Viewer.exe" }

        # The same viewer as installed (GitHub changed something else): nothing to do.
        $same = (Test-Path $Exe) -and ((Get-FileHash $Exe).Hash -eq (Get-FileHash (Join-Path $src "Sill Viewer.exe")).Hash)
        if ($same -and -not $Force) {
            Say "GitHub moved to $($sha.Substring(0,7)); the viewer is the same."
        } else {
            $running = @(Get-Process -Name "Sill Viewer" -ErrorAction SilentlyContinue)
            $running | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 800
            New-Item -ItemType Directory -Force -Path $Dir | Out-Null
            Copy-Item -Path (Join-Path $src "*") -Destination $Dir -Recurse -Force
            Get-ChildItem $Dir -Recurse | Unblock-File -ErrorAction SilentlyContinue
            Say "Sill Viewer updated to $($sha.Substring(0,7))."
            if ($running.Count -gt 0 -or -not $Update) { Start-Process -FilePath $Exe -WorkingDirectory $Dir }
        }
    }
    Set-Content -Path $State -Value $sha
} catch {
    Say "Update failed: $($_.Exception.Message)"
    exit 1
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

if (-not $Update) {
    # This script, kept next to the viewer, is what the hourly task runs.
    if ($PSCommandPath -and ($PSCommandPath -ne $Self)) { Copy-Item -Path $PSCommandPath -Destination $Self -Force }
    $cmd = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Self`" -Update"
    schtasks /Create /TN $Task /SC HOURLY /TR $cmd /F | Out-Null
    $menu = Join-Path ([Environment]::GetFolderPath("Programs")) "Sill Viewer.lnk"
    $sh = New-Object -ComObject WScript.Shell
    $lnk = $sh.CreateShortcut($menu)
    $lnk.TargetPath = $Exe
    $lnk.WorkingDirectory = $Dir
    $lnk.Save()
    Write-Host "Installed in $Dir. 'Sill Viewer' is in the Start menu. Updates are checked every hour."
} else {
    # Keep the task's copy of this script current.
    try {
        $s = Join-Path $env:TEMP "sill-update-new.ps1"
        Invoke-WebRequest -UseBasicParsing -OutFile $s -Uri "https://raw.githubusercontent.com/$Repo/$sha/downloads/install-sill-viewer.ps1"
        if ((Get-Item $s).Length -gt 1000) { Move-Item -Force $s $Self }
    } catch { }
}
