param([Parameter(Mandatory=$true)][string]$Label,[Parameter(Mandatory=$true)][string]$Selection)
$ErrorActionPreference='Stop'
$PSNativeCommandUseErrorActionPreference=$false
if ($Label -notmatch '^[a-zA-Z0-9_-]+$') { throw 'Unsafe evidence label' }
$taskEvidenceRoot='build/loading-validation/main-fa-final'
$taskSource=Get-Content -Raw -LiteralPath (Join-Path $taskEvidenceRoot 'complete-source-input.json') | ConvertFrom-Json
& 'C:/Program Files/LibreOffice/program/python.exe' 'build/loading-validation/main-fa-final/verify-source.py' *> 'build/loading-validation/main-fa-final/run-suite-source-preflight.log'
if ($LASTEXITCODE -ne 0) { throw 'Complete source preflight refused drift' }
$env:UTEN_RUN_DB_TESTS='true'
$env:UTEN_PYTHON_EXECUTABLE='C:/Program Files/LibreOffice/program/python.exe'
$env:MAVEN_OPTS='-Xmx2g'
$env:UTEN_LOADING_BENCHMARK_REPORT=Join-Path $taskEvidenceRoot ($Label+'-empty-latency.json')
$taskArguments=@('-Duten.build.directory=target-loading-main-fa-final','-Duten.test.jvm.heap.args=-Xmx3g',
  '-Duten.test.context.cache.maxSize=2',
  '-Duten.exportFlywayChecksums=true',
  "-Duten.loading.measurement.directory=$taskEvidenceRoot/$Label-growth",
  "-Duten.jdbc.measurement.trace-directory=$taskEvidenceRoot/$Label-measurements",
  "-Dtest=$Selection",'surefire:test')
$taskLog=Join-Path $taskEvidenceRoot ($Label+'.log')
$taskStatusPath=Join-Path $taskEvidenceRoot ($Label+'-execution.json')
$taskState=[ordered]@{label=$Label;state='running';startedAtUtc=[DateTime]::UtcNow.ToString('o');completedAtUtc=$null;
  actualExitCode=$null;sourceAggregateSha256=$taskSource.aggregateSha256;upstreamMainHead=$taskSource.upstreamMainHead;
  command='mvn';arguments=$taskArguments;selection=$Selection;wrapperPid=$PID;log=$taskLog;
  environment=@{UTEN_RUN_DB_TESTS='true';MAVEN_OPTS='-Xmx2g'}}
$taskState | ConvertTo-Json -Depth 6 | Set-Content -Encoding utf8 -LiteralPath $taskStatusPath
try {
  & mvn @taskArguments *> $taskLog
  $taskExitCode=$LASTEXITCODE
  $taskState.actualExitCode=$taskExitCode
  $taskState.state='completed'
} catch {
  $taskExitCode=99
  $taskState.state='wrapper_error'
  $taskState.error=$_.Exception.Message
} finally {
  $taskState.completedAtUtc=[DateTime]::UtcNow.ToString('o')
  $taskState | ConvertTo-Json -Depth 6 | Set-Content -Encoding utf8 -LiteralPath $taskStatusPath
}
$taskReceiptDirectory=Join-Path $taskEvidenceRoot ($Label+'-receipt')
New-Item -ItemType Directory -Path $taskReceiptDirectory -Force | Out-Null
Copy-Item -LiteralPath $taskLog -Destination (Join-Path $taskReceiptDirectory 'maven.log')
Copy-Item -LiteralPath $taskStatusPath -Destination (Join-Path $taskReceiptDirectory 'execution.json')
Copy-Item -LiteralPath (Join-Path $taskEvidenceRoot 'complete-source-input.json') -Destination (Join-Path $taskReceiptDirectory 'complete-source-input.json')
Copy-Item -LiteralPath (Join-Path $taskEvidenceRoot 'complete-source-input.json') -Destination (Join-Path $taskReceiptDirectory 'complete-input-inventory.json')
foreach ($taskClass in ($Selection -split ',')) {
  $taskSimpleClass=($taskClass -split '\.')[-1]
  Get-ChildItem -LiteralPath 'target-loading-main-fa-final/surefire-reports' -File -Filter ("TEST-*.$taskSimpleClass.xml") |
    ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $taskReceiptDirectory $_.Name) }
}
Get-Content -LiteralPath $taskLog -Tail 12
exit $taskExitCode
