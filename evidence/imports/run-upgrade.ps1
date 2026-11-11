param([ValidateSet('seed','seed-retry','seed-resume','finish-seed','verify','files')]$phase='seed',[string]$candidateBuild='')
$ErrorActionPreference='Stop'
$base='D:/Projects/uten_imp_worktrees/feedback-remediate-c-20261110/evidence/imports'
$runName=$phase;$sequence=1
while(Test-Path "$base/upgrade-$runName.log"){$sequence++;$runName="$phase-$sequence"}
$old='D:/Projects/uten_imp_worktrees/feedback-audit-20261110/audit/import-export/build'
$xml=[xml](Get-Content -LiteralPath "$old/surefire-reports/TEST-com.uten.imp.common.importing.ImportColumnGuardTest.xml" -Raw)
$jars=(($xml.testsuite.properties.property | Where-Object name -eq 'java.class.path').value -split ';') | Where-Object {$_ -like '*.jar' -and $_ -like '*\.m2\repository\*'}
$build=if($phase -notin @('verify','files')){$old}elseif($candidateBuild){$candidateBuild}else{"$base/candidate-1/build"}
$dest="$base/upgrade-$runName-classes"; $tmp="$base/upgrade-$runName-tmp"
New-Item -ItemType Directory -Force $dest,$tmp | Out-Null
$overlays=if($phase -in @('verify','files') -and !$candidateBuild){@("$base/candidate-2/test-classes","$base/candidate-2/classes")}else{@()}
$cp=(@($dest)+$overlays+@("$build/test-classes","$build/classes")+$jars)-join ';'
$cp='"'+($cp -replace '\\','/')+'"'
@('-encoding','UTF-8','-proc:none','-classpath',$cp,'-d',('"'+$dest+'"'),('"'+$base+'/ImportVersionUpgradeAudit.java"')) | Set-Content "$dest/javac.args" -Encoding utf8NoBOM
& javac "@$dest/javac.args" *> "$base/upgrade-$runName-compile.log"
if($LASTEXITCODE){exit $LASTEXITCODE}
$env:TEMP=$tmp; $env:TMP=$tmp
@('-ea','-Xmx2304m','-Dfile.encoding=UTF-8','-Dstdout.encoding=UTF-8','-Dstderr.encoding=UTF-8',('-Djava.io.tmpdir='+$tmp),('-Daudit.dir='+$base),('-Daudit.phase='+$phase),('-Daudit.run='+$runName),'-classpath',$cp,'com.uten.imp.businesschain.ImportVersionUpgradeAudit') | Set-Content "$dest/java.args" -Encoding utf8NoBOM
& java "@$dest/java.args" *> "$base/upgrade-$runName.log"
$LASTEXITCODE | Set-Content "$base/upgrade-$runName.exit"
exit $LASTEXITCODE
