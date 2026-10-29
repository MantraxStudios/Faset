# Instalación de Faset en una línea (Windows x86_64, PowerShell):
#   irm https://faset.lat/install.ps1 | iex
# Variables opcionales: $env:FASET_ANDROID = "1" (también el módulo de Android), $env:FASET_YES = "1" (sin preguntas).
$ErrorActionPreference = "Stop"
$url = if ($env:FASET_URL) { $env:FASET_URL } else { "https://github.com/MantraxStudios/Faset/releases/latest/download/faset-windows-x86_64.zip" }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("faset-" + [Guid]::NewGuid())
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
    Write-Host "Descargando $url"
    $zip = Join-Path $tmp "faset.zip"
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zip
    Expand-Archive -Path $zip -DestinationPath $tmp -Force
    $opts = @{}
    if ($env:FASET_ANDROID -eq "1") { $opts["Android"] = $true }
    if ($env:FASET_YES -eq "1") { $opts["Yes"] = $true }
    & (Join-Path $tmp "faset\install.ps1") @opts
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
