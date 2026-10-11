param([Parameter(Mandatory=$true)][string]$Plan,
      [Parameter(Mandatory=$true)][string]$MasterPath)
$ErrorActionPreference = 'Stop'
$console = 'C:\intelFPGA_lite\24.1std\quartus\sopc_builder\bin\system-console.exe'
if ($MasterPath -match '[{}\r\n]' -or $Plan -match '[{}\r\n]') { throw 'Invalid Tcl path' }
$tclPlan = $Plan.Replace('\','/')
$commands = @(
    "set env(TA_MASTER_PATH) {$MasterPath}"
    'set env(TA_BOARD_IMAGE_CONFIRMED) TA01'
    ('try {source {' + $tclPlan + '}} on error {message options} {puts stderr "BOARD_ERROR: $message"; error $message}')
) -join "`n"
$launcher = Join-Path (Split-Path -Parent $Plan) 'launch.tcl'
[IO.File]::WriteAllText($launcher, $commands)
& $console --cli "--script=$launcher"
if ($LASTEXITCODE -ne 0) { throw "Board inference failed: $LASTEXITCODE" }
