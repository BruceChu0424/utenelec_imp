# Integration regression with isolated fixture executables, never the real app.
# Run on Windows: powershell -NoProfile -File deploy/client/test_windows_updater.ps1
[CmdletBinding()]
param([string]$Python = 'python')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$taskId = [Guid]::NewGuid().ToString('N')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "uten-client-updater-tests-$taskId"
$stagingRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'com.uten.uten_imp\client-updates'
$jobRoot = Join-Path $stagingRoot "integration-$taskId"
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$updater = Join-Path $repositoryRoot 'windows\runner\client_updater.ps1'
$packager = Join-Path $PSScriptRoot 'package_windows.py'
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
[IO.Directory]::CreateDirectory($jobRoot) | Out-Null
$ownedProcesses = [Collections.Generic.List[Diagnostics.Process]]::new()
$priorUpdateState = @{}
foreach ($name in @('last-update.log', 'last-update-result.json')) {
    $path = Join-Path $stagingRoot $name
    $priorUpdateState[$name] = if ([IO.File]::Exists($path)) { [IO.File]::ReadAllBytes($path) } else { $null }
}

function Fixture([string]$Directory, [int]$BuildNumber, [bool]$Crash) {
    [IO.Directory]::CreateDirectory($Directory) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $Directory 'data\flutter_assets')) | Out-Null
    $crashCode = if ($Crash) { 'return;' } else { 'System.Threading.Thread.Sleep(-1);' }
    $fixtureTypeId = [Guid]::NewGuid().ToString('N')
    $source = @"
using System;
using System.Reflection;
[assembly: AssemblyFileVersion("1.0.0.$BuildNumber")]
[assembly: AssemblyVersion("1.0.0.$BuildNumber")]
namespace Fixture$fixtureTypeId {
  public class Program {
    public static void Main() {
      System.IO.File.WriteAllText(System.IO.Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "started.txt"), "$BuildNumber");
      $crashCode
    }
  }
}
"@
    $fixtureSource = Join-Path $testRoot "$fixtureTypeId.cs"
    [IO.File]::WriteAllText($fixtureSource, $source)
    $compiler = Join-Path ([Environment]::GetFolderPath('Windows')) 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    & $compiler /nologo /target:winexe /platform:x64 "/out:$(Join-Path $Directory 'uten_imp.exe')" $fixtureSource
    if ($LASTEXITCODE -ne 0) { throw 'Fixture executable compilation failed.' }
    foreach ($relative in @('flutter_windows.dll', 'data\app.so', 'data\icudtl.dat', 'data\flutter_assets\AssetManifest.bin')) {
        [IO.File]::WriteAllText((Join-Path $Directory $relative), "fixture-$BuildNumber")
    }
}

function Stop-OwnedClient([string]$Directory) {
    foreach ($process in [Diagnostics.Process]::GetProcessesByName('uten_imp')) {
        try {
            if ($process.MainModule.FileName.Equals((Join-Path $Directory 'uten_imp.exe'), [StringComparison]::OrdinalIgnoreCase)) {
                $process.Kill()
                $process.WaitForExit(5000) | Out-Null
            }
        } catch { }
        finally { $process.Dispose() }
    }
}

function Run-Case([string]$Name, [bool]$Crash, [bool]$AddTraversal = $false, [bool]$TamperHash = $false) {
    $install = Join-Path $testRoot "$Name\installed"
    $bundle = Join-Path $testRoot "$Name\bundle"
    $job = Join-Path $jobRoot $Name
    [IO.Directory]::CreateDirectory($job) | Out-Null
    Fixture $install 1 $false
    Fixture $bundle 2 $Crash
    $settings = Join-Path $install 'existing-personal-settings.keep'
    [IO.File]::WriteAllText($settings, 'preserve-me')
    $package = Join-Path $job 'release.zip'
    & $Python $packager --bundle $bundle --output $package --build-number 2 --architecture x64 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Fixture packaging failed.' }
    if ($AddTraversal) {
        Add-Type -AssemblyName System.IO.Compression
        $zipStream = [IO.File]::Open($package, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite)
        $zip = [IO.Compression.ZipArchive]::new($zipStream, [IO.Compression.ZipArchiveMode]::Update)
        try {
            $entry = $zip.CreateEntry('../escape.txt')
            $writer = [IO.StreamWriter]::new($entry.Open())
            try { $writer.Write('must never escape') } finally { $writer.Dispose() }
        } finally { $zip.Dispose(); $zipStream.Dispose() }
    }
    $expectedHash = (Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($TamperHash) { $expectedHash = '0' * 64 }
    $parent = [Diagnostics.Process]::Start((Join-Path $install 'uten_imp.exe'))
    $ownedProcesses.Add($parent)
    Start-Sleep -Milliseconds 350
    $startTime = $parent.StartTime.ToUniversalTime().ToFileTimeUtc()
    $eventName = "Local\UtenClientUpdateTest-$taskId-$Name"
    $created = $false
    $ready = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, $eventName, [ref]$created)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe'
    $start.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -PackagePath "{1}" -ExpectedSha256 {2} -BuildNumber 2 -Architecture x64 -InstallDirectory "{3}" -ParentProcessId {4} -ParentStartFileTime {5} -ReadyEventName "{6}" -Workspace "{7}"' -f $updater, $package, $expectedHash, $install, $parent.Id, $startTime, $eventName, $job
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    # A restarted client inherits the helper's standard handles. Reading a
    # redirected pipe to EOF can hang after the helper exits while that client
    # correctly remains alive; durable result JSON carries the failure details.
    $helper = [Diagnostics.Process]::Start($start)
    $ownedProcesses.Add($helper)
    try {
        if (-not $ready.WaitOne(15000)) { throw 'Updater did not become ready within 15 seconds.' }
        if ([IO.File]::ReadAllText((Join-Path $install 'data\app.so')) -ne 'fixture-1') {
            throw 'Updater changed program files while its parent was alive.'
        }
        $parent.Kill()
        $parent.WaitForExit(5000) | Out-Null
        if (-not $helper.WaitForExit(45000)) { throw 'Updater did not finish.' }
        $result = Get-Content -LiteralPath (Join-Path $stagingRoot 'last-update-result.json') -Raw | ConvertFrom-Json
        $shouldFail = $Crash -or $AddTraversal -or $TamperHash
        $expectedStatus = if ($shouldFail) { 'failed' } else { 'updated' }
        $expectedBuild = if ($shouldFail) { 1 } else { 2 }
        if ($result.status -ne $expectedStatus) {
            throw "Unexpected updater result: $($result | ConvertTo-Json -Compress)."
        }
        if ($shouldFail -and -not $result.rollbackComplete) { throw 'The old version did not recover completely.' }
        $actualBuild = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $install 'uten_imp.exe')).FilePrivatePart
        if ($actualBuild -ne $expectedBuild -or [IO.File]::ReadAllText((Join-Path $install 'started.txt')) -ne "$expectedBuild") {
            throw 'The expected version was not restarted.'
        }
        if ([IO.File]::ReadAllText($settings) -ne 'preserve-me') { throw 'Existing unrelated data was changed.' }
        if ([IO.File]::Exists((Join-Path $job 'escape.txt'))) { throw 'ZIP traversal wrote outside extraction.' }
        if (-not $shouldFail -and ([IO.File]::Exists($package) -or [IO.Directory]::Exists((Join-Path $job 'extracted')))) {
            throw 'Successful update retained its downloaded ZIP or extracted runtime.'
        }
        Write-Output "PASS $Name (build $expectedBuild, settings preserved, replacement waited for parent exit)"
    } finally {
        Stop-OwnedClient $install
        $ready.Dispose()
    }
}

try {
    Run-Case 'automatic-replacement' $false
    Run-Case 'startup-failure-rollback' $true
    Run-Case 'zip-traversal-rejected' $false $true
    Run-Case 'package-hash-rejected' $false $false $true
} finally {
    foreach ($process in $ownedProcesses) {
        try { if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit(5000) | Out-Null } } catch { }
        $process.Dispose()
    }
    foreach ($name in $priorUpdateState.Keys) {
        $path = Join-Path $stagingRoot $name
        if ($null -eq $priorUpdateState[$name]) { [IO.File]::Delete($path) }
        else { [IO.File]::WriteAllBytes($path, $priorUpdateState[$name]) }
    }
    # Verify absolute cleanup targets before recursively removing test fixtures.
    $temporaryParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    $resolvedTest = [IO.Path]::GetFullPath($testRoot)
    $resolvedJob = [IO.Path]::GetFullPath($jobRoot)
    if ($resolvedTest.StartsWith($temporaryParent + '\uten-client-updater-tests-', [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedTest -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($resolvedJob.StartsWith([IO.Path]::GetFullPath($stagingRoot).TrimEnd('\') + '\integration-', [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedJob -Recurse -Force -ErrorAction SilentlyContinue
    }
}
