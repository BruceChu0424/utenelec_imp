param([Parameter(Mandatory)][string]$WorkspaceRoot,
      [Alias('ExpectedRevision')][string]$FrozenRevision,
      [ValidatePattern('^[a-z0-9][a-z0-9-]*$')][string]$RunTag,
      [switch]$Execute)
$ErrorActionPreference='Stop'
$workspace=[IO.Path]::GetFullPath($WorkspaceRoot)
$selector='MasterDirectoryExportPostgresTest#mouldTaskKeepsReverseQuantityOrderAndExactDecimalText+fiftyThousandAndOneRealSelectedMouldsExcludeAnotherMatchingRowAndKeepOrder,CompleteExportScalePostgresTest#hundredThousandAuthoritativeRowsMatchIndependentSqlOrderAndExactAmounts,ExportSelectionBudgetTest,ExportRowSelectionTest,MasterExportSelectionAspectTest,ReportExportQueuePostgresTest#cancellationRetainsTheWorkerSlotUntilAcknowledgedAndCannotPublish+taskIdentityRequestAndExpiryHistoryRemainImmutable+rollbackDoesNotLeaveAPartiallySubmittedTask+workerKeepsOneRealSnapshotAcrossPagesAndDownloadRechecksAuthorization'
if(!$Execute){
    @{status='prepared-only; no Maven, PG, workbook or acceptance started';workspace=$workspace;
      frozenRevision=$FrozenRevision;runTag=$RunTag;testSelector=$selector;
      normalFreshBuild=$true;maximumForkHeap='3g';maximumMavenHeap='1800m';
      gate='Root must supply the final frozen 40-character SHA before -Execute';
      postgres='fresh non-reused Testcontainers; ephemeral mapped ports from actual logs';
      excludedLivePorts=@(28630,26630)}|ConvertTo-Json -Depth 4
    exit 0
}
if($FrozenRevision-notmatch'^[0-9a-f]{40}$' -or !$RunTag){throw 'Execution needs the explicit final frozen SHA and a new run tag.'}
$out=Join-Path $PSScriptRoot "runs/$RunTag"
if(Test-Path -LiteralPath $out){throw 'Preserve the original attempt, including exit 255; choose a new run tag.'}
if((git -C $workspace rev-parse HEAD)-ne$FrozenRevision){throw 'Candidate HEAD differs from the frozen SHA.'}
New-Item -ItemType Directory -Path "$out/logs","$out/tmp-maven","$out/artifacts","$out/physical/inputs","$out/physical/probes","$out/physical/tmp","$out/physical/artifacts"|Out-Null
& python -X utf8 "$PSScriptRoot/record-d3.py" begin --workspace $workspace --revision $FrozenRevision --out $out --selector $selector
if($LASTEXITCODE){throw 'Frozen source or runner inputs were not accepted; no tests started.'}
$env:TEMP="$out/tmp-maven";$env:TMP=$env:TEMP;$env:UTEN_RUN_DB_TESTS='true'
$env:MAVEN_OPTS="-Xmx1800m -Djava.io.tmpdir=$env:TEMP"
$mavenArgs=@('-o','-B','-ntp','-f',"$workspace/server/pom.xml","-Duten.build.directory=$out/build","-Duten.test.tmpdir=$env:TEMP","-Duten.export.evidence.directory=$out/artifacts",'-Duten.test.jvm.heap.args=-Xmx3g','-Duten.test.context.cache.maxSize=1','-DforkCount=1','-DreuseForks=true',"-Dtest=$selector",'test')
$mavenExit=255;$physicalExit=255
try {
    & java -version *> "$out/logs/environment.txt"
    & javac -version *>> "$out/logs/environment.txt"
    & mvn.cmd -version *>> "$out/logs/environment.txt"
    Push-Location "$workspace/server"
    try {& mvn.cmd @mavenArgs *> "$out/logs/maven.log";$mavenExit=$LASTEXITCODE}
    finally {Pop-Location}
    $mavenExit|Set-Content -LiteralPath "$out/logs/maven.exit" -Encoding utf8NoBOM
    if(Test-Path -LiteralPath "$out/build/surefire-reports"){
        Copy-Item -LiteralPath "$out/build/surefire-reports" -Destination "$out/reports" -Recurse
    }
    # A failing test does not hide the independent physical-writer result. A
    # compilation failure cannot supply a trusted completed set of main classes.
    $compiled=Test-Path -LiteralPath "$out/build/test-classes/com/uten/imp/businesschain/CompleteExportScalePostgresTest.class"
    if($compiled -and (git -C $workspace rev-parse HEAD)-eq$FrozenRevision){
        & mvn.cmd -o -B -ntp -f "$workspace/server/pom.xml" "-Duten.build.directory=$out/dependency-build" '-DincludeScope=test' "-Dmdep.outputFile=$out/deps-cp.txt" dependency:build-classpath *> "$out/logs/dependencies.log"
        $depsExit=$LASTEXITCODE;$depsExit|Set-Content -LiteralPath "$out/logs/dependencies.exit" -Encoding utf8NoBOM
        if($depsExit-eq0){
            & python -X utf8 "$PSScriptRoot/record-d3.py" physical-input --workspace $workspace --revision $FrozenRevision --out $out
            if($LASTEXITCODE){throw 'Physical helper does not match the frozen Git input.'}
            $deps=(Get-Content -LiteralPath "$out/deps-cp.txt" -Raw).Trim()
            foreach($jar in $deps.Split(';')){if(!$jar.EndsWith('.jar') -or !(Test-Path -LiteralPath $jar)){throw 'Classpath must contain existing dependency jars only.'}}
            $cp=(@("$out/physical/probes","$out/build/classes",$deps)-join ';') -replace '\\','/'
            @('-encoding','UTF-8','-g','-parameters','--release','21','-proc:none','-classpath',('"'+$cp+'"'),'-d',('"'+("$out/physical/probes" -replace '\\','/')+'"'),('"'+("$out/physical/inputs/PhysicalXlsxScale.java" -replace '\\','/')+'"'))|Set-Content -LiteralPath "$out/physical/javac.args" -Encoding utf8NoBOM
            & javac "@$out/physical/javac.args" *> "$out/physical/compile.log"
            $compileExit=$LASTEXITCODE;$compileExit|Set-Content -LiteralPath "$out/physical/compile.exit" -Encoding utf8NoBOM
            if($compileExit-eq0){
                @('-ea','-Xmx2304m','-Xshare:off','-Dfile.encoding=UTF-8',('"-Djava.io.tmpdir='+ ("$out/physical/tmp" -replace '\\','/')+'"'),'-classpath',('"'+$cp+'"'),'remediation.PhysicalXlsxScale',('"'+("$out/physical/artifacts" -replace '\\','/')+'"'))|Set-Content -LiteralPath "$out/physical/java.args" -Encoding utf8NoBOM
                $env:TMP="$out/physical/tmp";$env:TEMP=$env:TMP
                & java "@$out/physical/java.args" *> "$out/physical/physical.log"
                $physicalExit=$LASTEXITCODE
            } else {$physicalExit=$compileExit}
        } else {$physicalExit=$depsExit}
    }
} catch {
    @{type=$_.Exception.GetType().FullName;message=$_.Exception.Message;status='runner-error; original group exits retained'}|ConvertTo-Json|Set-Content -LiteralPath "$out/logs/runner-error.json" -Encoding utf8NoBOM
} finally {
    $mavenExit|Set-Content -LiteralPath "$out/logs/maven.exit" -Encoding utf8NoBOM
    $physicalExit|Set-Content -LiteralPath "$out/physical/physical.exit" -Encoding utf8NoBOM
    & python -X utf8 "$PSScriptRoot/record-d3.py" end --workspace $workspace --revision $FrozenRevision --out $out
}
& python -X utf8 "$PSScriptRoot/record-d3.py" seal --workspace $workspace --revision $FrozenRevision --out $out
exit $LASTEXITCODE
