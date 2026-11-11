$base='D:/Projects/uten_imp_worktrees/feedback-remediate-c-20261110/evidence/imports'
$old='D:/Projects/uten_imp_worktrees/feedback-audit-20261110/audit/import-export/build'
$xml=[xml](Get-Content -LiteralPath "$old/surefire-reports/TEST-com.uten.imp.common.importing.ImportColumnGuardTest.xml" -Raw)
$jars=(($xml.testsuite.properties.property | Where-Object name -eq 'java.class.path').value -split ';') | Where-Object {$_ -like '*.jar' -and $_ -like '*\.m2\repository\*'}
$dest="$base/normal-classes";New-Item -ItemType Directory -Force $dest | Out-Null
$rawCp=(@($dest,"$old/test-classes","$old/classes")+$jars)-join ';'
$cp='"'+($rawCp -replace '\\','/')+'"'
@('-encoding','UTF-8','-proc:none','-classpath',$cp,'-d',('"'+$dest+'"'),('"'+$base+'/NormalWorkbooks.java"')) | Set-Content "$dest/javac.args" -Encoding utf8NoBOM
& javac "@$dest/javac.args" *> "$base/normal-compile.log"
if($LASTEXITCODE){exit $LASTEXITCODE}
@('-Dfile.encoding=UTF-8','-classpath',$cp,'audit.NormalWorkbooks',$base) | Set-Content "$dest/java.args" -Encoding utf8NoBOM
& java "@$dest/java.args" *> "$base/normal.log"
exit $LASTEXITCODE
