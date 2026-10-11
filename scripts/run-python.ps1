param([Parameter(ValueFromRemainingArguments=$true)][string[]]$PythonArgs)
$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path $PSScriptRoot -Parent
Push-Location $ProjectRoot
try {
& wsl.exe -d Ubuntu --cd /mnt/c/projects/tensor-accelerator --exec /home/jonat/.venvs/tensor-accelerator/bin/python @PythonArgs
if ($LASTEXITCODE -ne 0) { throw "Python failed: $LASTEXITCODE" }
} finally { Pop-Location }
