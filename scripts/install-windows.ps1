# Instalador de Faset para Windows (va dentro del paquete faset-<versión>-windows-x86_64.zip).
#   powershell -ExecutionPolicy Bypass -File install.ps1             instala en %LOCALAPPDATA%\Faset
#   ... install.ps1 -Android    también el módulo de Android (SDK, NDK, Java y emulador)
#   ... install.ps1 -Yes        sin preguntas (acepta las licencias del SDK de Android)
#   ... install.ps1 -NoSetup    solo copia los archivos (sin 'faset setup')
#   ... install.ps1 -Desktop    también un acceso directo a FasetStudio en el escritorio
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall  lo quita (con los accesos directos)
param([switch]$Uninstall, [switch]$Android, [switch]$Yes, [switch]$NoSetup, [switch]$Desktop)
$ErrorActionPreference = "Stop"
$dest = Join-Path $env:LOCALAPPDATA "Faset"
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($null -eq $userPath) { $userPath = "" }
$parts = $userPath.Split(";") | Where-Object { $_ -ne "" -and $_ -ne $dest }
# Accesos directos de FasetStudio: menú Inicio del usuario y, con -Desktop, el escritorio.
$startLink = Join-Path ([Environment]::GetFolderPath("Programs")) "FasetStudio.lnk"
$desktopLink = Join-Path ([Environment]::GetFolderPath("Desktop")) "FasetStudio.lnk"

if ($Uninstall) {
    if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
    [Environment]::SetEnvironmentVariable("Path", ($parts -join ";"), "User")
    foreach ($l in @($startLink, $desktopLink)) { if (Test-Path $l) { Remove-Item -Force $l } }
    Write-Host "Faset desinstalado."
    exit 0
}

function New-Shortcut([string]$path) {
    $studio = Join-Path $dest "FasetStudio.exe"
    if (-not (Test-Path $studio)) { return }
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($path)
    $lnk.TargetPath = $studio
    $lnk.WorkingDirectory = $dest
    $lnk.Description = "FasetStudio, el entorno de desarrollo de Faset"
    $icon = Join-Path $dest "faset.ico"
    if (Test-Path $icon) { $lnk.IconLocation = "$icon,0" }
    $lnk.Save()
}

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if ((Resolve-Path $here).Path -ne $dest) {
    if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Copy-Item -Recurse -Force (Join-Path $here "*") $dest
}
[Environment]::SetEnvironmentVariable("Path", (($parts + $dest) -join ";"), "User")
$env:Path = "$env:Path;$dest"
Write-Host "Faset instalado en $dest (añadido al PATH del usuario; abre una terminal nueva)."
New-Shortcut $startLink
Write-Host "Acceso directo de FasetStudio creado en el menú Inicio."
if ($Desktop) {
    New-Shortcut $desktopLink
    Write-Host "Acceso directo de FasetStudio creado en el escritorio."
}
$faset = Join-Path $dest "faset.exe"
& $faset --version
if ($NoSetup) { exit 0 }

# Módulo de Windows (compilador de C llvm-mingw) siempre; Android si se pide o se acepta.
$yesArg = @()
if ($Yes) { $yesArg = @("--yes") }
& $faset setup windows @yesArg
if (-not $Android -and -not $Yes) {
    $r = Read-Host "¿Instalar también el módulo de Android (SDK, NDK, Java y emulador, ~4 GB)? [s/N]"
    if ($r -match '^[sSyY]') { $Android = $true }
}
if ($Android) { & $faset setup android @yesArg }
Write-Host ""
Write-Host "Listo. Abre FasetStudio desde el menú Inicio, o una terminal nueva y prueba: faset new Hola; cd Hola; faset run"
