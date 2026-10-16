param([int[]]$Seeds=@(1,42,20261008))
# Offline regression: the commands listed under "Software, simulation, tests,
# and rebuilding" in the README, in order. No board access. Every step runs
# even if an earlier one fails; the script exits non-zero if any step failed.
$ErrorActionPreference='Stop'
$ProjectRoot=Split-Path $PSScriptRoot -Parent
Set-Location $ProjectRoot
"START $(Get-Date -Format o) commit $(git rev-parse HEAD)"
$Failed=@()
function Step([string]$Name,[scriptblock]$Body) {
    $Start=Get-Date
    "=== STEP $Name"
    try { & $Body; "=== STEP_PASS $Name $([int]((Get-Date)-$Start).TotalSeconds)s" }
    catch { "=== STEP_FAIL $Name $([int]((Get-Date)-$Start).TotalSeconds)s :: $_"; $script:Failed+=$Name }
}
Step pytest { & "$PSScriptRoot/run-python.ps1" -m pytest tests -q }
Step persistent_console { & "$PSScriptRoot/run-python.ps1" -m tests.check_persistent_console }
Step vectors { & "$PSScriptRoot/run-python.ps1" -m host.ta.vectors }
Step board_plan { & "$PSScriptRoot/run-python.ps1" -m host.ta.board_plan --sample 0 }
Step board_tcl {
    & 'C:\intelFPGA_lite\24.1std\quartus\bin64\tclsh86.exe' "$ProjectRoot/tests/check_board_tcl.tcl"
    if($LASTEXITCODE -ne 0){throw "Tcl check exit $LASTEXITCODE"}
}
Step sim_n4 { & "$PSScriptRoot/run-sim.ps1" -ArrayN 4 -Seeds $Seeds }
Step sim_n8 { & "$PSScriptRoot/run-sim.ps1" -ArrayN 8 -Seeds $Seeds }
Step mutation_pe { & "$PSScriptRoot/run-sim.ps1" -Mutation pe }
Step mutation_round { & "$PSScriptRoot/run-sim.ps1" -Mutation round }
Step mutation_bank_n8 { & "$PSScriptRoot/run-sim.ps1" -ArrayN 8 -Mutation bank }
Step replay_n4 { & "$PSScriptRoot/replay-sim.ps1" -ArrayN 4 }
Step hex_n8 { & "$PSScriptRoot/run-hex-check.ps1" -ArrayN 8 }
Step hex_n4_defect { & "$PSScriptRoot/run-hex-check.ps1" -ArrayN 4 -InjectDefect }
"END $(Get-Date -Format o) FAILED_STEPS=[$($Failed -join ',')]"
if($Failed){ 'REGRESSION_FAIL'; exit 1 }
'REGRESSION_PASS'
