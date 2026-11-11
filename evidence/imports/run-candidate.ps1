param([string]$workspaceRoot='D:/Projects/uten_imp_worktrees/feedback-remediate-c-20261110',[string]$runName='maven-current')
$ErrorActionPreference='Stop'
$stem=Join-Path $workspaceRoot ("evidence/imports/"+$runName)
$base=$stem;$sequence=1
while(Test-Path "$base/maven.log"){$sequence++;$base="$stem-$sequence"}
New-Item -ItemType Directory -Force "$base/tmp" | Out-Null
Set-Location (Join-Path $workspaceRoot 'server')
$env:TEMP="$base/tmp"; $env:TMP=$env:TEMP
$env:UTEN_RUN_DB_TESTS='true'
$env:MAVEN_OPTS="-Xmx2304m -Djava.io.tmpdir=$env:TEMP"
$tests='WorkbookColumnRemediationTest,CostTitleColumnRemediationTest,AdditionalSheetColumnRemediationTest,ImportColumnGuardTest,PlatformWorkbookSchemaTest,GoodsCostWorkbookParserTest,GoodsImportColumnContractTest,GoodsBomImportColumnContractTest,GoodsImportPlanSafetyTest,FinanceOperatingNoteParserTest,FinanceChartWorkbookParserTest,FinanceAccountingWorkbookParserTest,FinanceAuxiliaryWorkbookParserTest,GoodsCostImportRemappingPostgresTest,FinanceExpenseAnalysisPostgresTest,FinanceChartImportPostgresTest,FinanceAccountingContinuationPostgresTest,FinanceAuxiliaryPostgresTest,GoodsImportHistoryPostgresTest,GoodsBomImportStatePostgresTest'
& mvn.cmd -B -ntp "-Duten.build.directory=$base/build" "-Dtest=$tests" "-Duten.test.tmpdir=$env:TEMP" '-Duten.test.jvm.heap.args=-Xmx3g' '-DforkCount=1' '-DreuseForks=true' test *> "$base/maven.log"
$LASTEXITCODE | Set-Content "$base/exit.txt"
exit $LASTEXITCODE
