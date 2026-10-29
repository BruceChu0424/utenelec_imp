[CmdletBinding()]
param(
    [switch]$Verify,
    [ValidateSet('x86', 'x64', 'all')][string]$Architecture = 'all',
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]{0,40}$')][string]$BuildScope = ('verify-' + [Guid]::NewGuid().ToString('N').Substring(0, 12)),
    [Parameter(Mandatory = $true)][string]$MsBuildPath,
    [Parameter(Mandatory = $true)][string]$PythonPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$clientRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$workspaceRoot = [IO.Path]::GetFullPath((Join-Path $clientRoot '../..'))
$privateRoot = Join-Path $workspaceRoot 'build/windows-wpf'
$architectures = if ($Architecture -eq 'all') { @('x86', 'x64') } else { @($Architecture) }
$testProject = Join-Path $clientRoot 'Uten.Legacy.Tests/Uten.Legacy.Tests.csproj'

if (-not $Verify) {
    [PSCustomObject]@{
        Mode = 'dry-run'
        Architecture = $architectures
        BuildScope = $BuildScope
        Project = $testProject
        Scope = 'Debug native contracts and bootstrap PE checks on this host; no installer, release ZIP, SDK change or publication.'
        TargetPcAcceptance = $false
    } | ConvertTo-Json -Depth 4
    return
}

function Assert-PrivatePath([string]$candidate) {
    $absolute = [IO.Path]::GetFullPath($candidate)
    $boundary = [IO.Path]::GetFullPath($privateRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if ($absolute -ne $boundary -and -not $absolute.StartsWith($boundary + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Verification output leaves the private WPF build directory.'
    }
    for ($ancestor = $absolute; $ancestor; $ancestor = [IO.Path]::GetDirectoryName($ancestor)) {
        $item = Get-Item -LiteralPath $ancestor -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Verification output cannot contain a symbolic link or junction.'
        }
    }
}

function Source-Proof {
    $progressBoundary = (Join-Path $clientRoot 'progress') + [IO.Path]::DirectorySeparatorChar
    $inputs = @(Get-ChildItem -LiteralPath $clientRoot -Recurse -File)
    $inputs += @(Get-ChildItem -LiteralPath (Join-Path $workspaceRoot 'lib/core/theme') -Recurse -File -Filter '*.dart')
    # The generator owns the input list, including the optional public window
    # controls. Do not maintain a separate caption/login/source list here.
    $designSourceJson = @(& $PythonPath -B (Join-Path $PSScriptRoot 'sync_design_tokens.py') --list-sources --root $workspaceRoot)
    if ($LASTEXITCODE -ne 0) { throw 'Cannot enumerate the authoritative design-token source inputs.' }
    foreach ($relative in (($designSourceJson -join '') | ConvertFrom-Json)) {
        $inputs += Get-Item -LiteralPath (Join-Path $workspaceRoot $relative) -ErrorAction Stop
    }
    foreach ($relative in @('pubspec.yaml', 'assets/security/uten-imp-root-ca.crt', 'assets/fonts/NotoSansSC.ttf', 'assets/fonts/NotoSansSCFull.ttf', 'assets/fonts/OFL.txt',
        'assets/images/logo_ip.png', 'assets/images/logo_name.png', 'windows/runner/resources/app_icon.ico')) {
        $inputs += Get-Item -LiteralPath (Join-Path $workspaceRoot $relative) -ErrorAction Stop
    }
    $records = foreach ($file in ($inputs | Sort-Object FullName -Unique)) {
        if ($file.FullName.StartsWith($progressBoundary, [StringComparison]::OrdinalIgnoreCase) -or $file.Name -eq 'README.zh-CN.md') { continue }
        if ($file.Extension -notin @('.cs', '.csproj', '.xaml', '.props', '.targets', '.config', '.manifest', '.json',
            '.py', '.ps1', '.iss', '.dart', '.yaml', '.crt', '.ttf', '.png', '.ico', '.txt') -and $file.Name -ne '.gitignore') { continue }
        [PSCustomObject]@{
            Path = $file.FullName.Substring($workspaceRoot.Length + 1).Replace([IO.Path]::DirectorySeparatorChar, [char]'/')
            Sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    $records | ConvertTo-Json -Depth 3 -Compress
}

foreach ($tool in @($MsBuildPath, $PythonPath)) {
    if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) { throw 'Supply an existing compiler and Python executable; this command installs nothing.' }
}
if ([IO.Path]::GetFileName($MsBuildPath) -ine 'MSBuild.exe') { throw 'MsBuildPath must identify MSBuild.exe.' }

$jobRoot = Join-Path $privateRoot ('verification/' + [Guid]::NewGuid().ToString('D'))
Assert-PrivatePath $jobRoot
[IO.Directory]::CreateDirectory($jobRoot) | Out-Null
$sourceBefore = Source-Proof
$report = [ordered]@{
    SchemaVersion = 1
    StartedAtUtc = [DateTime]::UtcNow.ToString('o')
    BuildScope = $BuildScope
    HostOs = [Environment]::OSVersion.VersionString
    Architectures = $architectures
    Succeeded = $false
    TargetPcAcceptance = $false
    FormalPackageCreated = $false
    ProductionRequestsExecuted = $false
    SourceFiles = ($sourceBefore | ConvertFrom-Json)
    Checks = @()
}

Push-Location $workspaceRoot
try {
    $progressLog = Join-Path $jobRoot 'progress-check.log'
    & $PythonPath -B (Join-Path $PSScriptRoot 'progress_tracker.py') check *> $progressLog
    if ($LASTEXITCODE -ne 0) { throw "Progress/source check failed; inspect $progressLog" }
    $report.Checks += [PSCustomObject]@{ Stage = 'progress'; ExitCode = 0; Log = $progressLog }

    $bootstrapLog = Join-Path $jobRoot 'bootstrap-build.log'
    & (Join-Path $PSScriptRoot 'build_windows_wpf.ps1') -Build -Architecture $Architecture -Configuration Debug -DistributionProfile Unreviewed -BuildScope $BuildScope -MsBuildPath $MsBuildPath -PythonPath $PythonPath *> $bootstrapLog
    $report.Checks += [PSCustomObject]@{ Stage = 'bootstrap-build-and-pe'; ExitCode = 0; Log = $bootstrapLog }

    foreach ($arch in $architectures) {
        $output = Join-Path $jobRoot ($arch + '/')
        Assert-PrivatePath $output
        $buildLog = Join-Path $jobRoot ($arch + '-build.log')
        $testLog = Join-Path $jobRoot ($arch + '-tests.log')
        & $MsBuildPath $testProject /nologo /verbosity:minimal /warnaserror /t:Rebuild /p:Configuration=Debug "/p:Platform=$arch" "/p:PlatformTarget=$arch" "/p:UtenBuildScope=$BuildScope" "/p:OutputPath=$output" /p:Restore=false /p:RestoreDuringBuild=false *> $buildLog
        if ($LASTEXITCODE -ne 0) { throw "Native $arch build failed; inspect $buildLog" }
        if (Select-String -LiteralPath $buildLog -Pattern '\b(?:warning|error)\s+[A-Z]+\d+\s*:' -Quiet) { throw "Native $arch build emitted diagnostics; inspect $buildLog" }
        $runner = Join-Path $output 'Uten.Legacy.Tests.exe'
        & $runner *> $testLog
        if ($LASTEXITCODE -ne 0) { throw "Native $arch checks failed; inspect $testLog" }
        if (-not (Select-String -LiteralPath $testLog -SimpleMatch "process=$arch" -Quiet)) { throw 'Native runner did not confirm its process architecture.' }
        $report.Checks += [PSCustomObject]@{ Stage = 'native-contracts'; Architecture = $arch; ExitCode = 0; BuildLog = $buildLog; TestLog = $testLog }
        Write-Output "PASS native contracts: $arch"
    }
    $sourceAfter = Source-Proof
    if ($sourceBefore -cne $sourceAfter) { throw 'Native source changed during verification. This run cannot certify the changed source; keep logs and rerun when frozen.' }
    $report.Succeeded = $true
}
catch {
    # Only fixture/source diagnostics are retained; no credentials or live business payloads.
    $report.Failure = $_.Exception.Message
    throw
}
finally {
    $report.CompletedAtUtc = [DateTime]::UtcNow.ToString('o')
    $logRecords = foreach ($log in (Get-ChildItem -LiteralPath $jobRoot -File -Filter '*.log')) {
        [PSCustomObject]@{ Path = $log.FullName; Sha256 = (Get-FileHash -LiteralPath $log.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
    $report.LogFiles = @($logRecords)
    $reportPath = Join-Path $jobRoot 'verification.json'
    [IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
    Write-Output "Verification report: $reportPath"
    Pop-Location
}
