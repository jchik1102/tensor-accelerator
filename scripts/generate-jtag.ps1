$ErrorActionPreference='Stop'
$ProjectRoot=Split-Path $PSScriptRoot -Parent
$RunRoot=Join-Path $ProjectRoot 'artifacts/board'
$QsysBin='C:/intelFPGA_lite/24.1std/quartus/sopc_builder/bin'
New-Item -ItemType Directory -Force $RunRoot | Out-Null
Push-Location $RunRoot
try {
    & "$QsysBin/qsys-script.exe" "--script=$ProjectRoot/fpga/board/create-jtag.tcl"
    if($LASTEXITCODE -ne 0){throw 'JTAG system creation failed'}
    & "$QsysBin/qsys-generate.exe" ta_jtag.qsys --synthesis=VERILOG
    if($LASTEXITCODE -ne 0){throw 'JTAG synthesis generation failed'}
} finally {Pop-Location}
