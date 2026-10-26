[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PackagePath,
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedSha256,
    [Parameter(Mandatory = $true)][long]$BuildNumber,
    [Parameter(Mandatory = $true)][ValidateSet('x64', 'arm64', 'x86')][string]$Architecture,
    [Parameter(Mandatory = $true)][string]$InstallDirectory,
    [Parameter(Mandatory = $true)][int]$ParentProcessId,
    [Parameter(Mandatory = $true)][uint64]$ParentStartFileTime,
    [Parameter(Mandatory = $true)][string]$ReadyEventName,
    [Parameter(Mandatory = $true)][string]$Workspace
)

# This file comes from the installed client, never from the downloaded ZIP.
# Filesystem changes use literal paths and never execute package-supplied code.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$progressPreference = 'SilentlyContinue'
$manifestName = 'uten-client-manifest.json'
$journal = [Collections.Generic.List[object]]::new()
$installChanged = $false
$parentExited = $false
$clientRestarted = $false
$updateLock = $null
$archive = $null
$parentProcess = $null
$readyEvent = $null

function Full-Path([string]$Path) {
    return [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar)
}

function Assert-Within([string]$Path, [string]$Root) {
    if (-not (Full-Path $Path).StartsWith((Full-Path $Root) + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'A path leaves its allowed directory.'
    }
}

function Assert-NoReparse([string]$Path) {
    $candidate = Full-Path $Path
    while ($candidate) {
        if ([IO.File]::Exists($candidate) -or [IO.Directory]::Exists($candidate)) {
            if (([IO.File]::GetAttributes($candidate) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Links and reparse points are forbidden in update paths.'
            }
        }
        $next = [IO.Path]::GetDirectoryName($candidate)
        if ($next -eq $candidate) { break }
        $candidate = $next
    }
}

function Write-Log([string]$Message) {
    $line = '{0:o} {1}' -f [DateTime]::UtcNow, $Message
    [IO.File]::AppendAllText($script:logPath, $line + [Environment]::NewLine)
}

function File-Sha256([string]$Path) {
    # The installed client may inherit a PowerShell 7 module path before it
    # launches Windows PowerShell 5.1. Hash verification must not depend on the
    # Get-FileHash script module being discoverable in that inherited environment.
    $stream = [IO.File]::OpenRead($Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose(); $stream.Dispose() }
}

function Assert-ReleasePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Length -gt 230 -or
        $Path.Contains('\') -or $Path.StartsWith('/') -or $Path.EndsWith('/') -or
        $Path -match '[\x00-\x1f<>:"|?*]') { throw 'Unsafe release file path.' }
    foreach ($segment in $Path.Split('/')) {
        if ($segment -in @('', '.', '..') -or $segment -match '[. ]$' -or
            $segment -match '^(?i:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)') {
            throw 'Unsafe release path segment.'
        }
    }
    # Restrict replacements to the Flutter executable, DLLs and runtime data.
    # In particular, an update can never overwrite client_updater/ or settings.
    if ($Path -cne 'uten_imp.exe' -and $Path -cne $manifestName -and
        $Path -cnotmatch '^data/.+' -and $Path -cnotmatch '^[^/]+\.dll$') {
        throw 'Release contains a file outside the Flutter runtime.'
    }
}

function Read-Manifest($Value, [bool]$RequireTarget) {
    if ($Value.schemaVersion -ne 1 -or $Value.platform -cne 'windows' -or
        $Value.executable -cne 'uten_imp.exe') { throw 'Unsupported release manifest.' }
    if ($RequireTarget -and ($Value.architecture -cne $Architecture -or
        [long]$Value.buildNumber -ne $BuildNumber)) { throw 'Release platform/build does not match.' }
    $packageKind = 'update'
    $kindProperty = $Value.PSObject.Properties['packageKind']
    if ($null -ne $kindProperty) { $packageKind = [string]$kindProperty.Value }
    if ($packageKind -cnotin @('update', 'installer') -or
        ($RequireTarget -and $packageKind -cne 'update')) {
        throw 'Only application update packages may replace an installed client.'
    }
    $records = @($Value.files)
    if ($records.Count -lt 4 -or $records.Count -gt 20000) { throw 'Invalid release file count.' }
    $files = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    [long]$expanded = 0
    $bootstrapUpdaterSeen = $false
    foreach ($record in $records) {
        $relative = [string]$record.path
        $bootstrapUpdater = -not $RequireTarget -and $packageKind -ceq 'installer' -and
            $relative -ceq 'client_updater/client_updater.ps1'
        if (-not $bootstrapUpdater) { Assert-ReleasePath $relative }
        if ($relative -ceq $manifestName -or $files.ContainsKey($relative) -or
            ($bootstrapUpdater -and $bootstrapUpdaterSeen) -or
            [string]$record.sha256 -cnotmatch '^[a-f0-9]{64}$' -or
            [long]$record.size -lt 0 -or [long]$record.size -gt 536870912 -or
            ($bootstrapUpdater -and [long]$record.size -eq 0)) {
            throw 'Invalid or duplicate release file.'
        }
        $expanded += [long]$record.size
        if ($expanded -gt 2147483648) { throw 'Expanded release exceeds 2 GiB.' }
        if ($bootstrapUpdater) {
            # A first-install manifest accounts for the trusted updater, but it
            # never belongs to the replacement/removal/rollback runtime journal.
            $bootstrapUpdaterSeen = $true
            continue
        }
        $files.Add($relative, $record)
    }
    if ($packageKind -ceq 'installer' -and -not $bootstrapUpdaterSeen) {
        throw 'The first-install manifest is missing its fixed updater.'
    }
    foreach ($required in @('uten_imp.exe', 'flutter_windows.dll', 'data/app.so', 'data/icudtl.dat')) {
        if (-not $files.ContainsKey($required)) { throw "Missing required runtime: $required" }
    }
    return ,$files
}

function Backup-Target([string]$Relative) {
    Assert-ReleasePath $Relative
    $target = Join-Path $script:installRoot ($Relative.Replace('/', '\'))
    Assert-Within $target $script:installRoot
    Assert-NoReparse $target
    if ([IO.Directory]::Exists($target)) { throw 'A directory conflicts with a release file.' }
    $existed = [IO.File]::Exists($target)
    $backup = Join-Path $script:backupRoot ($Relative.Replace('/', '\'))
    if ($existed) {
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($backup)) | Out-Null
        [IO.File]::Copy($target, $backup, $false)
    }
    $script:journal.Add([pscustomobject]@{ Target = $target; Backup = $backup; Existed = $existed })
}

function Restart-Client {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = Join-Path $script:installRoot 'uten_imp.exe'
    $start.WorkingDirectory = $script:installRoot
    $start.UseShellExecute = $false
    $started = [Diagnostics.Process]::Start($start)
    if ($null -eq $started) { throw 'Client restart did not create a process.' }
    # Detect immediate loader/crash failures while the old version is recoverable.
    try {
        if ($started.WaitForExit(8000)) { throw 'Updated client exited during startup.' }
    } finally { $started.Dispose() }
}

function Copy-WhenReleased([string]$Source, [string]$Target) {
    # A signaled parent process does not prove that all executable image readers
    # (including security scanners) released their file handles. Retry only the
    # actual Windows sharing/lock violations, with a bounded wait; permission,
    # disk, integrity, and all other failures still trigger the normal rollback.
    $waiting = [Diagnostics.Stopwatch]::StartNew()
    $logged = $false
    while ($true) {
        try {
            [IO.File]::Copy($Source, $Target, $true)
            return
        } catch {
            $cause = $_.Exception
            while ($null -ne $cause.InnerException) { $cause = $cause.InnerException }
            $nativeError = $cause.HResult -band 65535
            if ($cause -isnot [IO.IOException] -or $nativeError -notin @(32, 33) -or
                $waiting.ElapsedMilliseconds -ge 8000) { throw }
            if (-not $logged) {
                Write-Log ('Waiting for an exited client image file lock: {0}' -f [IO.Path]::GetFileName($Target))
                $logged = $true
            }
            Start-Sleep -Milliseconds 100
        }
    }
}

try {
    $stagingRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'com.uten.uten_imp\client-updates'
    $workspaceRoot = Full-Path $Workspace
    $package = Full-Path $PackagePath
    $installRoot = Full-Path $InstallDirectory
    if ($BuildNumber -lt 1 -or $BuildNumber -gt 65535) { throw 'Windows build number is out of range.' }
    Assert-Within $workspaceRoot $stagingRoot
    Assert-Within $package $stagingRoot
    if ($workspaceRoot -eq $installRoot -or $installRoot.StartsWith($stagingRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The program directory must be outside update staging.'
    }
    Assert-NoReparse $workspaceRoot
    Assert-NoReparse $package
    Assert-NoReparse $installRoot
    $logPath = Join-Path $stagingRoot 'last-update.log'
    $resultPath = Join-Path $stagingRoot 'last-update-result.json'
    $backupRoot = Join-Path $workspaceRoot 'rollback'
    $extractRoot = Join-Path $workspaceRoot 'extracted'
    Write-Log "Preparing client build $BuildNumber ($Architecture)."

    # Acquire one lock per installation before capturing the exact parent handle.
    $updateLock = [IO.File]::Open((Join-Path $installRoot '.uten-client-update.lock'),
        [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $parentProcess = [Diagnostics.Process]::GetProcessById($ParentProcessId)
    $null = $parentProcess.Handle
    if ([uint64]$parentProcess.StartTime.ToUniversalTime().ToFileTimeUtc() -ne $ParentStartFileTime -or
        -not $parentProcess.MainModule.FileName.Equals((Join-Path $installRoot 'uten_imp.exe'), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Parent process identity does not match this installation.'
    }
    $readyEvent = [Threading.EventWaitHandle]::OpenExisting($ReadyEventName)
    $readyEvent.Set() | Out-Null
    if (-not $parentProcess.WaitForExit(120000)) {
        throw 'Client is still open; no program files were changed.'
    }
    $parentExited = $true
    # The identity-bound wait is finished. Release the native process/module
    # bookkeeping before touching the executable image it used to own.
    $parentProcess.Dispose()
    $parentProcess = $null

    # Hold the exact ZIP open with no write/delete sharing across hash and extraction.
    $packageStream = [IO.File]::Open($package, [IO.FileMode]::Open,
        [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if ($packageStream.Length -lt 1 -or $packageStream.Length -gt 536870912) {
            throw 'Update archive size is invalid.'
        }
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $actualHash = ([BitConverter]::ToString($sha.ComputeHash($packageStream))).Replace('-', '').ToLowerInvariant()
        } finally { $sha.Dispose() }
        if ($actualHash -cne $ExpectedSha256) { throw 'Downloaded package SHA-256 does not match.' }
        $packageStream.Position = 0
        Add-Type -AssemblyName System.IO.Compression
        $archive = [IO.Compression.ZipArchive]::new($packageStream, [IO.Compression.ZipArchiveMode]::Read, $true)
        try {
            if ($archive.Entries.Count -gt 20001) { throw 'Archive contains too many entries.' }
            $manifestEntries = @($archive.Entries | Where-Object { $_.FullName -ceq $manifestName })
            if ($manifestEntries.Count -ne 1 -or $manifestEntries[0].Length -gt 8388608) {
                throw 'Release manifest is missing or too large.'
            }
            $reader = [IO.StreamReader]::new($manifestEntries[0].Open(), [Text.Encoding]::UTF8, $true)
            try { $manifestJson = $reader.ReadToEnd() } finally { $reader.Dispose() }
            $manifest = $manifestJson | ConvertFrom-Json
            $releaseFiles = Read-Manifest $manifest $true
            $entries = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($entry in $archive.Entries) {
                $relative = $entry.FullName
                Assert-ReleasePath $relative
                $unixMode = ([long]$entry.ExternalAttributes -shr 16) -band 61440
                if ($entries.ContainsKey($relative) -or $unixMode -eq 40960 -or
                    ($entry.ExternalAttributes -band 1024) -ne 0) { throw 'Duplicate or linked archive entry.' }
                $entries.Add($relative, $entry)
                if ($relative -ceq $manifestName) { continue }
                if (-not $releaseFiles.ContainsKey($relative) -or
                    $entry.Length -ne [long]$releaseFiles[$relative].size) { throw 'Archive does not match its manifest.' }
            }
            if ($entries.Count -ne $releaseFiles.Count + 1) { throw 'Archive omits release files.' }
            [IO.Directory]::CreateDirectory($extractRoot) | Out-Null
            foreach ($record in $releaseFiles.Values) {
                $relative = [string]$record.path
                $target = Join-Path $extractRoot ($relative.Replace('/', '\'))
                Assert-Within $target $extractRoot
                [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
                $source = $entries[$relative].Open()
                $destination = [IO.File]::Open($target, [IO.FileMode]::CreateNew)
                try {
                    $buffer = [byte[]]::new(65536)
                    [long]$written = 0
                    while (($count = $source.Read($buffer, 0, $buffer.Length)) -gt 0) {
                        $written += $count
                        if ($written -gt [long]$record.size) { throw 'Archive stream exceeds declared size.' }
                        $destination.Write($buffer, 0, $count)
                    }
                    if ($written -ne [long]$record.size) { throw 'Archive stream is truncated.' }
                } finally { $source.Dispose(); $destination.Dispose() }
                if ((File-Sha256 $target) -cne [string]$record.sha256) {
                    throw 'An extracted file does not match its SHA-256.'
                }
            }
            # Bind the binary's actual PE build to the release metadata.
            $version = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $extractRoot 'uten_imp.exe'))
            if ($version.FilePrivatePart -ne $BuildNumber) { throw 'Executable build differs from release metadata.' }
            $binary = [IO.BinaryReader]::new([IO.File]::OpenRead((Join-Path $extractRoot 'uten_imp.exe')))
            try {
                if ($binary.ReadUInt16() -ne 23117) { throw 'Executable DOS header is invalid.' }
                $binary.BaseStream.Position = 60
                $peOffset = $binary.ReadUInt32()
                $binary.BaseStream.Position = $peOffset
                if ($binary.ReadUInt32() -ne 17744) { throw 'Executable PE header is invalid.' }
                $machine = $binary.ReadUInt16()
                $expectedMachine = @{ x64 = 34404; arm64 = 43620; x86 = 332 }[$Architecture]
                if ($machine -ne $expectedMachine) { throw 'Executable architecture differs from release metadata.' }
            } finally { $binary.Dispose() }
            [IO.File]::WriteAllText((Join-Path $extractRoot $manifestName), $manifestJson, [Text.UTF8Encoding]::new($false))
        } finally { $archive.Dispose(); $archive = $null }
    } finally { $packageStream.Dispose() }

    # Preserve a complete journal before the first replacement. No AppData path
    # enters this transaction, and unknown files are never removed.
    [IO.Directory]::CreateDirectory($backupRoot) | Out-Null
    $oldManifestPath = Join-Path $installRoot $manifestName
    $obsolete = [Collections.Generic.List[string]]::new()
    if ([IO.File]::Exists($oldManifestPath)) {
        Assert-NoReparse $oldManifestPath
        $oldManifest = [IO.File]::ReadAllText($oldManifestPath) | ConvertFrom-Json
        $oldFiles = Read-Manifest $oldManifest $false
        foreach ($oldPath in $oldFiles.Keys) {
            if (-not $releaseFiles.ContainsKey($oldPath)) { $obsolete.Add($oldPath) }
        }
    }
    foreach ($record in $releaseFiles.Values) { Backup-Target ([string]$record.path) }
    foreach ($relative in $obsolete) { Backup-Target $relative }
    Backup-Target $manifestName
    $journal | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $workspaceRoot 'rollback-journal.json') -Encoding UTF8
    $installChanged = $true
    foreach ($record in $releaseFiles.Values) {
        $relative = [string]$record.path
        $target = Join-Path $installRoot ($relative.Replace('/', '\'))
        Assert-NoReparse $target
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
        Copy-WhenReleased (Join-Path $extractRoot ($relative.Replace('/', '\'))) $target
    }
    foreach ($relative in $obsolete) { [IO.File]::Delete((Join-Path $installRoot ($relative.Replace('/', '\')))) }
    Copy-WhenReleased (Join-Path $extractRoot $manifestName) $oldManifestPath
    Write-Log 'Program files replaced; restarting the client.'
    Restart-Client
    $clientRestarted = $true
    $installChanged = $false
    @{ status = 'updated'; buildNumber = $BuildNumber; backupDirectory = $backupRoot; completedAt = [DateTime]::UtcNow.ToString('o') } |
        ConvertTo-Json | Set-Content -LiteralPath $resultPath -Encoding UTF8
    Write-Log "Client restarted successfully. Recovery backup: $backupRoot"
    # Only remove this job's verified input and extraction, after the new process
    # survived startup. Retain its complete rollback backup for recovery.
    try {
        Assert-Within $extractRoot $workspaceRoot
        Assert-NoReparse $extractRoot
        if ([IO.Directory]::Exists($extractRoot)) {
            Remove-Item -LiteralPath $extractRoot -Recurse -Force
        }
        Assert-Within $package $stagingRoot
        Assert-NoReparse $package
        [IO.File]::Delete($package)
    } catch { Write-Log "Update completed; temporary cleanup deferred: $($_.Exception.Message)" }
} catch {
    $failure = $_.Exception.Message
    if (Get-Variable -Name logPath -ErrorAction SilentlyContinue) { Write-Log "UPDATE FAILED: $failure" }
    $rollbackComplete = $true
    if ($installChanged) {
        for ($index = $journal.Count - 1; $index -ge 0; $index--) {
            $item = $journal[$index]
            try {
                Assert-Within $item.Target $installRoot
                Assert-NoReparse $item.Target
                if ($item.Existed) { Copy-WhenReleased $item.Backup $item.Target }
                else { [IO.File]::Delete($item.Target) }
            } catch {
                $rollbackComplete = $false
                Write-Log "ROLLBACK FAILED: $($_.Exception.Message). Backup: $backupRoot"
            }
        }
    }
    if (Get-Variable -Name resultPath -ErrorAction SilentlyContinue) {
        @{ status = 'failed'; buildNumber = $BuildNumber; message = $failure; rollbackComplete = $rollbackComplete; backupDirectory = $backupRoot; completedAt = [DateTime]::UtcNow.ToString('o') } |
            ConvertTo-Json | Set-Content -LiteralPath $resultPath -Encoding UTF8
    }
    if ($parentExited -and $rollbackComplete -and -not $clientRestarted) {
        try { Restart-Client; Write-Log 'Previous client restarted after the failed update.' }
        catch { Write-Log "RESTART FAILED: $($_.Exception.Message)" }
    }
    exit 1
} finally {
    if ($null -ne $readyEvent) { $readyEvent.Dispose() }
    if ($null -ne $parentProcess) { $parentProcess.Dispose() }
    if ($null -ne $updateLock) { $updateLock.Dispose() }
}
