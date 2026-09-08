param(
    # Explicit scales: 10000 for a quick trial, 100000 for acceptance, 500000 for
    # the large-history reference. Each order also creates a shipment and return.
    [ValidateRange(100,500000)][int]$Orders = 100000,
    [ValidateRange(1,16)][int]$Readers = 8,
    [ValidateRange(100,100000)][int]$Calls = 2000,
    [string]$DatabaseConfig = '',
    [switch]$PrepareOnly,
    [string]$MeasurementGate = '',
    [string]$BuildDirectory = 'target-sales-money-pressure'
)
$ErrorActionPreference = 'Stop'
$serverDirectory = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$previousGate = $env:UTEN_RUN_SALES_MONEY_PRESSURE
try {
    Write-Host "Isolated synthetic projection benchmark: $Orders orders, $Orders shipments, $Orders returns; $Readers readers, $Calls checked queries. This is not write-chain or HTTP throughput."
    $env:UTEN_RUN_SALES_MONEY_PRESSURE = 'true'
    $pressureArguments = @(
        '-q', "-Duten.build.directory=$BuildDirectory",
        '-Dtest=SalesMoneyProjectionPressurePostgresTest',
        "-Duten.sales.pressure.orders=$Orders", "-Duten.sales.pressure.readers=$Readers",
        "-Duten.sales.pressure.calls=$Calls"
    )
    if ($DatabaseConfig) {
        $configPath = (Resolve-Path -LiteralPath $DatabaseConfig).Path
        $pressureArguments += "-Duten.sales.pressure.databaseConfig=$configPath"
    }
    if ($PrepareOnly) {
        if (-not $DatabaseConfig) { throw 'PrepareOnly needs a durable isolated DatabaseConfig.' }
        if ($MeasurementGate) { throw 'PrepareOnly does not wait for a measurement window.' }
        $pressureArguments += '-Duten.sales.pressure.prepareOnly=true'
    }
    if ($MeasurementGate) {
        $gatePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($MeasurementGate)
        if ((Test-Path -LiteralPath $gatePath) -or (Test-Path -LiteralPath "$gatePath.ready")) {
            throw 'Use a new measurement gate path; old run markers must not release timing.'
        }
        $pressureArguments += "-Duten.sales.pressure.measurementGate=$gatePath"
    }
    Push-Location -LiteralPath $serverDirectory
    try {
        & mvn @pressureArguments test
        if ($LASTEXITCODE -ne 0) { throw "Sales money pressure failed with exit code $LASTEXITCODE" }
    } finally { Pop-Location }
} finally { $env:UTEN_RUN_SALES_MONEY_PRESSURE = $previousGate }
