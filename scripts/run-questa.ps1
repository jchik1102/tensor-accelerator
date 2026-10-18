# The benches that the Questa Intel Starter FPGA Edition licence can run, in
# Questa: quant_tb and adapter_tb (4x4 and 8x8 builds, as in run-sim.ps1), the
# round mutation on quant_tb, and the cocotb tests (tb/cocotb) with their two
# mutations. core_tb is not here: it uses randomize() and covergroups, which
# the Starter licence refuses (no SystemVerilog verification feature, vsim-1).
#
# cocotb runs from a Windows Python with cocotb 2.1.0 (the version the WSL venv
# has), since Questa is the Windows install. Logs in artifacts/questa/.
param(
    [string]$Questa='C:\intelFPGA_lite\24.1std\questa_fse',
    [string]$CocotbPython="$env:USERPROFILE\.venvs\cocotb-win\Scripts\python.exe"
)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$bin=Join-Path $Questa 'win64'
$out=Join-Path $root 'artifacts/questa'
New-Item -ItemType Directory -Force $out | Out-Null
$summary=Join-Path $out 'summary.txt'
Set-Content $summary ''
function Tool([string]$Name,[string[]]$ToolArgs,[string]$Log) {
    $ErrorActionPreference='Continue'   # stderr lines are not failures; the exit code is
    & (Join-Path $bin "$Name.exe") @ToolArgs 2>&1 | Out-File -Encoding utf8 $Log
    if($LASTEXITCODE -ne 0){throw "$Name failed ($LASTEXITCODE), see $Log"}
}
function Note([string]$Line) {Add-Content $summary $Line; Write-Host $Line}
# Compile the RTL and benches into work/, optimize $top, run it, return the log.
function Bench([string]$Name,[string]$Top,[string[]]$Defines) {
    $dir=Join-Path $root "artifacts/questa_$Name"   # next to artifacts/vectors
    New-Item -ItemType Directory -Force $dir | Out-Null
    Push-Location $dir
    try {
        if(Test-Path work){Remove-Item -Recurse -Force work}
        Tool vlib @('work') 'vlib.log'
        $sources=@('ta_pe','ta_array','ta_requant','ta_ram','ta_vector_ram','ta_core') | ForEach-Object {"$root/rtl/$_.sv"}
        $sources+=@("$root/fpga/board/ta_hex_decoder.sv","$root/fpga/board/ta_avalon_adapter.sv","$root/tb/quant_tb.sv","$root/tb/adapter_tb.sv")
        Tool vlog (@('-sv','-timescale','1ns/1ps')+($Defines | ForEach-Object {"+define+$_"})+$sources) 'compile.log'
        Tool vopt @($Top,'-o',"${Top}_opt") 'vopt.log'
        $ErrorActionPreference='Continue'
        & (Join-Path $bin 'vsim.exe') -c "${Top}_opt" -l sim.log -do 'run -all; quit -f' 2>&1 | Out-File -Encoding utf8 sim.console.log
        return (Get-Content sim.log -Raw)
    } finally {Pop-Location}
}
# quant_tb reads ../vectors/quant.txt: run from a directory next to artifacts/vectors.
if(!(Test-Path (Join-Path $root 'artifacts/vectors/quant.txt'))){throw 'Missing artifacts/vectors; run make models first'}
foreach($n in 4,8) {
    $defs=if($n -eq 8){@('TA_ARRAY_8')}else{@()}
    foreach($b in @(@('quant_tb','QUANT_PASS'),@('adapter_tb','ADAPTER_PASS'))) {
        $top,$marker=$b
        $log=Bench "${top}_n$n" $top $defs
        $pass=[regex]::Match($log,"(?m)$marker.*$").Value.Trim()
        if(!$pass -or $log -match '(?m)^#\s*\*\*\s*(Error|Fatal)'){throw "$top n$n failed in Questa: artifacts/questa_${top}_n$n/sim.log"}
        Note ('{0,-28} PASS {1}' -f "${top}_n$n",$pass)
    }
}
$log=Bench 'quant_tb_mutate_round' 'quant_tb' @('TA_MUTATE_ROUND')
if($log -notmatch 'QUANT_MISMATCH'){throw 'Round mutation not detected in Questa'}
Note ('{0,-28} MUTATION_DETECTED {1}' -f 'quant_tb_mutate_round',([regex]::Match($log,'QUANT_MISMATCH[^\r\n]*').Value))

# cocotb, through Questa
$env:COCOTB_SIM='questa'
$env:PATH="$bin;$env:PATH"
Push-Location $root
try {
    $ErrorActionPreference='Continue'
    Remove-Item Env:TA_MUTATION -ErrorAction SilentlyContinue
    & $CocotbPython -m pytest tb/cocotb -v -s 2>&1 | Out-File -Encoding utf8 (Join-Path $out 'cocotb.log')
    $code=$LASTEXITCODE
    $text=Get-Content (Join-Path $out 'cocotb.log') -Raw
    $tally=[regex]::Matches($text,'(?m)\*\* TESTS=\d+ PASS=\d+ FAIL=\d+ SKIP=\d+') | ForEach-Object {$_.Value}
    if($code -ne 0){throw "cocotb in Questa failed, see artifacts/questa/cocotb.log"}
    Note ('{0,-28} PASS {1}' -f 'cocotb',($tally -join '; '))
    foreach($m in 'TA_MUTATE_PE','TA_MUTATE_ROUND') {
        $env:TA_MUTATION=$m
        & $CocotbPython -m pytest tb/cocotb -q 2>&1 | Out-File -Encoding utf8 (Join-Path $out "cocotb-$m.log")
        if($LASTEXITCODE -eq 0){throw "cocotb tests pass on $m in Questa"}
        # A failing test, not a build error, must be what failed.
        if((Get-Content (Join-Path $out "cocotb-$m.log") -Raw) -notmatch 'FAIL=[1-9]'){throw "cocotb ${m}: no failing test, see artifacts/questa/cocotb-$m.log"}
        Note ('{0,-28} COCOTB_MUTATION_DETECTED {1}' -f "cocotb $m",$m)
    }
    Remove-Item Env:TA_MUTATION
} finally {Pop-Location}
Write-Host 'QUESTA_PASS'
