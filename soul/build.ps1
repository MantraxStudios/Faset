# =============================================================================
#  Soul - build script.
#
#  1. Compiles the GLSL shaders to SPIR-V with glslc (from the Vulkan SDK).
#  2. Builds the Faset project with the freshly-rebuilt compiler.
#
#  Run from the repository root:  powershell -ExecutionPolicy Bypass -File soul/build.ps1
# =============================================================================
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot      # repository root

# --- locate glslc -----------------------------------------------------------
$glslc = 'glslc'
if ($env:VULKAN_SDK) {
    $candidate = Join-Path $env:VULKAN_SDK 'Bin\glslc.exe'
    if (Test-Path $candidate) { $glslc = $candidate }
}
if (-not (Get-Command $glslc -ErrorAction SilentlyContinue) -and -not (Test-Path $glslc)) {
    Write-Error "glslc not found. Install the Vulkan SDK (winget install KhronosGroup.VulkanSDK) and open a new shell."
}

# --- compile shaders --------------------------------------------------------
$shaders = Join-Path $root 'soul\shaders'
foreach ($stage in @('cube.vert', 'cube.frag', 'water.frag', 'shadow.vert')) {
    $src = Join-Path $shaders $stage
    $out = "$src.spv"
    Write-Host "glslc  $stage -> $stage.spv"
    & $glslc $src -o $out
}

# --- build the game ---------------------------------------------------------
$faset = Join-Path $root 'build-cc\faset.exe'
Write-Host "faset build soul/Soul.fstproj"
& $faset build (Join-Path $root 'soul\Soul.fstproj')

# --- copy compiled shaders next to the executable ---------------------------
# so the game finds them regardless of the working directory (double-click).
$exeDir = Join-Path $root 'soul\bin\Debug\windows-x86_64'
if (Test-Path $exeDir) {
    Copy-Item (Join-Path $shaders '*.spv') $exeDir -Force
    Write-Host "copied shaders -> $exeDir"
}
