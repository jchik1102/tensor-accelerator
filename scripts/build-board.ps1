$ErrorActionPreference='Stop'
$ProjectRoot=Split-Path $PSScriptRoot -Parent
$RunRoot=Join-Path $ProjectRoot 'artifacts/board'
New-Item -ItemType Directory -Force $RunRoot | Out-Null
Push-Location $RunRoot
try {
$QsysBin='C:/intelFPGA_lite/24.1std/quartus/sopc_builder/bin'
function Board-Tool([string]$Name,[string]$Program,[string[]]$ToolArgs){
    if(Test-Path "$Name.log"){Copy-Item "$Name.log" "$Name.log.previous-$(Get-Date -Format yyyyMMdd-HHmmss-fff)"}
    @{time=(Get-Date -Format o);program=$Program;arguments=$ToolArgs;cwd=$RunRoot}|ConvertTo-Json -Compress|Add-Content commands.jsonl
    & $Program @ToolArgs *> "$Name.log"
    $Code=$LASTEXITCODE
    Write-Output "$Name exit=$Code"
    if($Code -ne 0){Get-Content "$Name.log" -Tail 25;throw "$Name failed"}
}
Board-Tool 'create-jtag' "$QsysBin/qsys-script.exe" @("--script=$ProjectRoot/fpga/board/create-jtag.tcl")
Board-Tool 'generate-jtag' "$QsysBin/qsys-generate.exe" @('ta_jtag.qsys','--synthesis=VERILOG')
Board-Tool 'build-board' 'C:/intelFPGA_lite/24.1std/quartus/bin64/quartus_sh.exe' @('-t',"$ProjectRoot/fpga/board/build-board.tcl")
} finally { Pop-Location }
