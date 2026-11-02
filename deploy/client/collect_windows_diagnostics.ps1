# Read-only incident collection. Writes one new private local report; no upload,
# credentials, preferences, business documents, memory dumps or system changes.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$InstallDirectory,
    [string]$OutputDirectory = (Join-Path ([IO.Path]::GetTempPath()) ('uten-diagnostics-' + [Guid]::NewGuid().ToString('N'))),
    [ValidateRange(1, 30)][int]$Days = 7
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$install = [IO.Path]::GetFullPath($InstallDirectory)
if (-not [IO.Directory]::Exists($install)) { throw 'Supply the existing client installation directory.' }
if (Test-Path -LiteralPath $OutputDirectory) { throw 'Use a new output directory to preserve existing incident evidence.' }
[IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($OutputDirectory)) | Out-Null
$issues = [Collections.Generic.List[string]]::new()
$os = Get-CimInstance Win32_OperatingSystem
$modules = foreach ($name in @('uten_imp.exe', 'flutter_windows.dll', 'Uten.Legacy.Desktop.exe', 'Uten.Legacy.Updater.exe')) {
    $path = Join-Path $install $name
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $file = Get-Item -LiteralPath $path
        [PSCustomObject]@{ Name = $name; FileVersion = $file.VersionInfo.FileVersion
            ProductVersion = $file.VersionInfo.ProductVersion; Bytes = $file.Length
            Sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
}
$events = @()
try {
    $records = @(Get-WinEvent -FilterHashtable @{LogName='Application'; Id=1000,1001,1002
        StartTime=(Get-Date).AddDays(-$Days)} -ErrorAction SilentlyContinue)
    $events = @($records | Where-Object {
        $_.Message -match 'uten_imp\.exe|Uten\.Legacy\.(Desktop|Updater)\.exe|uten_native_window_regression\.exe'
    } | Select-Object -First 100 | ForEach-Object {
        [PSCustomObject]@{ AtUtc = $_.TimeCreated.ToUniversalTime().ToString('o')
            EventId = $_.Id; Provider = $_.ProviderName; Message = $_.Message }
    })
} catch { $issues.Add('Application event log could not be read: ' + $_.Exception.GetType().Name) }
$processes = @(Get-Process -Name uten_imp,Uten.Legacy.Desktop,Uten.Legacy.Updater -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        [PSCustomObject]@{ Id = $_.Id; Name = $_.ProcessName; Responding = $_.Responding
            WorkingSetBytes = $_.WorkingSet64; CpuSeconds = $_.CPU
            StartedAtUtc = $_.StartTime.ToUniversalTime().ToString('o') }
    } catch { $issues.Add('A client process exited during collection.') }
})
$dumps = @(Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'CrashDumps') -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^(uten_imp|Uten\.Legacy\.(Desktop|Updater))\.exe' } |
    Select-Object Name,Length,@{Name='ModifiedAtUtc';Expression={$_.LastWriteTimeUtc.ToString('o')}})
function Read-UpdateDiagnosticFile([string]$Path, [int]$Limit) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $file = Get-Item -LiteralPath $Path
    if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        $issues.Add('Skipped a linked update diagnostic file.')
        return $null
    }
    $stream = [IO.File]::Open($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $take = [int][Math]::Min([long]$Limit, $stream.Length)
        $offset = [Math]::Max([long]0, $stream.Length - $take)
        [void]$stream.Seek($offset, [IO.SeekOrigin]::Begin)
        $buffer = New-Object byte[] $take
        $read = 0
        while ($read -lt $take) {
            $count = $stream.Read($buffer, $read, $take - $read)
            if ($count -eq 0) { break }
            $read += $count
        }
        return [PSCustomObject]@{ Name=$file.Name; Bytes=$file.Length; TailOnly=($offset -gt 0)
            ModifiedAtUtc=$file.LastWriteTimeUtc.ToString('o'); Text=[Text.Encoding]::UTF8.GetString($buffer,0,$read) }
    } finally { $stream.Dispose() }
}
$updateRoot = Join-Path $env:LOCALAPPDATA 'com.uten.uten_imp\client-updates'
$updaterPath = Join-Path $install 'client_updater\client_updater.ps1'
$flutterUpdateApplicable = Test-Path -LiteralPath (Join-Path $install 'uten_imp.exe') -PathType Leaf
$updateDiagnostics = [ordered]@{ Applicable=$flutterUpdateApplicable; RuntimeFamily='flutter'
    UpdaterPresent=(Test-Path -LiteralPath $updaterPath -PathType Leaf)
    UpdaterSha256=$null; StagingDirectoryExists=(Test-Path -LiteralPath $updateRoot -PathType Container)
    LastUpdateLog=$null; LastUpdateResult=$null; StagedPackageMetadata=@() }
try {
  if ($flutterUpdateApplicable) {
    if ($updateDiagnostics.UpdaterPresent) {
        $updateDiagnostics.UpdaterSha256 = (Get-FileHash -LiteralPath $updaterPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $updateDiagnostics.LastUpdateLog = Read-UpdateDiagnosticFile (Join-Path $updateRoot 'last-update.log') 65536
    $updateDiagnostics.LastUpdateResult = Read-UpdateDiagnosticFile (Join-Path $updateRoot 'last-update-result.json') 16384
    $updateDiagnostics.StagedPackageMetadata = @(Get-ChildItem -LiteralPath $updateRoot -File -Filter '*.zip' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 5 Name,Length,@{Name='ModifiedAtUtc';Expression={$_.LastWriteTimeUtc.ToString('o')}})
  }
} catch { $issues.Add('Update diagnostics could not be fully read: ' + $_.Exception.GetType().Name) }
$report = [ordered]@{ SchemaVersion=1; CollectedAtUtc=[DateTime]::UtcNow.ToString('o')
    Os=[ordered]@{ Caption=$os.Caption; Version=$os.Version; Build=$os.BuildNumber; Architecture=$os.OSArchitecture }
    InstallDirectory=$install; Modules=@($modules); Processes=$processes; Events=$events
    AvailableDumpMetadata=$dumps; UpdateDiagnostics=$updateDiagnostics; Issues=@($issues)
    Scope='Local read-only diagnostics. Dump contents and business/authentication data were not collected.' }
$reportPath = Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) 'windows-diagnostics.json'
[IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 7), (New-Object Text.UTF8Encoding($false)))
Write-Output $reportPath
