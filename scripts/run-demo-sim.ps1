param([Parameter(Mandatory=$true)][string]$Vectors,[Parameter(Mandatory=$true)][string]$Log)
$ErrorActionPreference='Stop'
$ProjectRoot=Split-Path $PSScriptRoot -Parent
Push-Location "$ProjectRoot/artifacts/sim"
try {
if(!(Test-Path xsim.dir/core_tb_clean)){throw 'Run scripts/run-sim.ps1 first'}
$OptionsFile=Join-Path (Split-Path $Log -Parent) 'xsim-options.txt'
@('core_tb_clean','--R','--sv_seed','42','--testplusarg',"VECTORS=$Vectors") | Set-Content -LiteralPath $OptionsFile -Encoding ascii
& 'C:/AMDDesignTools/2025.2/Vivado/bin/xsim.bat' --file $OptionsFile *> $Log
if($LASTEXITCODE -ne 0){throw 'XSim failed'}
if(!(Select-String -Path $Log -SimpleMatch 'CORE_PASS' -Quiet)){throw 'RTL inference failed'}
} finally { Pop-Location }
