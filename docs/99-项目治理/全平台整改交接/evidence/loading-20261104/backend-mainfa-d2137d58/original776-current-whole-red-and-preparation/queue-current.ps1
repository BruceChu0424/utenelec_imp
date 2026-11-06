$ErrorActionPreference='Stop'
$PSNativeCommandUseErrorActionPreference=$false
$taskBase='build/loading-validation/main-fa-final'
$taskState=[ordered]@{state='waiting_compile';startedAtUtc=[DateTime]::UtcNow.ToString('o');completedAtUtc=$null;actualExitCode=$null;wrapperPid=$PID;compileExitCode=$null;fastExitCode=$null;pgExitCode=$null;sealExitCode=$null}
function Save-TaskState { $taskState | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $taskBase 'queue-execution.json') -Encoding utf8 }
if (Test-Path -LiteralPath (Join-Path $taskBase 'queue-execution.json')) { throw 'Existing queue receipt must not be overwritten' }
Save-TaskState
while ($true) {
  $taskCompile=Get-Content -Raw -LiteralPath (Join-Path $taskBase 'compile-execution.json') | ConvertFrom-Json
  if ($taskCompile.state -ne 'running') { break }
  Start-Sleep -Seconds 2
}
$taskState.compileExitCode=$taskCompile.actualExitCode
if ($taskCompile.state -ne 'completed' -or $taskCompile.actualExitCode -ne 0) {
  $taskState.state='completed_compile_failed';$taskState.actualExitCode=1;$taskState.completedAtUtc=[DateTime]::UtcNow.ToString('o');Save-TaskState;exit 1
}
foreach ($taskLabel in @('current-fast','current-pg')) {
  $taskState.state='running_'+$taskLabel;Save-TaskState
  $taskSelection=(Get-Content -Raw -LiteralPath (Join-Path $taskBase ($taskLabel+'-selection.txt'))).Trim()
  & (Join-Path $taskBase 'run-suite.ps1') -Label $taskLabel -Selection $taskSelection
  if ($taskLabel -eq 'current-fast') { $taskState.fastExitCode=$LASTEXITCODE } else { $taskState.pgExitCode=$LASTEXITCODE }
  Save-TaskState
}
$taskState.state='sealing';Save-TaskState
& 'C:/Program Files/LibreOffice/program/python.exe' (Join-Path $taskBase 'seal-current.py') *> (Join-Path $taskBase 'seal.log')
$taskState.sealExitCode=$LASTEXITCODE
$taskCode=if ($taskState.fastExitCode -eq 0 -and $taskState.pgExitCode -eq 0 -and $taskState.sealExitCode -eq 0) { 0 } else { 1 }
$taskState.state='completed';$taskState.actualExitCode=$taskCode;$taskState.completedAtUtc=[DateTime]::UtcNow.ToString('o');Save-TaskState
Get-Content -LiteralPath (Join-Path $taskBase 'seal.log') -Tail 8
exit $taskCode
