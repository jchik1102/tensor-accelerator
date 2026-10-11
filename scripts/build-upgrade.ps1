param([ValidateSet(4,8)][int]$ArrayN=4,[ValidateSet(50,60,65,75,100)][int]$CoreMHz=75,[string]$Variant='')
$ErrorActionPreference='Stop'
$ProjectRoot=Split-Path $PSScriptRoot -Parent
if(!(Test-Path "$ProjectRoot/artifacts/board/ta_jtag/synthesis/ta_jtag.qip")){
    & "$PSScriptRoot/generate-jtag.ps1"
}
$RunRoot=Join-Path $ProjectRoot "artifacts/board-n$ArrayN-$CoreMHz"
if($Variant){if($Variant -notmatch '^[a-z0-9-]+$'){throw 'Invalid variant'};$RunRoot+="-$Variant"}
New-Item -ItemType Directory -Force $RunRoot | Out-Null
Push-Location $RunRoot
try {
    if(Test-Path build.log){Copy-Item build.log "build.log.previous-$(Get-Date -Format yyyyMMdd-HHmmss-fff)"}
    $Q='C:/intelFPGA_lite/24.1std/quartus/bin64'
    @{array_n=$ArrayN;core_mhz=$CoreMHz;time=(Get-Date -Format o);seed=1} | ConvertTo-Json | Set-Content configuration.json
    $SourceFiles=@(rg --files "$ProjectRoot/rtl" "$ProjectRoot/fpga" "$ProjectRoot/artifacts/board/ta_jtag/synthesis")
    $Manifest=@{}
    foreach($File in $SourceFiles){$Manifest[$File]=(Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash}
    $Manifest | ConvertTo-Json | Set-Content source-sha256.json
    & "$Q/quartus_sh.exe" -t "$ProjectRoot/fpga/board/build-board.tcl" $ArrayN $CoreMHz *> build.log
    if($LASTEXITCODE -ne 0){Get-Content build.log -Tail 30;throw 'Board compilation failed'}
    & "$Q/quartus_sta.exe" -t "$ProjectRoot/fpga/quartus/report-timing.tcl" de10_lite *> timing-audit.log
    if($LASTEXITCODE -ne 0){throw 'Timing audit failed'}
    foreach($File in $SourceFiles){if((Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash -ne $Manifest[$File]){throw "Source changed during build: $File"}}
    Get-Content output_files/de10_lite.fit.summary
    $Summary=Get-Content output_files/de10_lite.sta.summary -Raw
    $Slacks=[regex]::Matches($Summary,'Slack\s*:\s*(-?[\d.]+)') | ForEach-Object {[double]$_.Groups[1].Value}
    if(!$Slacks -or ($Slacks | Where-Object {$_ -lt 0})){throw 'Timing checks did not all pass; this image is not a qualified candidate'}
    "TIMING_PASS minimum_reported_slack_ns=$(($Slacks | Measure-Object -Minimum).Minimum)"
    Get-FileHash output_files/de10_lite.sof -Algorithm SHA256 | Format-List
} finally {Pop-Location}
