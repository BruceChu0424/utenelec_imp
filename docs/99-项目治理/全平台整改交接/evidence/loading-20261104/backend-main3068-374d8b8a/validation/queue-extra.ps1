$ErrorActionPreference='Stop'
$PSNativeCommandUseErrorActionPreference=$false
$taskBase='build/loading-validation/main-3068-output-fixed'
$taskState=[ordered]@{state='waiting_core_queue';startedAtUtc=[DateTime]::UtcNow.ToString('o');completedAtUtc=$null;actualExitCode=$null;wrapperPid=$PID}
$taskState | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $taskBase 'extra-queue-execution.json') -Encoding utf8
while ($true) {
  $taskCore=Get-Content -Raw -LiteralPath (Join-Path $taskBase 'queue-execution.json') | ConvertFrom-Json
  if ($taskCore.state -eq 'completed') { break }
  Start-Sleep -Seconds 1
}
if ($taskCore.actualExitCode -ne 0) { throw 'Core current61 native/sealer did not complete0; do not start extra consumers' }
$taskState.state='running_final_extra';$taskState | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $taskBase 'extra-queue-execution.json') -Encoding utf8
& (Join-Path $taskBase 'close-cost-stage.ps1')
$taskCode=$LASTEXITCODE
$taskState.state='completed';$taskState.actualExitCode=$taskCode;$taskState.completedAtUtc=[DateTime]::UtcNow.ToString('o')
$taskState | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $taskBase 'extra-queue-execution.json') -Encoding utf8
exit $taskCode
