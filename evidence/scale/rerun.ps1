param([Parameter(Mandatory)][string]$WorkspaceRoot,
      [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]+$')][string]$RunName,
      [ValidateSet('preverification','final-unified')][string]$Kind='preverification')
$ErrorActionPreference='Stop'
$workspace=[IO.Path]::GetFullPath($WorkspaceRoot)
$out=Join-Path $PSScriptRoot "runs/$RunName"
if(Test-Path -LiteralPath $out){throw 'Keep previous evidence; choose a fresh run name.'}
New-Item -ItemType Directory -Force "$out/tmp","$out/logs","$out/artifacts" | Out-Null
$sourceStart=(git -C $workspace rev-parse HEAD)
$dirty=@(git -C $workspace diff --name-only HEAD -- server/src server/pom.xml)
$untracked=@(git -C $workspace ls-files --others --exclude-standard -- server/src)
if($dirty.Count -or $untracked.Count){throw 'Freeze the actual server source before this candidate replay.'}
@{sourceStart=$sourceStart;kind=$Kind;workspace=$workspace;sourceTrees=@{
  main=(git -C $workspace rev-parse 'HEAD:server/src/main');tests=(git -C $workspace rev-parse 'HEAD:server/src/test');pom=(git -C $workspace rev-parse 'HEAD:server/pom.xml')
}}|ConvertTo-Json -Depth 4|Set-Content -LiteralPath "$out/source-start.json" -Encoding utf8NoBOM
$env:TEMP="$out/tmp";$env:TMP=$env:TEMP;$env:UTEN_RUN_DB_TESTS='true'
$env:MAVEN_OPTS="-Xmx1800m -Djava.io.tmpdir=$env:TEMP"
$selector='MasterDirectoryExportPostgresTest#mouldTaskKeepsReverseQuantityOrderAndExactDecimalText+fiftyThousandAndOneRealSelectedMouldsExcludeAnotherMatchingRowAndKeepOrder,CompleteExportScalePostgresTest#hundredThousandAuthoritativeRowsMatchIndependentSqlOrderAndExactAmounts,ExportSelectionBudgetTest,ExportRowSelectionTest,MasterExportSelectionAspectTest,ReportExportQueuePostgresTest#cancellationRetainsTheWorkerSlotUntilAcknowledgedAndCannotPublish+taskIdentityRequestAndExpiryHistoryRemainImmutable+rollbackDoesNotLeaveAPartiallySubmittedTask+workerKeepsOneRealSnapshotAcrossPagesAndDownloadRechecksAuthorization'
& mvn.cmd -o -B -ntp -f "$workspace/server/pom.xml" "-Duten.build.directory=$out/build" "-Duten.test.tmpdir=$env:TEMP" "-Duten.export.evidence.directory=$out/artifacts" '-Duten.test.jvm.heap.args=-Xmx3g' '-Duten.test.context.cache.maxSize=1' '-DforkCount=1' '-DreuseForks=true' "-Dtest=$selector" test *> "$out/logs/maven.log"
$maven=$LASTEXITCODE;$maven|Set-Content -LiteralPath "$out/logs/maven.exit"
if(Test-Path -LiteralPath "$out/build/surefire-reports"){Copy-Item -LiteralPath "$out/build/surefire-reports" -Destination "$out/reports" -Recurse}
$sourceEnd=(git -C $workspace rev-parse HEAD)
@{sourceStart=$sourceStart;sourceEnd=$sourceEnd;kind=$Kind;exit=$maven;sourceUnchanged=($sourceStart-eq$sourceEnd)}|ConvertTo-Json|Set-Content -LiteralPath "$out/source-end.json" -Encoding utf8NoBOM
if($sourceStart-ne$sourceEnd){throw 'Source changed during the replay; keep this run but do not claim final unified acceptance.'}
exit $maven
