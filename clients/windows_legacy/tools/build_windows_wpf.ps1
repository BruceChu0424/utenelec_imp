[CmdletBinding()]
param(
    [switch]$Build,
    [ValidateSet('x86', 'x64', 'all')][string]$Architecture = 'all',
    [ValidateSet('Debug', 'Release')][string]$Configuration = 'Release',
    [ValidateSet('Unreviewed', 'Company')][string]$DistributionProfile = 'Unreviewed',
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]{0,40}$')][string]$BuildScope = 'default',
    [string]$MsBuildPath,
    [string]$PythonPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# This opt-in build has no installer, update ZIP, restore or publication step.
# It never invokes Flutter or modifies the shared Flutter/.NET SDK installation.
$clientRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$workspaceRoot = [IO.Path]::GetFullPath((Join-Path $clientRoot '../..'))
$desktopProject = Join-Path $clientRoot 'Uten.Legacy.Desktop/Uten.Legacy.Desktop.csproj'
$updaterProject = Join-Path $clientRoot 'Uten.Legacy.Updater/Uten.Legacy.Updater.csproj'
$policyTool = Join-Path $clientRoot 'installer/wpf_install_policy.py'
$dependencyTool = Join-Path $clientRoot 'tools/restore_dependencies.py'
$designTool = Join-Path $clientRoot 'tools/sync_design_tokens.py'
$packageTool = Join-Path $clientRoot 'tools/package_wpf.py'
$buildRoot = Join-Path $workspaceRoot 'build/windows-wpf'
$buildArchitectures = if ($Architecture -eq 'all') { @('x86', 'x64') } else { @($Architecture) }

function Assert-PrivateBuildPath([string]$CandidatePath) {
    $resolvedCandidate = [IO.Path]::GetFullPath($CandidatePath)
    $resolvedBuildRoot = [IO.Path]::GetFullPath($buildRoot).TrimEnd('\')
    if ($resolvedCandidate -ne $resolvedBuildRoot -and
        -not $resolvedCandidate.StartsWith($resolvedBuildRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'WPF build path leaves the explicitly named private output root.'
    }
    $ancestorPath = $resolvedCandidate
    while ($ancestorPath) {
        $ancestor = Get-Item -LiteralPath $ancestorPath -Force -ErrorAction SilentlyContinue
        if ($ancestor -and ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Private build/receipt paths cannot contain symbolic links or junctions.'
        }
        $nextAncestor = [IO.Path]::GetDirectoryName($ancestorPath)
        if ($nextAncestor -eq $ancestorPath) { break }
        $ancestorPath = $nextAncestor
    }
}

function Find-MsBuild {
    if ($MsBuildPath) {
        $explicit = Get-Item -LiteralPath $MsBuildPath -ErrorAction Stop
        if ($explicit.PSIsContainer -or $explicit.Name -ine 'MSBuild.exe') {
            throw 'MsBuildPath must identify an installed MSBuild.exe.'
        }
        return $explicit.FullName
    }
    $command = Get-Command MSBuild.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $programFilesX86 = [Environment]::GetFolderPath('ProgramFilesX86')
    $locator = Join-Path $programFilesX86 'Microsoft Visual Studio/Installer/vswhere.exe'
    if (Test-Path -LiteralPath $locator -PathType Leaf) {
        $located = @(& $locator -latest -products '*' -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe')
        if ($LASTEXITCODE -ne 0) { throw 'Installed Visual Studio discovery failed.' }
        foreach ($candidate in $located) {
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        }
    }
    throw 'MSBuild was not found. Supply -MsBuildPath for an existing installation; this script installs nothing.'
}

$plans = foreach ($targetArchitecture in $buildArchitectures) {
    $outputDirectory = [IO.Path]::GetFullPath((Join-Path $buildRoot $targetArchitecture))
    Assert-PrivateBuildPath $outputDirectory
    $buildPrefix = [IO.Path]::GetFullPath($buildRoot).TrimEnd('\') + '\'
    if (-not $outputDirectory.StartsWith($buildPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Build output leaves the independent WPF output directory.'
    }
    [PSCustomObject]@{
        Architecture = $targetArchitecture
        Project = $desktopProject
        OutputDirectory = $outputDirectory
        Arguments = @(
            $desktopProject,
            '/nologo',
            '/verbosity:minimal',
            '/t:Build',
            "/p:Configuration=$Configuration",
            "/p:Platform=$targetArchitecture",
            "/p:PlatformTarget=$targetArchitecture",
            "/p:UtenDistributionProfile=$DistributionProfile",
            "/p:UtenBuildScope=$BuildScope",
            "/p:OutputPath=$outputDirectory\",
            '/p:BuildProjectReferences=true',
            '/p:RestorePackages=false',
            '/p:RestoreDuringBuild=false',
            '/p:Restore=false'
        )
    }
}

if (-not $Build) {
    [PSCustomObject]@{
        Mode = 'dry-run'
        Configuration = $Configuration
        DistributionProfile = $DistributionProfile
        BuildScope = $BuildScope
        Builds = @($plans)
        Status = 'No compiler invoked; no output directories, installer or ZIP created. Win7 target-PC validation pending.'
    } | ConvertTo-Json -Depth 5
    return
}

if (-not (Test-Path -LiteralPath $desktopProject -PathType Leaf)) {
    throw "Desktop project is missing: $desktopProject"
}
if (-not (Test-Path -LiteralPath $updaterProject -PathType Leaf)) {
    throw "Native updater project is missing: $updaterProject"
}
if ($DistributionProfile -eq 'Company' -and $Configuration -ne 'Release') {
    throw 'Company candidate receipts require a Release build; Debug cannot be a formal package input.'
}
$compiler = Find-MsBuild
if (-not $PythonPath) {
    $pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
    if (-not $pythonCommand) {
        throw 'An existing Python 3 interpreter is required for read-only PE checks; supply -PythonPath. Nothing will be installed.'
    }
    $PythonPath = $pythonCommand.Source
}
if (-not (Test-Path -LiteralPath $PythonPath -PathType Leaf)) {
    throw 'PythonPath must identify an existing Python interpreter.'
}

& $PythonPath $dependencyTool --check
if ($LASTEXITCODE -ne 0) {
    throw 'Private managed TLS dependency validation failed. Use restore_dependencies.py --restore explicitly; this build never changes the global SDK or package cache.'
}
& $PythonPath $designTool --check
if ($LASTEXITCODE -ne 0) {
    throw 'Shared Uten design tokens drifted. Regenerate the WPF mapping from the owning Flutter token source; do not patch local corner values.'
}

$sourceStateFile = $null
if ($DistributionProfile -eq 'Company') {
    $sourceState = @(& $PythonPath $packageTool source-state --source-root $workspaceRoot)
    if ($LASTEXITCODE -ne 0) { throw 'Company candidate requires clean, reviewed and committed source inputs.' }
    $receiptDirectory = Join-Path $buildRoot 'receipts'
    Assert-PrivateBuildPath $receiptDirectory
    [IO.Directory]::CreateDirectory($receiptDirectory) | Out-Null
    $sourceStateFile = Join-Path $receiptDirectory 'source-state.json'
    [IO.File]::WriteAllText($sourceStateFile, ($sourceState -join [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
}

foreach ($plan in $plans) {
    & $compiler @($plan.Arguments)
    if ($LASTEXITCODE -ne 0) { throw "WPF $($plan.Architecture) compilation failed (exit $LASTEXITCODE)." }
    $updaterOutput = Join-Path $plan.OutputDirectory 'client_updater'
    $updaterArguments = @($updaterProject, '/nologo', '/verbosity:minimal', '/t:Build',
        "/p:Configuration=$Configuration", "/p:Platform=$($plan.Architecture)", "/p:PlatformTarget=$($plan.Architecture)",
        "/p:UtenDistributionProfile=$DistributionProfile", "/p:OutputPath=$updaterOutput\", '/p:Restore=false')
    $updaterArguments += "/p:UtenBuildScope=$BuildScope"
    & $compiler @updaterArguments
    if ($LASTEXITCODE -ne 0) { throw 'Native updater compilation failed; no package output will be prepared.' }
    & $PythonPath $policyTool --verify-executable (Join-Path $updaterOutput 'Uten.Legacy.Updater.exe') --architecture $plan.Architecture
    if ($LASTEXITCODE -ne 0) { throw 'Native updater bitness differs from its application.' }
    $executable = Join-Path $plan.OutputDirectory 'Uten.Legacy.Desktop.exe'
    & $PythonPath $policyTool --verify-executable $executable --architecture $plan.Architecture
    if ($LASTEXITCODE -ne 0) { throw "WPF $($plan.Architecture) output failed its PE architecture check." }
    if ($DistributionProfile -eq 'Company') {
        # The update candidate is an explicit six-file snapshot, never the
        # mixed development output directory (PDBs, test assemblies or helpers).
        $payloadDirectory = Join-Path $buildRoot ("company-payloads/" + $plan.Architecture + '-' + [Guid]::NewGuid().ToString('D'))
        Assert-PrivateBuildPath $payloadDirectory
        [IO.Directory]::CreateDirectory($payloadDirectory) | Out-Null
        $approvedFiles = @('Uten.Legacy.Desktop.exe', 'Uten.Legacy.Core.dll', 'BouncyCastle.Cryptography.dll',
            'Uten.Legacy.Desktop.exe.config', 'BouncyCastle-LICENSE.md', 'uten.client.json')
        foreach ($approvedName in $approvedFiles) {
            $inputFile = Get-Item -LiteralPath (Join-Path $plan.OutputDirectory $approvedName) -ErrorAction Stop
            if ($inputFile.PSIsContainer -or ($inputFile.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw 'Company payload source must be a regular approved file.'
            }
            Copy-Item -LiteralPath $inputFile.FullName -Destination (Join-Path $payloadDirectory $approvedName)
        }
        $receiptOutput = Join-Path $buildRoot "receipts/$($plan.Architecture)-company.json"
        & $PythonPath $packageTool receipt --source-root $workspaceRoot --source-state $sourceStateFile --bundle $payloadDirectory --architecture $plan.Architecture --configuration Release --distribution-profile Company --output $receiptOutput
        if ($LASTEXITCODE -ne 0) { throw 'Compiled payload does not match the reviewed Company source receipt.' }
        Write-Output "Company candidate snapshot: $payloadDirectory"
    }
}
Write-Output 'Native WPF source compiled and PE architecture checked. No Setup/ZIP or publication performed; Win7 target-PC acceptance remains pending.'
