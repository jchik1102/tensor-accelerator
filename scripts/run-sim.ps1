param([ValidateSet('clean','pe','round','bank')][string]$Mutation='clean',[int[]]$Seeds=@(1,42,20261008),[ValidateSet(4,8)][int]$ArrayN=4)
$ErrorActionPreference='Stop'
$ProjectRoot=Split-Path $PSScriptRoot -Parent
$RunRoot=Join-Path $ProjectRoot 'artifacts/sim'
if($ArrayN -eq 8){$RunRoot=Join-Path $ProjectRoot 'artifacts/sim-n8'}
New-Item -ItemType Directory -Force $RunRoot | Out-Null
Push-Location $RunRoot
try {
$SimBin='C:/AMDDesignTools/2025.2/Vivado/bin'
$env:XILINX_VIVADO=Split-Path $SimBin -Parent
function Run-Tool([string]$Name,[string]$Program,[string[]]$ToolArgs) {
    $Log=Join-Path $RunRoot "$Name.log"
    if(Test-Path $Log){Copy-Item $Log "$Log.previous-$(Get-Date -Format yyyyMMdd-HHmmss-fff)"}
    @{time=(Get-Date -Format o);program=$Program;arguments=$ToolArgs;cwd=$RunRoot} | ConvertTo-Json -Compress | Add-Content commands.jsonl
    & $Program @ToolArgs *> $Log
    $Code=$LASTEXITCODE
    "EXIT_CODE=$Code" | Add-Content $Log
    Write-Output "$Name exit=$Code"
    if($Code -ne 0 -and !$Name.StartsWith('mutation-')){Get-Content $Log -Tail 20;throw "$Name failed"}
}
$Sources=@('ta_pe','ta_array','ta_requant','ta_ram','ta_vector_ram','ta_core') | ForEach-Object {"$ProjectRoot/rtl/$_.sv"}
$CompileArgs=@('--sv','-L','uvm','--uvm_version','1.2')
if($ArrayN -eq 8){$CompileArgs+=@('-d','TA_ARRAY_8')}
if($Mutation -eq 'pe'){$CompileArgs+=@('-d','TA_MUTATE_PE')}
if($Mutation -eq 'round'){$CompileArgs+=@('-d','TA_MUTATE_ROUND')}
if($Mutation -eq 'bank'){$CompileArgs+=@('-d','TA_MUTATE_BANK')}
Run-Tool "compile-$Mutation" "$SimBin/xvlog.bat" ($CompileArgs+$Sources+@("$ProjectRoot/fpga/board/ta_hex_decoder.sv","$ProjectRoot/fpga/board/ta_avalon_adapter.sv","$ProjectRoot/tb/core_tb.sv","$ProjectRoot/tb/quant_tb.sv","$ProjectRoot/tb/adapter_tb.sv"))
foreach($Top in @('quant_tb','core_tb','adapter_tb')) {
    Run-Tool "elaborate-$Top-$Mutation" "$SimBin/xelab.bat" @($Top,'-L','uvm','--uvm_version','1.2','-s',"$Top`_$Mutation",'--debug','typical','--timescale','1ns/1ps')
}
if($Mutation -eq 'clean') {
    Run-Tool 'quant-clean' "$SimBin/xsim.bat" @('quant_tb_clean','--R')
    if(!(Select-String -Path quant-clean.log -SimpleMatch 'QUANT_PASS' -Quiet)){throw 'Quantization failed'}
    Run-Tool 'adapter-clean' "$SimBin/xsim.bat" @('adapter_tb_clean','--R')
    if(!(Select-String -Path adapter-clean.log -SimpleMatch 'ADAPTER_PASS' -Quiet)){throw 'Avalon adapter failed'}
    foreach($Seed in $Seeds){
        Run-Tool "core-$Seed" "$SimBin/xsim.bat" @('core_tb_clean','--R','--sv_seed',"$Seed",'--cov_db_dir','coverage','--cov_db_name',"core_$Seed")
        if(!(Select-String -Path "core-$Seed.log" -SimpleMatch 'CORE_PASS' -Quiet)){throw "Core failed seed $Seed"}
        $Report="coverage-$Seed-$(Get-Date -Format yyyyMMdd-HHmmss)"
        Run-Tool "coverage-$Seed" "$SimBin/xcrg.bat" @('-cov_db_dir','coverage','-cov_db_name',"core_$Seed",'-report_dir',$Report,'-report_format','all')
    }
} else {
    $Top=if($Mutation -eq 'round'){'quant_tb'}else{'core_tb'}
    Run-Tool "mutation-$Mutation" "$SimBin/xsim.bat" @("$Top`_$Mutation",'--R','--sv_seed','42')
    if(!(Select-String -Path "mutation-$Mutation.log" -Pattern 'MISMATCH' -Quiet)){throw 'Mutation not detected'}
    "MUTATION_DETECTED $Mutation"
}
} finally { Pop-Location }
