$ErrorActionPreference='Stop'
$PSNativeCommandUseErrorActionPreference=$false
$taskBase='build/loading-validation/main-3068-output-fixed'
$taskState=[ordered]@{state='waiting_compile';startedAtUtc=[DateTime]::UtcNow.ToString('o');completedAtUtc=$null;actualExitCode=$null;wrapperPid=$PID;fastExitCode=$null;pgExitCode=$null;sealExitCode=$null}
function Save-TaskState { $taskState | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $taskBase 'queue-execution.json') -Encoding utf8 }
Save-TaskState
while ($true) {
  $taskCompile=Get-Content -Raw -LiteralPath (Join-Path $taskBase 'compile-execution.json') | ConvertFrom-Json
  if ($taskCompile.state -ne 'running') { break }
  Start-Sleep -Seconds 1
}
if ($taskCompile.state -ne 'completed' -or $taskCompile.actualExitCode -ne 0) { throw 'Fresh current compile did not complete native0' }
$taskState.state='running_fast';Save-TaskState
$taskSelection=(Get-Content -Raw -LiteralPath (Join-Path $taskBase 'final-fast-selection.txt')).Trim()
& (Join-Path $taskBase 'run-suite.ps1') -Label final-fast -Selection $taskSelection
$taskState.fastExitCode=$LASTEXITCODE
if ($taskState.fastExitCode -eq 0) {
  $taskState.state='running_pg';Save-TaskState
  $taskSelection=(Get-Content -Raw -LiteralPath (Join-Path $taskBase 'final-pg-selection.txt')).Trim()
  & (Join-Path $taskBase 'run-suite.ps1') -Label final-pg -Selection $taskSelection
  $taskState.pgExitCode=$LASTEXITCODE
  if ($taskState.pgExitCode -eq 0) {
    $taskState.state='sealing';Save-TaskState
    $env:PYTHONIOENCODING='utf-8'
    & 'C:/Program Files/LibreOffice/program/python.exe' (Join-Path $taskBase 'seal-current.py') *> (Join-Path $taskBase 'seal.log')
    $taskState.sealExitCode=$LASTEXITCODE
    Get-Content -LiteralPath (Join-Path $taskBase 'seal.log') -Tail 8
  }
}
$taskCode=if ($taskState.fastExitCode -eq 0 -and $taskState.pgExitCode -eq 0 -and $taskState.sealExitCode -eq 0) { 0 } else { 1 }
$taskState.state='completed';$taskState.actualExitCode=$taskCode;$taskState.completedAtUtc=[DateTime]::UtcNow.ToString('o');Save-TaskState
exit $taskCode
