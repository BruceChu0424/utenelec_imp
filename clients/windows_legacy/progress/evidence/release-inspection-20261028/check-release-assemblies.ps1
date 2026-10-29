param([string]$Root = $PSScriptRoot)
$ErrorActionPreference = 'Stop'
$taskRoot = [IO.Path]::GetFullPath($Root)
$taskInspector = Join-Path $PSScriptRoot 'inspect-release-assembly.ps1'
$taskShell = 'C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe'
$taskFiles = @(
    @{Name='core'; Relative='Uten.Legacy.Core.dll'},
    @{Name='desktop'; Relative='Uten.Legacy.Desktop.exe'},
    @{Name='updater'; Relative='client_updater/Uten.Legacy.Updater.exe'}
)
$taskRecords = @()
foreach ($taskArch in @('x86','x64')) {
    foreach ($taskTarget in $taskFiles) {
        $taskInput = Join-Path (Join-Path $taskRoot $taskArch) $taskTarget.Relative
        $taskOutput = Join-Path $taskRoot ('release-' + $taskArch + '-' + $taskTarget.Name + '-inspection.json')
        # Fresh .NET Framework metadata-only process per identity/architecture.
        & $taskShell -NoProfile -File $taskInspector -AssemblyPath $taskInput -ExpectedArchitecture $taskArch -OutputPath $taskOutput
        if ($LASTEXITCODE -ne 0) { throw ('Release assembly inspection failed: ' + $taskArch + '/' + $taskTarget.Name) }
        $taskRecords += Get-Content -LiteralPath $taskOutput -Raw | ConvertFrom-Json
    }
}
if ($taskRecords.Count -ne 6 -or @($taskRecords | Where-Object { -not $_.passed }).Count -ne 0) { throw 'Six release records required' }
$taskReport = [ordered]@{
    schemaVersion=1; inspectedUtc=[DateTime]::UtcNow.ToString('O'); passed=$true; assemblyCount=6
    expectedTargetFramework='.NETFramework,Version=v4.8'; expectedConfiguration='Release'; expectedDistribution='Unreviewed'
    sourceVersion='2.5.34+2534'; expectedAssemblyVersion='2.5.34.0'; expectedFileAndProductVersion='2.5.34.2534'
    expectedDebuggableModes=2; forbiddenTypePatterns=@('Tests namespace','Checks','Fixture'); desktopMaximumBytes=33554432
    metadataOnly=$true; applicationStarted=$false; companyProfileAccessed=$false; sourceModified=$false
    inspector=[ordered]@{path=$taskInspector;sha256=(Get-FileHash -LiteralPath $taskInspector -Algorithm SHA256).Hash.ToLowerInvariant()}
    driver=[ordered]@{path=$PSCommandPath;sha256=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()}
    rerunCommand='powershell.exe -NoProfile -File build/windows-wpf/unit-business-release/check-release-assemblies.ps1'
    records=$taskRecords
}
$taskReport | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath (Join-Path $taskRoot 'release-assembly-inspection.json') -Encoding UTF8
$taskRecords | ForEach-Object {
    [ordered]@{arch=$_.expectedArchitecture;assembly=$_.assemblyName;passed=$_.passed;bytes=$_.lengthBytes;typeCount=$_.totalTypeCount;
        forbiddenTypes=$_.forbiddenTypes.Count;debuggableModes=$_.debuggableModes;fileVersion=$_.fileVersion;sha256=$_.sha256} | ConvertTo-Json -Compress
}
Write-Output 'UNIT_BUSINESS_SIX_RELEASE_ASSEMBLIES_PASSED'
