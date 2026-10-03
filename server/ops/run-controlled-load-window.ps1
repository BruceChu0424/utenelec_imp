[CmdletBinding()]
param(
    [string]$ApplicationImage = 'uten-local-backend-linux-env:20260930-shard-runner',
    [string]$PostgresImage = 'postgres:16-alpine',
    [string]$ReadOnlyMavenCache = 'uten-linux-full-maven-cache-20260930-shard-runner',
    [ValidateSet('daily-report-1','daily-report-3','daily-report-11','fqc-20-plain','fqc-20-prestock','fqc-20-mixed','draw-1','draw-3','draw-10')]
    [string[]]$Scenarios = @('daily-report-1'),
    [ValidateSet('QUIET','MIXED')][string]$Background = 'QUIET',
    [ValidateRange(10,3600)][int]$DurationSeconds = 60,
    [ValidateRange(0,120)][int]$WarmupSeconds = 5,
    [ValidateRange(0.05,2.0)][double]$ArrivalRate = 0.2,
    [ValidateRange(1,8)][int]$MaxInFlight = 1,
    [ValidateRange(1,2000)][int]$MaxSamples = 12,
    [ValidateRange(1,2000)][int]$MinimumMeasuredSamples = 3,
    [ValidateRange(1,16)][int]$ReadyCapacity = 4,
    [ValidateRange(10,120)][int]$DrainSeconds = 60,
    [ValidateRange(256,4096)][int]$DatabaseLimitMiB = 1024,
    [switch]$AllowExtended,
    [switch]$ValidateOnly
)

# One JVM/context with bounded open-loop admission. Extended windows require an explicit switch.
# No host stress, business DB, Docker socket, production scheduler edit, or foreign cleanup.
$ErrorActionPreference = 'Stop'
$Background = $Background.ToUpperInvariant()
$Scenarios = @($Scenarios | ForEach-Object { $_.Trim().ToLowerInvariant() })
if ($Scenarios.Count -eq 0 -or @($Scenarios | Select-Object -Unique).Count -ne $Scenarios.Count) { throw 'Scenarios must be nonempty and unique' }
if ($MinimumMeasuredSamples -gt $MaxSamples -or $MinimumMeasuredSamples -gt [Math]::Ceiling($DurationSeconds*$ArrivalRate)) { throw 'The requested measured sample threshold is unreachable' }
if ($ReadyCapacity -lt $MaxInFlight) { throw 'ReadyCapacity must cover MaxInFlight' }
if (($DurationSeconds -gt 120 -or $MaxSamples -gt 30 -or $MaxInFlight -gt 2) -and -not $AllowExtended) { throw 'Extended sampling requires -AllowExtended' }
$maximumSeconds = 600 + 120 + $WarmupSeconds + $DurationSeconds + 2*$DrainSeconds + 20
if ($maximumSeconds -gt 4800) { throw 'The total external execution budget must stay within 80 minutes' }
$plan = [ordered]@{scenarios=$Scenarios;background=$Background;durationSeconds=$DurationSeconds;warmupSeconds=$WarmupSeconds;arrivalRate=$ArrivalRate;maxInFlight=$MaxInFlight;maxSamples=$MaxSamples;minimumMeasuredSamples=$MinimumMeasuredSamples;readyCapacity=$ReadyCapacity;drainSeconds=$DrainSeconds;databaseLimitMiB=$DatabaseLimitMiB;extendedExplicit=[bool]$AllowExtended}
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
if (-not (Test-Path -LiteralPath (Join-Path $repoRoot 'server/pom.xml'))) { throw 'Not an ERP workspace' }
$runId = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$prefix = 'uten-load-window-' + $runId
$labelKey = 'uten.controlled-load.run'
$network = $prefix + '-net'
$pgName = $prefix + '-pg'
$appName = $prefix + '-app'
$volumeNames = @(($prefix + '-pgdata'), ($prefix + '-cache'), ($prefix + '-work'))
$output = Join-Path $repoRoot ('.local-tmp/load-window/' + $runId)
New-Item -ItemType Directory -Path $output -ErrorAction Stop | Out-Null
$manifestPath = Join-Path $output 'run-manifest.json'
$manifest = [ordered]@{schema='uten-controlled-load-window-run-v1';runId=$runId;startedAt=[DateTime]::UtcNow.ToString('o');mode=$(if($ValidateOnly){'UNIT_VALIDATION'}else{'WINDOW'});plan=$plan;output=$output;outcome='PREPARING';maximumSeconds=$maximumSeconds;httpCovered=$false;formalSlaAccepted=$false;createdResources=@();cleanup=@()}
$createdContainers = [Collections.Generic.List[string]]::new()
$createdVolumes = [Collections.Generic.List[string]]::new()
$networkCreated = $false
$failure = $null

function Write-Manifest { $manifest | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $manifestPath -Encoding utf8 }
function Invoke-Docker([string[]]$Arguments) {
    $start = [Diagnostics.ProcessStartInfo]::new((Get-Command docker).Source)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        $null = $process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) {
            $process.Kill($true)
            $null = $process.WaitForExit(5000)
            throw 'Docker CLI exceeded its independent 30-second deadline'
        }
        $result = $stdout.GetAwaiter().GetResult()
        $errorText = $stderr.GetAwaiter().GetResult()
        $code = $process.ExitCode
    } finally { $process.Dispose() }
    if ($code -ne 0) {
        $verb = ($Arguments | Select-Object -First 2) -join ' '
        throw ('Docker operation failed (' + $verb + '): ' + $errorText + $result)
    }
    if ($Arguments[0] -eq 'logs') { return ($result + $errorText).Trim() }
    return $result.Trim()
}
function Assert-Owned([string]$Kind, [string]$Name) {
    $raw = switch ($Kind) {
        'container' { Invoke-Docker @('inspect', $Name) }
        'volume' { Invoke-Docker @('volume', 'inspect', $Name) }
        'network' { Invoke-Docker @('network', 'inspect', $Name) }
    }
    $item = @($raw | ConvertFrom-Json)[0]
    $labels = if ($Kind -eq 'container') { $item.Config.Labels } else { $item.Labels }
    $actualName = if ($Kind -eq 'container') { $item.Name.TrimStart('/') } else { $item.Name }
    if ($actualName -ne $Name -or $labels.$labelKey -ne $runId -or -not $Name.StartsWith($prefix, [StringComparison]::Ordinal)) {
        throw ('Refusing to touch a resource not owned by this run: ' + $Name)
    }
    return $item
}
function Inspect-Limits([string]$Name, [double]$Cpu, [long]$Memory) {
    $item = Assert-Owned 'container' $Name
    $quota = Invoke-Docker @('exec', $Name, 'cat', '/sys/fs/cgroup/cpu.max')
    $memoryMax = Invoke-Docker @('exec', $Name, 'cat', '/sys/fs/cgroup/memory.max')
    $parts = $quota -split '\s+'
    if ($parts[0] -eq 'max' -or $parts.Count -ne 2 -or ([double]$parts[0] / [double]$parts[1]) -ne $Cpu) { throw ('CPU cgroup limit mismatch: ' + $Name) }
    if ([long]$memoryMax -ne $Memory -or [long]$item.HostConfig.Memory -ne $Memory -or [long]$item.HostConfig.NanoCpus -ne [long]($Cpu * 1000000000)) { throw ('Docker/cgroup limit mismatch: ' + $Name) }
    return [ordered]@{name=$Name;image=$item.Image;cpuMax=$quota;memoryMax=[long]$memoryMax;nanoCpus=$item.HostConfig.NanoCpus;memorySwap=$item.HostConfig.MemorySwap;pidsLimit=$item.HostConfig.PidsLimit;networkMode=$item.HostConfig.NetworkMode}
}

try {
    $system = Get-CimInstance Win32_ComputerSystem
    $os = Get-CimInstance Win32_OperatingSystem
    $freeBytes = [long]$os.FreePhysicalMemory * 1KB
    $cpuCeiling = [Math]::Min(2.0, [double]$system.NumberOfLogicalProcessors * 0.25)
    if ($cpuCeiling -lt 2.0) { throw 'This fixed 2-CPU profile exceeds 25% of host logical CPUs' }
    if ($freeBytes -lt 9GB) { throw 'Need 5 GiB container limits plus at least 4 GiB free host reserve' }
    $dockerInfo = Invoke-Docker @('info', '--format', '{{json .}}') | ConvertFrom-Json
    if ($dockerInfo.OSType -ne 'linux' -or $dockerInfo.CgroupVersion -ne '2') { throw 'Verified Linux cgroup v2 is required' }
    $manifest.host = [ordered]@{logicalCpus=$system.NumberOfLogicalProcessors;freeMemoryBytes=$freeBytes;totalMemoryBytes=$system.TotalPhysicalMemory;hardCpuBudget=2.0;hostCpuShare=2.0/$system.NumberOfLogicalProcessors;dockerCpus=$dockerInfo.NCPU;dockerMemoryBytes=$dockerInfo.MemTotal;cgroupVersion=$dockerInfo.CgroupVersion}
    $appImageId = Invoke-Docker @('image', 'inspect', $ApplicationImage, '--format', '{{.Id}}')
    $pgImageId = Invoke-Docker @('image', 'inspect', $PostgresImage, '--format', '{{.Id}}')
    $null = Invoke-Docker @('volume', 'inspect', $ReadOnlyMavenCache)
    $commit = (& git -C $repoRoot rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Cannot record the source commit' }
    $manifest.sourceCommit = $commit
    $manifest.runnerScriptSha256 = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLower()
    $manifest.images = @{application=$appImageId;postgres=$pgImageId;applicationTag=$ApplicationImage;postgresTag=$PostgresImage}
    $manifest.dependencies = @{cache=$ReadOnlyMavenCache;access='read-only input; repository copied to new volume';offline=$true;settingsCopied=$false}
    $manifest.java = @{mavenHeap='768m';testHeap='1536m';applicationContainerBytes=4GB;postgresContainerBytes=1GB;note='Container limit includes all processes, native memory and charged cache; actual peak is captured'}
    $sourceHashes = @()
    if (Get-ChildItem -LiteralPath (Join-Path $repoRoot 'server/src') -Recurse -Attributes ReparsePoint) {
        throw 'Source directory links must not enter the isolated copy'
    }
    foreach ($file in (Get-ChildItem -LiteralPath (Join-Path $repoRoot 'server/src') -Recurse -File)) {
        if ($file.Name -match '^\.env($|\.)' -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'A source dotenv file or link must not enter the isolated copy'
        }
        $sourceHashes += [ordered]@{path=$file.FullName.Substring($repoRoot.Length+1).Replace('\','/');sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLower()}
    }
    $sourceHashes | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $output 'source-files.json') -Encoding utf8
    $manifest.sourceFilesSha256 = (Get-FileHash -LiteralPath (Join-Path $output 'source-files.json') -Algorithm SHA256).Hash.ToLower()
    $manifest.pomSha256 = (Get-FileHash -LiteralPath (Join-Path $repoRoot 'server/pom.xml') -Algorithm SHA256).Hash.ToLower()
    $manifest.fontFiles = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'assets/fonts') -File | ForEach-Object {
        @{name=$_.Name;sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLower()}
    })
    Write-Manifest

    $null = Invoke-Docker @('network', 'create', '--internal', '--label', "$labelKey=$runId", $network)
    $networkCreated = $true
    foreach ($name in $volumeNames) {
        if ($ValidateOnly -and $name -eq $volumeNames[0]) { continue }
        $null = Invoke-Docker @('volume', 'create', '--label', "$labelKey=$runId", $name); $createdVolumes.Add($name)
    }
    $password = [guid]::NewGuid().ToString('N') # Ephemeral container-only credential; excluded from manifests.
    if (-not $ValidateOnly) {
      $null = Invoke-Docker @('run', '-d', '--pull', 'never', '--name', $pgName, '--label', "$labelKey=$runId", '--network', $network,
        '--cpus', '0.75', '--memory', '1g', '--memory-swap', '1g', '--pids-limit', '256', '--shm-size', '128m',
        '--mount', "type=volume,source=$($volumeNames[0]),target=/var/lib/postgresql/data",
        '-e', 'POSTGRES_DB=uten_load', '-e', 'POSTGRES_USER=uten_load', '-e', "POSTGRES_PASSWORD=$password",
        $pgImageId, 'postgres', '-c', 'max_connections=40', '-c', 'shared_buffers=128MB')
      $createdContainers.Add($pgName)
      $manifest.postgresLimits = Inspect-Limits $pgName 0.75 1GB
    }
    $testSelection = if ($ValidateOnly) { 'ControlledLoadRunPlanTest,ControlledLoadWindowMetricsTest' } else { 'ControlledLoadWindowTest' }
    $manifest.testSelection = $testSelection

    $workload = @'
set -eu
mkdir -p /work/server /work/assets /cache/repository
cp -a /cache-input/repository/. /cache/repository/
cp -a /source/server/src /work/server/
cp /source/server/pom.xml /work/server/
cp -a /source/assets/fonts /work/assets/
cd /work/server
exec mvn --offline --batch-mode -Dmaven.repo.local=/cache/repository -Duten.build.directory=/work/target-load-window -Duten.test.jvm.heap.args=-Xmx1536m "-Dtest=$UTEN_LOAD_TEST_SELECTION" test > /results/maven.log 2>&1
'@
    [IO.File]::WriteAllText((Join-Path $output 'workload.sh'), $workload.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
    $inside = @'
set -eu
while [ ! -f /results/start.allowed ]; do sleep 1; done
status=0
timeout --signal=TERM --kill-after=10s "$UTEN_LOAD_MAX_SECONDS" /bin/bash /results/workload.sh || status=$?
for name in cpu.max cpu.stat memory.max memory.current memory.peak memory.events io.stat; do
  if [ -f /sys/fs/cgroup/$name ]; then cat /sys/fs/cgroup/$name > /results/application-final-$name.txt; fi
done
if [ -d /work/target-load-window/surefire-reports ]; then cp -a /work/target-load-window/surefire-reports /results/; fi
printf '%s\n' "$status" > /results/maven-exit-code.txt
exit "$status"
'@
    $null = Invoke-Docker @('run', '-d', '--pull', 'never', '--user', '0', '--name', $appName, '--label', "$labelKey=$runId", '--network', $network,
        '--cpus', '1.25', '--memory', '4g', '--memory-swap', '4g', '--pids-limit', '512',
        '--mount', "type=bind,source=$(Join-Path $repoRoot 'server/src'),target=/source/server/src,readonly",
        '--mount', "type=bind,source=$(Join-Path $repoRoot 'server/pom.xml'),target=/source/server/pom.xml,readonly",
        '--mount', "type=bind,source=$(Join-Path $repoRoot 'assets/fonts'),target=/source/assets/fonts,readonly",
        '--mount', "type=bind,source=$output,target=/results",
        '--mount', "type=volume,source=$ReadOnlyMavenCache,target=/cache-input,readonly",
        '--mount', "type=volume,source=$($volumeNames[1]),target=/cache",
        '--mount', "type=volume,source=$($volumeNames[2]),target=/work",
        '-e', 'MAVEN_OPTS=-Xmx768m', '-e', "UTEN_LOAD_TEST_SELECTION=$testSelection", '-e', "UTEN_LOAD_MAX_SECONDS=$maximumSeconds", '-e', "UTEN_CONTROLLED_LOAD_WINDOW=$((-not $ValidateOnly).ToString().ToLowerInvariant())", '-e', "UTEN_LOAD_DB_URL=jdbc:postgresql://${pgName}:5432/uten_load",
        '-e', "UTEN_WINDOW_SCENARIOS=$($Scenarios -join ',')", '-e', "UTEN_WINDOW_BACKGROUND=$Background",
        '-e', "UTEN_WINDOW_DURATION_SECONDS=$DurationSeconds", '-e', "UTEN_WINDOW_WARMUP_SECONDS=$WarmupSeconds",
        '-e', "UTEN_WINDOW_RATE=$($ArrivalRate.ToString([Globalization.CultureInfo]::InvariantCulture))", '-e', "UTEN_WINDOW_MAX_IN_FLIGHT=$MaxInFlight",
        '-e', "UTEN_WINDOW_MAX_SAMPLES=$MaxSamples", '-e', "UTEN_WINDOW_MIN_SAMPLES=$MinimumMeasuredSamples",
        '-e', "UTEN_WINDOW_READY_CAPACITY=$ReadyCapacity", '-e', "UTEN_WINDOW_DRAIN_SECONDS=$DrainSeconds",
        '-e', "UTEN_WINDOW_DATABASE_LIMIT_MIB=$DatabaseLimitMiB", '-e', "UTEN_WINDOW_ALLOW_EXTENDED=$(([bool]$AllowExtended).ToString().ToLowerInvariant())",
        '-e', 'UTEN_LOAD_DB_USER=uten_load', '-e', "UTEN_LOAD_DB_PASSWORD=$password", '-e', 'UTEN_LOAD_OUTPUT=/results',
        '--entrypoint', '/bin/bash', $appImageId, '-c', $inside)
    $createdContainers.Add($appName)
    $manifest.applicationLimits = Inspect-Limits $appName 1.25 4GB
    $manifest.createdResources = @($createdContainers.ToArray()) + @($createdVolumes.ToArray()) + @($network)
    $pgReady = [bool]$ValidateOnly
    $readyDeadline = [DateTime]::UtcNow.AddSeconds(60)
    while (-not $pgReady -and [DateTime]::UtcNow -lt $readyDeadline) {
        try { $null = Invoke-Docker @('exec', $pgName, 'pg_isready', '-U', 'uten_load', '-d', 'uten_load'); $pgReady = $true; break }
        catch { if ($_.Exception.Message -notmatch 'no response|rejecting connections') { throw } }
        Start-Sleep -Seconds 1
    }
    if (-not $pgReady) { throw 'Private PostgreSQL did not become ready within 60 seconds' }
    $manifest.outcome = 'RUNNING'
    $manifest.limitsVerifiedAt = [DateTime]::UtcNow.ToString('o')
    Write-Manifest
    New-Item -ItemType File -Path (Join-Path $output 'start.allowed') | Out-Null
    $deadline = [DateTime]::UtcNow.AddSeconds($maximumSeconds)
    while ($true) {
        $state = Invoke-Docker @('inspect', $appName, '--format', '{{json .State}}') | ConvertFrom-Json
        if (-not $state.Running) { break }
        if ([DateTime]::UtcNow -ge $deadline) {
            $null = Assert-Owned 'container' $appName
            $null = Invoke-Docker @('stop', '--time', '5', $appName)
            throw 'The bounded single-context window exceeded its external deadline'
        }
        $statsArguments = @('stats', '--no-stream', '--format', '{{json .}}', $appName)
        if (-not $ValidateOnly) { $statsArguments += $pgName }
        $stats = Invoke-Docker $statsArguments
        foreach ($line in ($stats -split "`n")) {
            [ordered]@{at=[DateTime]::UtcNow.ToString('o');sample=($line|ConvertFrom-Json)} | ConvertTo-Json -Compress -Depth 5 |
                Add-Content -LiteralPath (Join-Path $output 'docker-stats.jsonl') -Encoding utf8
        }
        Start-Sleep -Seconds 2
    }
    $manifest.applicationExit = $state
    $manifest.outcome = if ($state.ExitCode -eq 0) { 'PASSED' } else { 'FAILED' }
    if ($state.ExitCode -ne 0) { throw ('Controlled application exited with code ' + $state.ExitCode + '; see maven.log') }
    if ($ValidateOnly) {
        $tests = 0
        foreach ($file in (Get-ChildItem -LiteralPath (Join-Path $output 'surefire-reports') -Filter 'TEST-*.xml')) {
            [xml]$report = Get-Content -LiteralPath $file.FullName
            if ([int]$report.testsuite.failures -ne 0 -or [int]$report.testsuite.errors -ne 0) { throw 'Pure validation failed' }
            $tests += [int]$report.testsuite.tests
        }
        if ($tests -ne 7) { throw 'The seven expected pure checks did not all run' }
        $manifest.unitTests = $tests
        $manifest.windowExecuted = $false
    } else {
        $summaryPath = Join-Path $output 'window-summary.json'
        if (-not (Test-Path -LiteralPath $summaryPath)) { throw 'No window summary was produced' }
        $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
        if ($summary.outcome -ne 'DIAGNOSTIC_COMPLETED' -or -not $summary.sampleThresholdMet -or $summary.unknownOutcomes -ne 0) { throw 'The requested diagnostic window did not meet its declared evidence threshold' }
        $manifest.summarySha256 = (Get-FileHash -LiteralPath $summaryPath -Algorithm SHA256).Hash.ToLower()
    }
} catch {
    $failure = $_
    $manifest.outcome = 'FAILED'
    $manifest.failure = $_.Exception.Message
} finally {
    # An operation may create a resource before its CLI returns failure. Inspect
    # every exact planned name; missing resources are harmless, foreign ones never touched.
    foreach ($name in @($appName, $pgName)) {
        try {
            $item = Assert-Owned 'container' $name
        } catch {
            if ($_.Exception.Message -match 'No such object|No such container') { $manifest.cleanup += "$name absent" }
            else { $manifest.cleanup += ('FAILED ' + $name + ': ' + $_.Exception.Message) }
            continue
        }
        if ($name -eq $appName) { $manifest.applicationExit = $item.State }
        try {
            $log = Invoke-Docker @('logs', $name)
            $log | Set-Content -LiteralPath (Join-Path $output ($name + '.log')) -Encoding utf8
            if ($item.State.Running) {
                foreach ($stat in @('cpu.max','cpu.stat','memory.max','memory.current','memory.peak','memory.events','io.stat')) {
                    Invoke-Docker @('exec', $name, 'cat', ("/sys/fs/cgroup/" + $stat)) | Set-Content -LiteralPath (Join-Path $output ($name + '-' + $stat + '.txt')) -Encoding utf8
                }
            }
        } catch {
            $manifest.cleanup += ('Evidence capture incomplete for ' + $name + ': ' + $_.Exception.Message)
        }
        # Diagnostics must never prevent cleanup of a positively owned container.
        try { $null = Invoke-Docker @('rm', '-f', $name); $manifest.cleanup += "$name removed after ownership validation" }
        catch { $manifest.cleanup += ('FAILED ' + $name + ': ' + $_.Exception.Message) }
    }
    foreach ($name in $volumeNames) {
        try { $null = Assert-Owned 'volume' $name; $null = Invoke-Docker @('volume', 'rm', $name); $manifest.cleanup += "$name removed after ownership validation" }
        catch {
            if ($_.Exception.Message -match 'no such volume') { $manifest.cleanup += "$name absent" }
            else { $manifest.cleanup += ('FAILED ' + $name + ': ' + $_.Exception.Message) }
        }
    }
    if ($network) {
        try { $null = Assert-Owned 'network' $network; $null = Invoke-Docker @('network', 'rm', $network); $manifest.cleanup += "$network removed after ownership validation" }
        catch {
            if ($_.Exception.Message -match 'network .* not found|No such network') { $manifest.cleanup += "$network absent" }
            else { $manifest.cleanup += ('FAILED ' + $network + ': ' + $_.Exception.Message) }
        }
    }
    $manifest.finishedAt = [DateTime]::UtcNow.ToString('o')
    # Persist uncertainty when a hard deadline/OOM prevents the JVM summary. A
    # missing response is not proof of rollback; never replay these keys here.
    if (-not (Test-Path -LiteralPath (Join-Path $output 'window-summary.json')) -and (Test-Path -LiteralPath (Join-Path $output 'events.jsonl'))) {
        $admissions = @{}; $verifiedCommands = @{}
        foreach ($line in [IO.File]::ReadLines((Join-Path $output 'events.jsonl'))) {
            try {
                $event = $line | ConvertFrom-Json
                if ($event.type -eq 'COMMAND_ADMITTED') { $admissions[$event.data.commandId] = $event.data.input }
                if ($event.type -eq 'COMMAND_VERIFIED') { $verifiedCommands[$event.data.commandId] = $true }
            } catch { $manifest.journalTailMayBeIncomplete = $true }
        }
        $manifest.unverifiedAtProcessExit = @($admissions.Keys | Where-Object { -not $verifiedCommands.ContainsKey($_) } | ForEach-Object {
            @{commandId=$_;resolution='OUTCOME_UNKNOWN_OR_UNVERIFIED';originalInput=$admissions[$_]}
        })
    }
    if (@($manifest.cleanup | Where-Object { $_ -like 'FAILED *' }).Count -gt 0) {
        $manifest.outcome = 'FAILED_CLEANUP'
        if (-not $failure) { $failure = [Exception]::new('Owned test resources need cleanup; see run-manifest.json') }
    }
    Write-Manifest
}
Write-Output ('Controlled load evidence: ' + $output)
if ($failure) { throw $failure }
