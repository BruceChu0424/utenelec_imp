param([string]$CandidateBuild=(Join-Path $PSScriptRoot 'parse-suite/build'),[string]$RunName='v3-persisted-five-kinds',[ValidateSet('finance','contracts','goods')][string]$Group='finance')
$ErrorActionPreference='Stop'
$base=$PSScriptRoot.Replace('\','/');$CandidateBuild=$CandidateBuild.Replace('\','/')
if(Test-Path "$base/$RunName.log"){throw 'Preserve existing execution log'}
$xml=[xml](Get-Content -LiteralPath "$CandidateBuild/surefire-reports/TEST-com.uten.imp.common.importing.ImportColumnGuardTest.xml" -Raw)
$jars=(($xml.testsuite.properties.property | Where-Object name -eq 'java.class.path').value -split ';') | Where-Object {$_ -like '*.jar' -and $_ -like '*\.m2\repository\*'}
$dest="$base/$RunName-classes";$tmp="$base/$RunName-tmp"
New-Item -ItemType Directory -Force $dest,$tmp | Out-Null
$raw=(@($dest,"$CandidateBuild/test-classes","$CandidateBuild/classes")+$jars)-join ';';$cp='"'+($raw -replace '\\','/')+'"'
@('-encoding','UTF-8','-proc:none','-classpath',$cp,'-d',('"'+$dest+'"'),('"'+$base+'/CandidateImportSuite.java"')) | Set-Content "$dest/javac.args" -Encoding utf8NoBOM
& javac "@$dest/javac.args" *> "$base/$RunName-compile.log"
if($LASTEXITCODE){exit $LASTEXITCODE}
$env:TEMP=$tmp;$env:TMP=$tmp;$env:UTEN_RUN_DB_TESTS='true'
$agent=($jars | Where-Object {$_ -like '*mockito-core-*.jar'} | Select-Object -First 1).Replace('\','/')
$classes=if($Group -eq 'contracts'){@('com.uten.imp.businesschain.FinanceChartImportOriginalCommandsPostgresTest','com.uten.imp.migration.FinanceChartImportIntentUpgradePostgresTest')}elseif($Group -eq 'goods'){@('com.uten.imp.features.master.goods.importing.GoodsImportHistoryPostgresTest','com.uten.imp.features.master.goods.GoodsBomImportStatePostgresTest')}else{@('com.uten.imp.features.master.goods.costing.GoodsCostImportRemappingPostgresTest','com.uten.imp.features.finance.gl.FinanceExpenseAnalysisPostgresTest','com.uten.imp.businesschain.FinanceChartImportPostgresTest','com.uten.imp.businesschain.FinanceAuxiliaryPostgresTest','com.uten.imp.businesschain.FinanceAccountingContinuationPostgresTest')}
@('-ea','-Xmx3g','-Dfile.encoding=UTF-8','-Dstdout.encoding=UTF-8','-Dstderr.encoding=UTF-8',('"-javaagent:'+$agent+'"'),('-Djava.io.tmpdir='+$tmp),('-Duten.storage.local-dir='+$tmp+'/storage'),('-Dlogging.file.name='+$base+'/'+$RunName+'-spring.log'),'-classpath',$cp,'audit.CandidateImportSuite')+$classes | Set-Content "$dest/java.args" -Encoding utf8NoBOM
& java "@$dest/java.args" *> "$base/$RunName.log"
$LASTEXITCODE | Set-Content "$base/$RunName.exit"
exit $LASTEXITCODE
