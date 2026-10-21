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
