param([Parameter(Mandatory=$true)][string]$AssemblyPath,
      [Parameter(Mandatory=$true)][ValidateSet('x86','x64')][string]$ExpectedArchitecture,
      [Parameter(Mandatory=$true)][string]$OutputPath)
$ErrorActionPreference = 'Stop'
$taskFile = Get-Item -LiteralPath $AssemblyPath
$taskBytes = [IO.File]::ReadAllBytes($taskFile.FullName)
if ([BitConverter]::ToUInt16($taskBytes, 0) -ne 0x5a4d) { throw 'Invalid DOS signature' }
$taskPeOffset = [BitConverter]::ToInt32($taskBytes, 0x3c)
if ($taskPeOffset -lt 64 -or $taskPeOffset + 256 -ge $taskBytes.Length -or [BitConverter]::ToUInt32($taskBytes, $taskPeOffset) -ne 0x4550) { throw 'Invalid PE signature' }
$taskMachine = [BitConverter]::ToUInt16($taskBytes, $taskPeOffset + 4)
$taskSectionCount = [BitConverter]::ToUInt16($taskBytes, $taskPeOffset + 6)
$taskOptionalSize = [BitConverter]::ToUInt16($taskBytes, $taskPeOffset + 20)
$taskOptional = $taskPeOffset + 24
$taskMagic = [BitConverter]::ToUInt16($taskBytes, $taskOptional)
$taskDataDirectory = if ($taskMagic -eq 0x10b) { $taskOptional + 96 } elseif ($taskMagic -eq 0x20b) { $taskOptional + 112 } else { throw 'Invalid PE optional-header magic' }
$taskSectionTable = $taskOptional + $taskOptionalSize
$taskSections = @()
for ($taskIndex=0; $taskIndex -lt $taskSectionCount; $taskIndex++) {
    $taskOffset = $taskSectionTable + 40 * $taskIndex
    if ($taskOffset + 40 -gt $taskBytes.Length) { throw 'Invalid PE section bounds' }
    $taskSections += [pscustomobject]@{ rva=[BitConverter]::ToUInt32($taskBytes,$taskOffset+12); virtualSize=[BitConverter]::ToUInt32($taskBytes,$taskOffset+8); rawSize=[BitConverter]::ToUInt32($taskBytes,$taskOffset+16); raw=[BitConverter]::ToUInt32($taskBytes,$taskOffset+20) }
}
function Resolve-TaskRva([uint32]$Value) {
    foreach ($taskSection in $taskSections) {
        if ($Value -ge $taskSection.rva -and $Value -lt [uint64]$taskSection.rva + [Math]::Max($taskSection.virtualSize,$taskSection.rawSize)) {
            $taskResolved = [uint64]$taskSection.raw + $Value - $taskSection.rva
            if ($taskResolved -ge $taskBytes.Length) { throw 'RVA outside file' }
            return [int]$taskResolved
        }
    }
    throw 'RVA has no section'
}
$taskClrRva = [BitConverter]::ToUInt32($taskBytes,$taskDataDirectory+14*8)
$taskClrSize = [BitConverter]::ToUInt32($taskBytes,$taskDataDirectory+14*8+4)
if ($taskClrRva -eq 0 -or $taskClrSize -lt 72) { throw 'No CLR header' }
$taskClrOffset = Resolve-TaskRva $taskClrRva
$taskClrFlags = [BitConverter]::ToUInt32($taskBytes,$taskClrOffset+16)
$taskMetadataOffset = Resolve-TaskRva ([BitConverter]::ToUInt32($taskBytes,$taskClrOffset+8))
if ([BitConverter]::ToUInt32($taskBytes,$taskMetadataOffset) -ne 0x424a5342) { throw 'Invalid CLR metadata signature' }
$taskClrVersionLength = [BitConverter]::ToUInt32($taskBytes,$taskMetadataOffset+12)
if ($taskClrVersionLength -lt 1 -or $taskClrVersionLength -gt 256 -or $taskMetadataOffset + 16 + $taskClrVersionLength -gt $taskBytes.Length) { throw 'Invalid CLR metadata version length' }
$taskClrVersion = [Text.Encoding]::ASCII.GetString($taskBytes,$taskMetadataOffset+16,$taskClrVersionLength).Trim([char]0)

# Metadata-only load. Each invocation is a fresh .NET Framework process so assembly
# identity unification cannot accidentally inspect the other architecture's file.
$taskSearchDirectories = @($taskFile.DirectoryName, $taskFile.Directory.Parent.FullName,
    'C:/Program Files (x86)/Reference Assemblies/Microsoft/Framework/.NETFramework/v4.8',
    'C:/Program Files (x86)/Reference Assemblies/Microsoft/Framework/.NETFramework/v4.8/Facades')
[AppDomain]::CurrentDomain.add_ReflectionOnlyAssemblyResolve({ param($sender,$taskEventArgs)
    $taskSimple = (New-Object Reflection.AssemblyName($taskEventArgs.Name)).Name
    foreach ($taskDirectory in $taskSearchDirectories) {
        foreach ($taskExtension in @('.dll','.exe')) {
            $taskCandidate = Join-Path $taskDirectory ($taskSimple + $taskExtension)
            if ([IO.File]::Exists($taskCandidate)) { return [Reflection.Assembly]::ReflectionOnlyLoadFrom($taskCandidate) }
        }
    }
    return [Reflection.Assembly]::ReflectionOnlyLoad($taskEventArgs.Name)
})
$taskAssembly = [Reflection.Assembly]::ReflectionOnlyLoadFrom($taskFile.FullName)
try { $taskTypes = @($taskAssembly.GetTypes()) }
catch {
    $taskException = $_.Exception
    while ($taskException.InnerException) { $taskException = $taskException.InnerException }
    if ($taskException -is [Reflection.ReflectionTypeLoadException]) {
        $taskException.LoaderExceptions | ForEach-Object { [Console]::Error.WriteLine($_.ToString()) }
    }
    throw
}
$taskForbiddenTypes = @($taskTypes | Where-Object { $_.FullName -match '(?i)(^|\.)Tests?(\.|$)|Checks|Fixture' } | ForEach-Object { $_.FullName })
$taskAttributes = @([Reflection.CustomAttributeData]::GetCustomAttributes($taskAssembly))
function Get-TaskAttributeString([string]$Name) {
    $taskAttribute = @($taskAttributes | Where-Object { $_.Constructor.DeclaringType.FullName -eq $Name })
    if ($taskAttribute.Count -eq 0) { return $null }
    if ($taskAttribute.Count -ne 1) { throw ('Duplicate assembly attribute: ' + $Name) }
    return [string]$taskAttribute[0].ConstructorArguments[0].Value
}
$taskDebugAttribute = @($taskAttributes | Where-Object { $_.Constructor.DeclaringType.FullName -eq 'System.Diagnostics.DebuggableAttribute' })
$taskDebugModes = 0
if ($taskDebugAttribute.Count -gt 1) { throw 'Duplicate DebuggableAttribute' }
if ($taskDebugAttribute.Count -eq 1) {
    if ($taskDebugAttribute[0].ConstructorArguments.Count -eq 1) { $taskDebugModes = [int]$taskDebugAttribute[0].ConstructorArguments[0].Value }
    else {
        if ([bool]$taskDebugAttribute[0].ConstructorArguments[0].Value) { $taskDebugModes = $taskDebugModes -bor 1 }
        if ([bool]$taskDebugAttribute[0].ConstructorArguments[1].Value) { $taskDebugModes = $taskDebugModes -bor 256 }
    }
}
$taskConfiguration = Get-TaskAttributeString 'System.Reflection.AssemblyConfigurationAttribute'
$taskDescription = Get-TaskAttributeString 'System.Reflection.AssemblyDescriptionAttribute'
$taskTargetFramework = Get-TaskAttributeString 'System.Runtime.Versioning.TargetFrameworkAttribute'
$taskExpectedMarker = 'UTEN WPF candidate; Configuration=Release; Distribution=Unreviewed'
$taskFailures = @()
if ($taskForbiddenTypes.Count -ne 0) { $taskFailures += 'Test/Checks/Fixture types present' }
if ($taskDescription -cne $taskExpectedMarker -or $taskFile.VersionInfo.Comments -cne $taskExpectedMarker) { $taskFailures += 'Release/Unreviewed marker mismatch' }
if ($taskConfiguration -and $taskConfiguration -cne 'Release') { $taskFailures += 'Non-Release assembly configuration' }
if (($taskDebugModes -band (1 -bor 4 -bor 256)) -ne 0 -or $taskFile.VersionInfo.IsDebug) { $taskFailures += 'Debug tracking/EditAndContinue/DisableOptimizations metadata present' }
if ($taskDebugModes -ne 2) { $taskFailures += 'Release debuggable modes must be exactly 2' }
if ($taskAssembly.GetName().Name -eq 'Uten.Legacy.Desktop' -and $taskFile.Length -gt 33554432) { $taskFailures += 'Desktop exceeds 32 MiB managed payload limit' }
if ($taskTargetFramework -cne '.NETFramework,Version=v4.8') { $taskFailures += 'Wrong target framework' }
if ($taskAssembly.GetName().Version.ToString() -cne '2.5.34.0' -or $taskFile.VersionInfo.FileVersion -cne '2.5.34.2534' -or $taskFile.VersionInfo.ProductVersion -cne '2.5.34.2534') { $taskFailures += 'Application version mismatch' }
if (($ExpectedArchitecture -eq 'x86' -and ($taskMachine -ne 0x14c -or $taskMagic -ne 0x10b -or ($taskClrFlags -band 2) -eq 0)) -or
    ($ExpectedArchitecture -eq 'x64' -and ($taskMachine -ne 0x8664 -or $taskMagic -ne 0x20b -or ($taskClrFlags -band 2) -ne 0))) { $taskFailures += 'Raw PE/CLR architecture mismatch' }
if (($taskClrFlags -band 1) -eq 0 -or ($taskClrFlags -band 0x20000) -ne 0) { $taskFailures += 'Unexpected managed architecture flags' }
$taskResult = [ordered]@{
    schemaVersion=1; path=$taskFile.FullName; expectedArchitecture=$ExpectedArchitecture; lengthBytes=$taskFile.Length
    sha256=(Get-FileHash -LiteralPath $taskFile.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    inspectionMethod='Windows PowerShell .NET Framework ReflectionOnlyLoadFrom + bounded raw PE metadata reads; no application entry point invoked'
    assemblyName=$taskAssembly.GetName().Name; assemblyVersion=$taskAssembly.GetName().Version.ToString()
    fileVersion=$taskFile.VersionInfo.FileVersion; productVersion=$taskFile.VersionInfo.ProductVersion; productName=$taskFile.VersionInfo.ProductName
    assemblyInformationalVersion=(Get-TaskAttributeString 'System.Reflection.AssemblyInformationalVersionAttribute')
    rawPE=[ordered]@{ machine=('0x{0:x4}' -f $taskMachine); optionalHeaderMagic=('0x{0:x3}' -f $taskMagic); bitness=$(if($taskMagic -eq 0x20b){64}else{32}); clrFlags=('0x{0:x8}' -f $taskClrFlags); ilOnly=(($taskClrFlags -band 1)-ne 0); requires32Bit=(($taskClrFlags -band 2)-ne 0); prefers32Bit=(($taskClrFlags -band 0x20000)-ne 0); clrMetadataVersion=$taskClrVersion }
    targetFramework=$taskTargetFramework; description=$taskDescription; fileComments=$taskFile.VersionInfo.Comments
    assemblyConfiguration=$taskConfiguration; debuggableModes=$taskDebugModes; inappropriateDebugMetadata=(($taskDebugModes -band 261)-ne 0 -or $taskFile.VersionInfo.IsDebug)
    desktopMaximumBytes=33554432; desktopSizeWithinLimit=($taskAssembly.GetName().Name -ne 'Uten.Legacy.Desktop' -or $taskFile.Length -le 33554432); totalTypeCount=$taskTypes.Count; forbiddenTypes=$taskForbiddenTypes; passed=($taskFailures.Count -eq 0); failures=$taskFailures
}
$taskResult | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
if ($taskFailures.Count -ne 0) { throw ($taskFailures -join '; ') }
