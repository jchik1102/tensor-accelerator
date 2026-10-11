param([ValidateSet(4,8)][int]$ArrayN=8,[switch]$InjectDefect)
$ErrorActionPreference='Stop'
$ProjectRoot=Split-Path $PSScriptRoot -Parent
$Kind=if($InjectDefect){'mutated'}else{'clean'}
$RunRoot=Join-Path $ProjectRoot "artifacts/hex-check-n$ArrayN-$Kind"
New-Item -ItemType Directory -Force $RunRoot | Out-Null
$Decoder=Get-Content "$ProjectRoot/fpga/board/ta_hex_decoder.sv" -Raw
if($InjectDefect){$Decoder=$Decoder.Replace("3:segments=8'hb0;","3:segments=8'hb1;")}
$Decoder | Set-Content "$RunRoot/decoder.sv"
Push-Location $RunRoot
try {
    $SimBin='C:/AMDDesignTools/2025.2/Vivado/bin'
    $env:XILINX_VIVADO=Split-Path $SimBin -Parent
    $Sources=@('ta_pe','ta_array','ta_requant','ta_ram','ta_vector_ram','ta_core') | ForEach-Object {"$ProjectRoot/rtl/$_.sv"}
    $CompileArgs=@('--sv')
    if($ArrayN -eq 8){$CompileArgs+=@('-d','TA_ARRAY_8')}
    & "$SimBin/xvlog.bat" @CompileArgs @Sources decoder.sv "$ProjectRoot/fpga/board/ta_avalon_adapter.sv" "$ProjectRoot/tb/adapter_tb.sv" *> compile.log
    if($LASTEXITCODE -ne 0){throw 'HEX compile failed'}
    & "$SimBin/xelab.bat" adapter_tb -s hex_check --debug typical --timescale 1ns/1ps *> elaborate.log
    if($LASTEXITCODE -ne 0){throw 'HEX elaborate failed'}
    & "$SimBin/xsim.bat" hex_check --R *> run.log
    if($InjectDefect){
        if(!(Select-String -Path run.log -SimpleMatch 'HEX_MISMATCH' -Quiet)){throw 'Display mutation escaped'}
        'HEX_MUTATION_DETECTED digit3_segment_a'
    }else{
        if($LASTEXITCODE -ne 0 -or !(Select-String -Path run.log -SimpleMatch 'ADAPTER_PASS' -Quiet)){throw 'HEX simulation failed'}
        Select-String -Path run.log -Pattern 'ADAPTER_PASS'
    }
}finally{Pop-Location}
