param([Parameter(Mandatory)][string]$Attempt,[string]$BuildDirectory)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
if(!$BuildDirectory){$BuildDirectory=Join-Path $PSScriptRoot 'build'}
$output=Join-Path $PSScriptRoot "downloads/$Attempt"
$probes=Join-Path $PSScriptRoot "probes/$Attempt"
$tmp=Join-Path $PSScriptRoot "tmp/$Attempt"
$log=Join-Path $PSScriptRoot "logs/physical-$Attempt.log"
if(Test-Path -LiteralPath $log){throw 'Preserve the previous attempt.'}
$report=Get-ChildItem -LiteralPath (Join-Path $BuildDirectory 'surefire-reports') -Filter 'TEST-*.xml' | Select-Object -First 1
if(!$report){throw 'Run the actual candidate Maven validation first.'}
$xml=[xml](Get-Content -LiteralPath $report.FullName -Raw)
$jars=(($xml.testsuite.properties.property | Where-Object name -eq 'java.class.path').value -split ';') | Where-Object {$_ -like '*.jar' -and $_ -like '*\.m2\repository\*'}
foreach($dependency in $jars){if(!(Test-Path -LiteralPath $dependency)){throw "Missing dependency: $dependency"}}
New-Item -ItemType Directory -Force $output,$probes,$tmp | Out-Null
$env:TMP=$tmp; $env:TEMP=$tmp
$cp=(@($probes,(Join-Path $BuildDirectory 'classes'))+$jars)-join ';'
$argsFile=Join-Path $probes 'javac.args'
@('-encoding','UTF-8','-proc:none','-classpath',('"'+($cp -replace '\\','/')+'"'),'-d',('"'+($probes -replace '\\','/')+'"'),('"'+((Join-Path $PSScriptRoot 'PhysicalXlsxScale.java') -replace '\\','/')+'"')) | Set-Content -LiteralPath $argsFile -Encoding utf8NoBOM
& javac "@$argsFile" *> (Join-Path $PSScriptRoot "logs/physical-$Attempt-compile.log")
if($LASTEXITCODE){exit $LASTEXITCODE}
$runtimeArgs=Join-Path $probes 'java.args'
@('-ea','-Xmx2304m',('-Djava.io.tmpdir="'+($tmp -replace '\\','/')+'"'),'-Dfile.encoding=UTF-8','-classpath',('"'+($cp -replace '\\','/')+'"'),'remediation.PhysicalXlsxScale',('"'+($output -replace '\\','/')+'"')) | Set-Content -LiteralPath $runtimeArgs -Encoding utf8NoBOM
& java "@$runtimeArgs" *> $log
$code=$LASTEXITCODE
@{source=(git -C $root rev-parse HEAD);buildDirectory=$BuildDirectory;attempt=$Attempt;exit=$code;fingerprintBytes='raw-file'} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot "physical-$Attempt.json") -Encoding utf8NoBOM
exit $code
