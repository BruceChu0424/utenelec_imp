param([ValidateSet('compile','parsers','db','goods','cost','legacy')]$group='compile')
$ErrorActionPreference='Stop'
$root='D:/Projects/uten_imp_worktrees/feedback-remediate-c-20261110'
$base="$root/evidence/imports/candidate-2"
$prior="$root/evidence/imports/candidate-1/build"
$xml=[xml](Get-Content -LiteralPath 'D:/Projects/uten_imp_worktrees/feedback-audit-20261110/audit/import-export/build/surefire-reports/TEST-com.uten.imp.common.importing.ImportColumnGuardTest.xml' -Raw)
$jars=(($xml.testsuite.properties.property | Where-Object name -eq 'java.class.path').value -split ';') | Where-Object {$_ -like '*.jar' -and $_ -like '*\.m2\repository\*'}
$main="$base/classes"; $test="$base/test-classes"; $tmp="$base/tmp-$group"
New-Item -ItemType Directory -Force $main,$test,$tmp | Out-Null
$rawCp=(@($test,$main,"$prior/test-classes","$prior/classes")+$jars)-join ';'
$cp='"'+($rawCp -replace '\\','/')+'"'
$env:TEMP=$tmp;$env:TMP=$tmp;$env:UTEN_RUN_DB_TESTS='true'
if($group -eq 'compile') {
 Set-Location $root
 $sources=@(git diff fdeda88b3 --name-only -- 'server/src/main/java/*.java' 'server/src/main/java/**/*.java')
 $sources += @(git ls-files --others --exclude-standard -- 'server/src/main/java/*.java' 'server/src/main/java/**/*.java')
 $processor='lombok.launch.AnnotationProcessorHider$AnnotationProcessor'
 @('--release','21','-parameters','-encoding','UTF-8','-processor',$processor,'-classpath',$cp,'-d',('"'+$main+'"')) + @($sources | ForEach-Object {'"'+$root+'/'+($_ -replace '\\','/')+'"'}) | Set-Content "$base/main-javac.args" -Encoding utf8NoBOM
 & javac "@$base/main-javac.args" *> "$base/main-compile.log"
 if($LASTEXITCODE){exit $LASTEXITCODE}
 $tests=@(git diff fdeda88b3 --name-only -- 'server/src/test/java/*.java' 'server/src/test/java/**/*.java')
 $tests += @(git ls-files --others --exclude-standard -- 'server/src/test/java/*.java' 'server/src/test/java/**/*.java')
 $tests += 'evidence/imports/CandidateImportSuite.java'
 @('--release','21','-parameters','-encoding','UTF-8','-proc:none','-classpath',$cp,'-d',('"'+$test+'"')) + @($tests | ForEach-Object {'"'+$root+'/'+($_ -replace '\\','/')+'"'}) | Set-Content "$base/test-javac.args" -Encoding utf8NoBOM
 & javac "@$base/test-javac.args" *> "$base/test-compile.log"
 exit $LASTEXITCODE
}
$classes=if($group -eq 'parsers'){@(
 'com.uten.imp.features.finance.gl.WorkbookColumnRemediationTest',
 'com.uten.imp.features.master.goods.costing.CostTitleColumnRemediationTest',
 'com.uten.imp.features.master.goods.importing.AdditionalSheetColumnRemediationTest',
 'com.uten.imp.common.importing.ImportColumnGuardTest','com.uten.imp.common.export.PlatformWorkbookSchemaTest',
 'com.uten.imp.features.master.goods.costing.GoodsCostWorkbookParserTest',
 'com.uten.imp.features.master.goods.importing.GoodsImportColumnContractTest',
 'com.uten.imp.features.master.goods.importing.GoodsBomImportColumnContractTest',
 'com.uten.imp.features.master.goods.importing.GoodsImportPlanSafetyTest',
 'com.uten.imp.features.finance.gl.FinanceOperatingNoteParserTest','com.uten.imp.features.finance.gl.FinanceChartWorkbookParserTest',
 'com.uten.imp.features.finance.gl.FinanceAccountingWorkbookParserTest',
 'com.uten.imp.features.finance.statement.FinanceAuxiliaryWorkbookParserTest'
)}elseif($group -eq 'goods'){@('com.uten.imp.features.master.goods.importing.GoodsImportHistoryPostgresTest','com.uten.imp.features.master.goods.GoodsBomImportStatePostgresTest')}
elseif($group -eq 'cost'){@('com.uten.imp.features.master.goods.costing.GoodsCostImportRemappingPostgresTest')}
elseif($group -eq 'legacy'){@('com.uten.imp.features.master.goods.importing.GoodsImportHistoryPostgresTest')}
else{@('com.uten.imp.features.master.goods.costing.GoodsCostImportRemappingPostgresTest','com.uten.imp.businesschain.FinanceChartImportPostgresTest','com.uten.imp.businesschain.FinanceAuxiliaryPostgresTest','com.uten.imp.businesschain.FinanceAccountingContinuationPostgresTest','com.uten.imp.features.finance.gl.FinanceExpenseAnalysisPostgresTest')}
$agent=$jars | Where-Object {$_ -like '*mockito-core-*.jar'} | Select-Object -First 1
@('-ea','-Xmx2304m','-Dfile.encoding=UTF-8','-Dstdout.encoding=UTF-8','-Dstderr.encoding=UTF-8',('"-javaagent:'+($agent -replace '\\','/')+'"'),('-Djava.io.tmpdir='+$tmp),('-Duten.storage.local-dir='+$tmp+'/storage'),('-Dlogging.file.name='+$base+'/spring-'+$group+'.log'),'-classpath',$cp,'audit.CandidateImportSuite') + $classes | Set-Content "$base/java-$group.args" -Encoding utf8NoBOM
& java "@$base/java-$group.args" *> "$base/$group.log"
$LASTEXITCODE | Set-Content "$base/$group.exit"
exit $LASTEXITCODE
