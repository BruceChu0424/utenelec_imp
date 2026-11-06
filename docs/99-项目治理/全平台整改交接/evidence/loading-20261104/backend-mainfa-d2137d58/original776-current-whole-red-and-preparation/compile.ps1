$ErrorActionPreference='Stop'
$PSNativeCommandUseErrorActionPreference=$false
$taskEvidence='build/loading-validation/main-fa-final'
$taskSource=Get-Content -Raw -LiteralPath (Join-Path $taskEvidence 'complete-source-input.json') | ConvertFrom-Json
& 'C:/Program Files/LibreOffice/program/python.exe' 'build/loading-validation/main-fa-final/verify-source.py' *> 'build/loading-validation/main-fa-final/compile-source-preflight.log'
if ($LASTEXITCODE -ne 0) { throw 'Complete source preflight refused drift' }
$env:MAVEN_OPTS='-Xmx2g'
$taskArgs=@('-Duten.build.directory=target-loading-main-fa-final','-DskipTests','test-compile')
$taskState=[ordered]@{state='running';startedAtUtc=[DateTime]::UtcNow.ToString('o');completedAtUtc=$null;actualExitCode=$null;
  sourceAggregateSha256=$taskSource.aggregateSha256;upstreamMainHead=$taskSource.upstreamMainHead;
  command='mvn';arguments=$taskArgs;wrapperPid=$PID;log=(Join-Path $taskEvidence 'compile.log')}
$taskState | ConvertTo-Json -Depth 5 | Set-Content -Encoding utf8 -LiteralPath (Join-Path $taskEvidence 'compile-execution.json')
try {
  & mvn @taskArgs *> (Join-Path $taskEvidence 'compile.log')
  $taskCode=$LASTEXITCODE
  $taskState.actualExitCode=$taskCode;$taskState.state='completed'
} catch {
  $taskCode=99;$taskState.state='wrapper_error';$taskState.error=$_.Exception.Message
} finally {
  $taskState.completedAtUtc=[DateTime]::UtcNow.ToString('o')
  $taskState | ConvertTo-Json -Depth 5 | Set-Content -Encoding utf8 -LiteralPath (Join-Path $taskEvidence 'compile-execution.json')
}
Get-Content -LiteralPath (Join-Path $taskEvidence 'compile.log') -Tail 12
exit $taskCode
