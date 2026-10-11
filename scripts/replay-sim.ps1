param([ValidateSet(4,8)][int]$ArrayN=4)
$ErrorActionPreference='Stop'
$ProjectRoot=Split-Path $PSScriptRoot -Parent
$RunRoot=if($ArrayN -eq 4){"$ProjectRoot/artifacts/sim"}else{"$ProjectRoot/artifacts/sim-n8"}
Push-Location $RunRoot
try {
& 'C:/AMDDesignTools/2025.2/Vivado/bin/xsim.bat' core_tb_clean --R --sv_seed 42 *> core-replay-42.log
if($LASTEXITCODE -ne 0){throw 'Replay process failed'}
$Original=(Select-String -Path core-42.log -Pattern '^CORE_PASS').Line
$Replay=(Select-String -Path core-replay-42.log -Pattern '^CORE_PASS').Line
if(!$Original -or $Original -cne $Replay){throw 'Seed 42 result/gap digest differs on replay'}
'REPLAY_PASS seed=42 exact result, activity, gap counts and ordered gap digest'
} finally { Pop-Location }
