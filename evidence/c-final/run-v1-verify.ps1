param([string]$CandidateBuild=(Join-Path $PSScriptRoot 'parse-suite/build'),[string]$RunName='v3-retained-v1-verify',[ValidateSet('verify','files')][string]$Phase='verify')
$ErrorActionPreference='Stop'
$base=$PSScriptRoot.Replace('\','/');$CandidateBuild=$CandidateBuild.Replace('\','/')
$previous='D:/Projects/uten_imp_worktrees/feedback-remediate-c-20261110/evidence/imports'
if(Test-Path "$base/$RunName.log"){throw 'Preserve existing execution log'}
$xml=[xml](Get-Content -LiteralPath "$CandidateBuild/surefire-reports/TEST-com.uten.imp.common.importing.ImportColumnGuardTest.xml" -Raw)
$jars=(($xml.testsuite.properties.property | Where-Object name -eq 'java.class.path').value -split ';') | Where-Object {$_ -like '*.jar' -and $_ -like '*\.m2\repository\*'}
$dest="$base/$RunName-classes";$tmp="$base/$RunName-tmp"
New-Item -ItemType Directory -Force $dest,$tmp | Out-Null
$raw=(@($dest,"$CandidateBuild/test-classes","$CandidateBuild/classes")+$jars)-join ';';$cp='"'+($raw -replace '\\','/')+'"'
@('-encoding','UTF-8','-proc:none','-classpath',$cp,'-d',('"'+$dest+'"'),('"'+$base+'/ImportVersionUpgradeAudit.java"')) | Set-Content "$dest/javac.args" -Encoding utf8NoBOM
& javac "@$dest/javac.args" *> "$base/$RunName-compile.log"
if($LASTEXITCODE){exit $LASTEXITCODE}
$env:TEMP=$tmp;$env:TMP=$tmp
@('-ea','-Xmx2g','-Dfile.encoding=UTF-8','-Dstdout.encoding=UTF-8','-Dstderr.encoding=UTF-8',('-Djava.io.tmpdir='+$tmp),('-Daudit.dir='+$previous),('-Daudit.log='+$base),('-Daudit.phase='+$Phase),('-Daudit.run='+$RunName),'-classpath',$cp,'com.uten.imp.businesschain.ImportVersionUpgradeAudit') | Set-Content "$dest/java.args" -Encoding utf8NoBOM
& java "@$dest/java.args" *> "$base/$RunName.log"
$LASTEXITCODE | Set-Content "$base/$RunName.exit"
exit $LASTEXITCODE
