param([Parameter(Mandatory)][string]$Attempt,[switch]$Trace,[string]$Method='twentyMaterialLinesCompleteWithinDeadlineBudget')
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$sourceStart=(git -C $root rev-parse HEAD)
$build=Join-Path $PSScriptRoot 'build-integrated-1'
$report=Join-Path $build 'surefire-reports/TEST-com.uten.imp.common.export.ExportSelectionBudgetTest.xml'
$xml=[xml](Get-Content -LiteralPath $report -Raw)
$jars=(($xml.testsuite.properties.property|Where-Object name -eq 'java.class.path').value -split ';')|Where-Object {$_ -like '*.jar' -and $_ -like '*\.m2\repository\*'}
$overlay=Join-Path $PSScriptRoot "probes/$Attempt"
$tmp=Join-Path $PSScriptRoot "tmp/$Attempt"
$log=Join-Path $PSScriptRoot "logs/$Attempt.log"
if(Test-Path -LiteralPath $log){throw 'Preserve previous diagnostic attempts.'}
New-Item -ItemType Directory -Force $overlay,$tmp | Out-Null
$cp=(@($overlay,(Join-Path $build 'test-classes'),(Join-Path $build 'classes'))+$jars)-join ';'
$sources=@(
  (Join-Path $root 'server/src/main/java/com/uten/imp/features/production/analysis/MaterialAnalysisService.java'),
  (Join-Path $root 'server/src/main/java/com/uten/imp/features/production/analysis/AggregateMaterialOrderWriteService.java'),
  (Join-Path $root 'server/src/main/java/com/uten/imp/features/production/analysis/AggregateMaterialOrderPreviewService.java'),
  (Join-Path $root 'server/src/test/java/com/uten/imp/businesschain/AggregateMaterialOrderEndToEndTest.java'),
  (Join-Path $PSScriptRoot 'BudgetSuite.java')
)
$javacArgs=Join-Path $overlay 'javac.args'
@('-encoding','UTF-8','-g','-parameters','--release','21','-processor','lombok.launch.AnnotationProcessorHider$AnnotationProcessor','-classpath',('"'+($cp -replace '\\','/')+'"'),'-d',('"'+($overlay -replace '\\','/')+'"'))+@($sources|ForEach-Object {'"'+($_ -replace '\\','/')+'"'})|Set-Content -LiteralPath $javacArgs -Encoding utf8NoBOM
& javac "@$javacArgs" *> (Join-Path $PSScriptRoot "logs/$Attempt-compile.log")
if($LASTEXITCODE){exit $LASTEXITCODE}
$agent=$jars|Where-Object {$_ -like '*\mockito-core-*.jar'}|Select-Object -First 1
$javaArgs=Join-Path $overlay 'java.args'
$argsList=@('-ea','-Xmx2304m','-Xshare:off','-Dfile.encoding=UTF-8',('-Djava.io.tmpdir="'+($tmp -replace '\\','/')+'"'),('"-javaagent:'+($agent -replace '\\','/')+'"'),'-classpath',('"'+($cp -replace '\\','/')+'"'))
$argsList+=@(('"-Dlogging.file.name='+($overlay -replace '\\','/')+'/spring.log"'),'-Dspring.test.context.cache.maxSize=8')
if($Trace){$argsList+=('"-Duten.jdbc.measurement.trace-directory='+($PSScriptRoot -replace '\\','/')+'/'+$Attempt+'-trace"')}
$argsList+=@('remediation.BudgetSuite',$Method)
$argsList|Set-Content -LiteralPath $javaArgs -Encoding utf8NoBOM
$env:UTEN_RUN_DB_TESTS='true';$env:TMP=$tmp;$env:TEMP=$tmp
Push-Location (Join-Path $root 'server')
try {& java "@$javaArgs" *> $log;$code=$LASTEXITCODE}finally{Pop-Location}
@{sourceStart=$sourceStart;sourceEnd=(git -C $root rev-parse HEAD);attempt=$Attempt;exit=$code;compilation='task-owned incremental overlay; final acceptance still requires clean final-SHA compilation'}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $PSScriptRoot "$Attempt.json") -Encoding utf8NoBOM
exit $code
