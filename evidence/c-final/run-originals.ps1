param([Parameter(Mandatory)][string]$CandidateBuild,[string]$RunName='final-originals')
$ErrorActionPreference='Stop'
$base=$PSScriptRoot.Replace('\','/');$CandidateBuild=$CandidateBuild.Replace('\','/')
if(Test-Path "$base/$RunName.log"){throw 'Preserve existing execution log'}
$xml=[xml](Get-Content -LiteralPath "$CandidateBuild/surefire-reports/TEST-com.uten.imp.common.importing.ImportColumnGuardTest.xml" -Raw)
$jars=(($xml.testsuite.properties.property | Where-Object name -eq 'java.class.path').value -split ';') | Where-Object {$_ -like '*.jar' -and $_ -like '*\.m2\repository\*'}
$dest="$base/$RunName-classes";New-Item -ItemType Directory -Force $dest | Out-Null
$raw=(@($dest,"$CandidateBuild/classes")+$jars)-join ';';$cp='"'+($raw -replace '\\','/')+'"'
@('-encoding','UTF-8','-proc:none','-classpath',$cp,'-d',('"'+$dest+'"'),('"'+$base+'/OriginalFileRegression.java"')) | Set-Content "$dest/javac.args" -Encoding utf8NoBOM
& javac "@$dest/javac.args" *> "$base/$RunName-compile.log"
if($LASTEXITCODE){exit $LASTEXITCODE}
@('-ea','-Dfile.encoding=UTF-8','-Dstdout.encoding=UTF-8','-Dstderr.encoding=UTF-8','-classpath',$cp,'independent.OriginalFileRegression',('"'+$base+'/originals"')) | Set-Content "$dest/java.args" -Encoding utf8NoBOM
& java "@$dest/java.args" *> "$base/$RunName.log"
$LASTEXITCODE | Set-Content "$base/$RunName.exit"
exit $LASTEXITCODE
