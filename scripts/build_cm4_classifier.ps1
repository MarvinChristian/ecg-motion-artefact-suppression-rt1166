$ErrorActionPreference = "Stop"

$repo = Split-Path -Parent $PSScriptRoot
$toolBin = "C:\nxp\MCUXpressoIDE_25.6.136\ide\plugins\com.nxp.mcuxpresso.tools.win32_25.6.0.202501151204\tools\bin"
$buildTools = "C:\nxp\MCUXpressoIDE_25.6.136\ide\plugins\com.nxp.mcuxpresso.tools.win32_25.6.0.202501151204\buildtools\bin"

$env:PATH = "$toolBin;$buildTools;$env:PATH"
Set-Location $repo

make -C Debug -r -j4 Build_CM4_Classifier
