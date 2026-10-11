param([ValidateSet(4,8)][int]$ArrayN=4)
$ErrorActionPreference='Stop'
$ProjectRoot=Split-Path $PSScriptRoot -Parent
$RunRoot=Join-Path $ProjectRoot "artifacts/synthesis-n$ArrayN"
New-Item -ItemType Directory -Force $RunRoot | Out-Null
Push-Location $RunRoot
try {
if(Test-Path build.log){Copy-Item build.log "build.log.previous-$(Get-Date -Format yyyyMMdd-HHmmss-fff)"}
@{time=(Get-Date -Format o);program='quartus_sh';arguments=@('-t',"$ProjectRoot/fpga/quartus/build-core.tcl");cwd=$RunRoot} | ConvertTo-Json -Compress | Add-Content commands.jsonl
& 'C:/intelFPGA_lite/24.1std/quartus/bin64/quartus_sh.exe' -t "$ProjectRoot/fpga/quartus/build-core.tcl" $ArrayN *> build.log
$Code=$LASTEXITCODE
Get-Content build.log -Tail 25
if($Code -ne 0){throw "Quartus failed $Code"}
} finally { Pop-Location }
