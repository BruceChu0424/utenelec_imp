<#
.SYNOPSIS
Starts the local backend without compiling test sources.
.EXAMPLE
.\dev.ps1
.EXAMPLE
.\dev.ps1 -BuildDirectory target-dev-secondary -Port 8081
#>
[CmdletBinding()]
param(
    [ValidatePattern('^target-dev(?:-[A-Za-z0-9][A-Za-z0-9._-]*)?$')]
    [string]$BuildDirectory = 'target-dev',

    [ValidateRange(1, 65535)]
    [int]$Port
)

$ErrorActionPreference = 'Stop'
# PowerShell 7 can turn native exit codes into exceptions via a caller preference.
# Handle Maven's status ourselves so its exit code is preserved on every version.
$PSNativeCommandUseErrorActionPreference = $false

# Developer bootstrap only. Formal releases already contain this exact offline
# payload; the company service never downloads packages while starting.
$forecastRoot = Join-Path $PSScriptRoot '../services/material_forecast'
if ((Test-Path -LiteralPath (Join-Path $forecastRoot 'build_payload.py')) -and
    -not $env:UTEN_MATERIAL_FORECAST_PAYLOAD_DIRECTORY -and
    $env:UTEN_MATERIAL_FORECAST_MANAGE_RUNTIME -ne 'false') {
    $forecastPython = $env:UTEN_MATERIAL_FORECAST_BASE_PYTHON_EXECUTABLE
    if (-not $forecastPython) {
        foreach ($forecastRegistry in @('HKCU:\Software\Python\PythonCore\3.12\InstallPath', 'HKLM:\Software\Python\PythonCore\3.12\InstallPath')) {
            if (Test-Path -LiteralPath $forecastRegistry) {
                $forecastKey = Get-Item -LiteralPath $forecastRegistry
                $forecastCandidate = $forecastKey.GetValue('ExecutablePath')
                if (-not $forecastCandidate) { $forecastCandidate = Join-Path $forecastKey.GetValue('') 'python.exe' }
                if (Test-Path -LiteralPath $forecastCandidate -PathType Leaf) { $forecastPython = $forecastCandidate; break }
            }
        }
    }
    if ($forecastPython) {
        $forecastPayload = @(& $forecastPython -I (Join-Path $forecastRoot 'build_payload.py') --development-cache)
        if ($LASTEXITCODE -eq 0) {
            $forecastResult = $forecastPayload[-1] | ConvertFrom-Json
            $env:UTEN_MATERIAL_FORECAST_PAYLOAD_DIRECTORY = $forecastResult.payload
        } else {
            Write-Warning 'Material forecast payload preparation failed; runtime status will report unavailable.'
        }
    } else {
        Write-Warning 'Material forecast requires the installed PythonCore 3.12 base runtime.'
    }
}
$mavenCommand = Get-Command mvn -CommandType Application -ErrorAction Stop | Select-Object -First 1
$mavenArguments = @('-Pdev-run', "-Duten.build.directory=$BuildDirectory")
if ($PSBoundParameters.ContainsKey('Port')) {
    $mavenArguments += "-Dspring-boot.run.arguments=--server.port=$Port"
}
$mavenArguments += 'spring-boot:run'

# The working directory controls .env loading as well as Maven's project settings.
# Keep the JVM in the foreground so Ctrl+C and startup failures reach this terminal.
Push-Location -LiteralPath $PSScriptRoot
try {
    & $mavenCommand.Source @mavenArguments
    $mavenExitCode = $LASTEXITCODE
} finally {
    Pop-Location
}
exit $mavenExitCode
