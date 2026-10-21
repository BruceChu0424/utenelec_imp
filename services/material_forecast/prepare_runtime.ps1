[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Payload,
    [Parameter(Mandatory=$true)][string]$Cache,
    [string]$BasePython
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
# A sanitized service environment need not contain PATHEXT. PS 5.1 otherwise
# silently fails to classify even an absolute .exe path as a native command.
$env:PATHEXT = '.COM;.EXE;.BAT;.CMD'
try {
    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($BasePython) { $candidates.Add($BasePython) }
    foreach ($registry in @('HKCU:\Software\Python\PythonCore\3.12\InstallPath', 'HKLM:\Software\Python\PythonCore\3.12\InstallPath')) {
        if (Test-Path -LiteralPath $registry) {
            $key = Get-Item -LiteralPath $registry
            $executable = $key.GetValue('ExecutablePath')
            if (-not $executable) { $executable = Join-Path $key.GetValue('') 'python.exe' }
            if ($executable) { $candidates.Add($executable) }
        }
    }
    $selected = $null
    foreach ($candidate in $candidates) {
        if (-not [IO.Path]::IsPathRooted($candidate) -or -not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        # Windows PowerShell 5.1 strips embedded native-argument quotes. Keep
        # this probe quote-free and use its exit status for both PS 5.1 and 7.
        & $candidate -I -c 'import struct,sys; sys.exit(0 if sys.version_info[:2] == (3,12) and struct.calcsize(chr(80)) == 8 else 1)' 2>$null
        if ($LASTEXITCODE -eq 0) { $selected = $candidate; break }
    }
    if (-not $selected) { throw 'Base interpreter unavailable' }
    & $selected -I (Join-Path $PSScriptRoot 'prepare_runtime.py') --payload $Payload --cache $Cache
    exit $LASTEXITCODE
} catch {
    Write-Output '{"schemaVersion":1,"state":"ERROR","errorCode":"BASE_PYTHON_UNAVAILABLE"}'
    exit 2
}
