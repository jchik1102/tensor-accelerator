param(
    [string]$Vivado = 'C:\AMDDesignTools\2025.2\Vivado',
    [string]$Part = 'xc7a100tcsg324-1',
    [ValidateSet(4, 8)][int]$ArrayN = 8,
    [double]$PeriodNs = 13.333
)
# Out-of-context Vivado implementation of ta_core for a Xilinx Artix-7 part at
# the board's 75 MHz, for comparison with the Intel MAX 10 build. Writes
# build/vivado/n<ArrayN>/ and prints VIVADO_PASS or VIVADO_FAIL.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$out = (Join-Path $root "build/vivado/n$ArrayN").Replace('\', '/')
New-Item -ItemType Directory -Force $out | Out-Null
$sources = @('ta_pe', 'ta_array', 'ta_ram', 'ta_vector_ram', 'ta_requant', 'ta_core') |
    ForEach-Object { (Join-Path $root "rtl/$_.sv").Replace('\', '/') }
Push-Location $out
try {
    & (Join-Path $Vivado 'bin/vivado.bat') -mode batch -nojournal -log vivado.log -source ((Join-Path $root 'scripts/vivado-impl.tcl').Replace('\', '/')) `
        -tclargs ta_core $Part $PeriodNs $out "ARRAY_N:$ArrayN" none @sources
    if ($LASTEXITCODE -ne 0) { throw "Vivado failed: $LASTEXITCODE" }
    Get-Content (Join-Path $out 'result.txt')
} finally { Pop-Location }
