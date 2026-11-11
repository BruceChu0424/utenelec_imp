param([Parameter(Mandatory)][ValidatePattern('^[a-z0-9-]+$')][string]$Attempt,
      [Parameter(Mandatory)][string]$ClassesDirectory,
      [string]$WorkspaceRoot=(Join-Path $PSScriptRoot '../..'),
      [ValidateSet('preverification','final-unified')][string]$Kind='preverification')
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath($WorkspaceRoot)
$sourceStart=(git -C $root rev-parse HEAD)
$out=Join-Path $PSScriptRoot $Attempt
$log=Join-Path $out 'physical.log'
if(Test-Path -LiteralPath $log){throw 'Preserve the previous physical workbook attempt.'}
$probes=Join-Path $out 'probes';$tmp=Join-Path $out 'tmp';$artifacts=Join-Path $out 'artifacts'
New-Item -ItemType Directory -Force $out,$probes,$tmp,$artifacts | Out-Null
$deps=(Get-Content -LiteralPath (Join-Path $PSScriptRoot 'deps-cp.txt') -Raw).Trim()
foreach($jar in $deps.Split(';')){if(!(Test-Path -LiteralPath $jar) -or !$jar.EndsWith('.jar')){throw 'Dependency classpath must contain existing jars only.'}}
$cp=(@($probes,$ClassesDirectory,$deps)-join ';') -replace '\\','/'
$compiler=Join-Path $probes 'javac.args'
@('-encoding','UTF-8','-g','-parameters','--release','21','-proc:none','-classpath',('"'+$cp+'"'),'-d',('"'+($probes -replace '\\','/')+'"'),('"'+((Join-Path $PSScriptRoot 'PhysicalXlsxScale.java') -replace '\\','/')+'"'))|Set-Content -LiteralPath $compiler -Encoding utf8NoBOM
Copy-Item -LiteralPath $compiler -Destination (Join-Path $out 'javac.args')
& javac "@$compiler" *> (Join-Path $out 'compile.log')
if($LASTEXITCODE){exit $LASTEXITCODE}
$runtime=Join-Path $probes 'java.args'
@('-ea','-Xmx2304m','-Xshare:off','-Dfile.encoding=UTF-8',('"-Djava.io.tmpdir='+($tmp -replace '\\','/')+'"'),'-classpath',('"'+$cp+'"'),'remediation.PhysicalXlsxScale',('"'+($artifacts -replace '\\','/')+'"'))|Set-Content -LiteralPath $runtime -Encoding utf8NoBOM
Copy-Item -LiteralPath $runtime -Destination (Join-Path $out 'java.args')
$env:TMP=$tmp;$env:TEMP=$tmp
& java "@$runtime" *> $log
$code=$LASTEXITCODE;$code|Set-Content -LiteralPath (Join-Path $out 'physical.exit')
$book=Join-Path $artifacts 'physical-1048600.xlsx'
$receipt=@{sourceStart=$sourceStart;sourceEnd=(git -C $root rev-parse HEAD);kind=$Kind;workspace=$root;exit=$code;classesDirectory=$ClassesDirectory;workbook=$book;fingerprintBytes='exact raw file bytes';sourceTrees=@{main=(git -C $root rev-parse 'HEAD:server/src/main');pom=(git -C $root rev-parse 'HEAD:server/pom.xml')}}
$writerClass=Join-Path $ClassesDirectory 'com/uten/imp/common/export/XlsxExportService.class'
if(Test-Path -LiteralPath $writerClass){$receipt.compiledWriterSha256=(Get-FileHash -LiteralPath $writerClass -Algorithm SHA256).Hash.ToLowerInvariant()}
if(Test-Path -LiteralPath $book){$receipt.workbookBytes=(Get-Item -LiteralPath $book).Length;$receipt.workbookSha256=(Get-FileHash -LiteralPath $book -Algorithm SHA256).Hash.ToLowerInvariant()}
$receipt|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $out 'receipt.json') -Encoding utf8NoBOM
if($receipt.sourceStart-ne$receipt.sourceEnd){throw 'Source changed during physical replay; this attempt is not final unified acceptance.'}
exit $code
