param(
  [ValidateSet('seed','seed-finance','verify')][string]$Phase,
  [string]$CandidateBuild = '',
  [string]$RunName = ''
)
$ErrorActionPreference='Stop'
$base=$PSScriptRoot.Replace('\','/')
$previous='D:/Projects/uten_imp_worktrees/feedback-remediate-c-20261110/evidence/imports'
if (!$RunName) { $RunName=$Phase+'-'+(Get-Date -Format 'yyyyMMdd-HHmmss') }
$log=Join-Path $base ($RunName+'.log')
if (Test-Path -LiteralPath $log) { throw "Preserve existing log: $log" }
$xml=[xml](Get-Content -LiteralPath "$previous/candidate-1/build/surefire-reports/TEST-com.uten.imp.common.importing.ImportColumnGuardTest.xml" -Raw)
$jars=(($xml.testsuite.properties.property | Where-Object name -eq 'java.class.path').value -split ';') | Where-Object {$_ -like '*.jar' -and $_ -like '*\.m2\repository\*'}
$build=if($Phase -like 'seed*'){Join-Path $base 'old-v2-build'}elseif($CandidateBuild){$CandidateBuild}else{throw 'A separately compiled v3 candidate build is required'}
$dest=(Join-Path $base ($RunName+'-classes')).Replace('\','/');$tmp=(Join-Path $base ($RunName+'-tmp')).Replace('\','/')
New-Item -ItemType Directory -Force $dest,$tmp | Out-Null
$classpath=(@($dest,"$build/test-classes","$build/classes")+$jars)-join ';'
$classpath='"'+($classpath -replace '\\','/')+'"'
@('-encoding','UTF-8','-proc:none','-classpath',$classpath,'-d',('"'+$dest+'"'),('"'+$base+'/CostStructureVersionUpgradeAudit.java"')) | Set-Content "$dest/javac.args" -Encoding utf8NoBOM
& javac "@$dest/javac.args" *> "$base/$RunName-compile.log"
if($LASTEXITCODE){exit $LASTEXITCODE}
$env:TEMP=$tmp;$env:TMP=$tmp
@('-ea','-Xmx2g','-Dfile.encoding=UTF-8','-Dstdout.encoding=UTF-8','-Dstderr.encoding=UTF-8',('-Djava.io.tmpdir='+$tmp),('-Daudit.dir='+$base),('-Daudit.previous='+$previous),('-Daudit.phase='+$Phase),('-Daudit.run='+$RunName),'-classpath',$classpath,'com.uten.imp.businesschain.CostStructureVersionUpgradeAudit') | Set-Content "$dest/java.args" -Encoding utf8NoBOM
& java "@$dest/java.args" *> $log
$LASTEXITCODE | Set-Content "$base/$RunName.exit"
exit $LASTEXITCODE
