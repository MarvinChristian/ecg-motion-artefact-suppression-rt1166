param(
    [switch]$DryRun,
    [switch]$NoBuild
)

$ErrorActionPreference = "Stop"

$repo = Split-Path -Parent $PSScriptRoot
$mcuxRoot = "C:\nxp\MCUXpressoIDE_25.6.136"
$toolBin = Join-Path $mcuxRoot "ide\plugins\com.nxp.mcuxpresso.tools.win32_25.6.0.202501151204\tools\bin"
$buildTools = Join-Path $mcuxRoot "ide\plugins\com.nxp.mcuxpresso.tools.win32_25.6.0.202501151204\buildtools\bin"
$linkServer = Join-Path $mcuxRoot "ide\LinkServer\LinkServer.exe"

$env:PATH = "$toolBin;$buildTools;$env:PATH"

$device = "MIMXRT1166:MIMXRT1160-EVK"
$cm7Axf = Join-Path $repo "Debug\Motion_Artefact_Suppression_ECG_SystemP1_09_04_2026.axf"
$cm4Axf = Join-Path $repo "Debug_CM4\Phase4_CM4_Classifier.axf"

Set-Location $repo

if (-not $NoBuild) {
    make -C Debug -r -j4 all
    make -C Debug -r -j4 Build_CM4_Classifier
}

if (-not (Test-Path $cm7Axf)) {
    throw "CM7 image not found: $cm7Axf"
}

if (-not (Test-Path $cm4Axf)) {
    throw "CM4 image not found: $cm4Axf"
}

$flashArgs = @("flash", $device, "load", $cm7Axf, $cm4Axf)

if ($DryRun) {
    Write-Host "`"$linkServer`" $($flashArgs -join ' ')"
    exit 0
}

& $linkServer @flashArgs
