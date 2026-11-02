[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$private = Join-Path $repo 'build/mobile/local-backend'
New-Item -ItemType Directory -Path $private -Force | Out-Null
$envFile = Join-Path $private 'private.env'
if (-not (Test-Path -LiteralPath $envFile)) {
    function New-LocalSecret { [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)) }
    $adminSecret = New-LocalSecret
    $lines = @(
        'POSTGRES_USER=uten_dev_admin', 'POSTGRES_DB=uten_imp', "POSTGRES_PASSWORD=$adminSecret",
        "UTEN_LOCAL_ADMIN_PASSWORD=$adminSecret", "UTEN_LOCAL_MIGRATOR_PASSWORD=$(New-LocalSecret)",
        "UTEN_LOCAL_RUNTIME_PASSWORD=$(New-LocalSecret)", "UTEN_JWT_SECRET=$(New-LocalSecret)",
        "UTEN_PGP_MASTER_KEY=$(New-LocalSecret)", "UTEN_HMAC_KEY=$(New-LocalSecret)",
        'BOOTSTRAP_ADMIN_LOGIN=mobile_review_admin', "BOOTSTRAP_ADMIN_PASSWORD=$(New-LocalSecret)"
    )
    [IO.File]::WriteAllLines($envFile, $lines)
}
$values = @{}
Get-Content -LiteralPath $envFile | ForEach-Object {
    $pair = $_.Split('=', 2); if ($pair.Length -eq 2) { $values[$pair[0]] = $pair[1] }
}
$name = 'uten-mobile-review-20261102-pg16'
$existing = & docker ps -a --filter "name=^/$name`$" --format '{{.Names}}'
if (-not $existing) {
    $image = 'postgres:16.15-alpine'
    & docker run -d --name $name --label 'uten.task=mobile-review-20261102' -p '127.0.0.1:5548:5432' --env-file $envFile $image
    if ($LASTEXITCODE -ne 0) { throw 'Unable to create isolated local database' }
} else {
    $label = & docker inspect $name --format '{{index .Config.Labels "uten.task"}}'
    if ($label -ne 'mobile-review-20261102') { throw 'Existing container identity mismatch' }
    & docker start $name | Out-Null
}
for ($attempt = 0; $attempt -lt 30; $attempt++) {
    & docker exec $name pg_isready -h 127.0.0.1 -U uten_dev_admin -d uten_imp *> $null
    if ($LASTEXITCODE -eq 0) { break }
    Start-Sleep -Seconds 1
}
$prepared = Join-Path $private 'roles-prepared'
if (-not (Test-Path -LiteralPath $prepared)) {
    $identity = & docker exec $name psql -U uten_dev_admin -d uten_imp -Atc 'select system_identifier from pg_control_system()'
    & docker cp (Join-Path $repo 'server/ops/prepare-local-postgres-roles.sql') "${name}:/tmp/mobile-roles.sql"
    & docker exec --env-file $envFile $name psql -X -U uten_dev_admin -d uten_imp -v ON_ERROR_STOP=1 -v 'local_dev_confirm=PREPARE LOCAL uten_imp' -v "expected_system_identifier=$identity" -f /tmp/mobile-roles.sql
    if ($LASTEXITCODE -ne 0) { throw 'Isolated role preparation failed' }
    Set-Content -LiteralPath $prepared -Value $identity
}
foreach ($key in @('UTEN_JWT_SECRET','UTEN_PGP_MASTER_KEY','UTEN_HMAC_KEY','BOOTSTRAP_ADMIN_LOGIN','BOOTSTRAP_ADMIN_PASSWORD')) {
    [Environment]::SetEnvironmentVariable($key, $values[$key], 'Process')
}
$env:UTEN_DB_URL = 'jdbc:postgresql://127.0.0.1:5548/uten_imp'
$env:UTEN_DB_USER = 'uten'
$env:UTEN_DB_PASSWORD = $values['UTEN_LOCAL_RUNTIME_PASSWORD']
$env:UTEN_DEV_MIGRATOR_DB_USER = 'uten_migrator'
$env:UTEN_DEV_MIGRATOR_DB_PASSWORD = $values['UTEN_LOCAL_MIGRATOR_PASSWORD']
$env:UTEN_PROFILE = 'dev'
$env:SERVER_ADDRESS = '127.0.0.1'
$env:UTEN_CORS_ORIGINS = 'http://127.0.0.1:8274,http://127.0.0.1:8273'
$env:UTEN_MATERIAL_FORECAST_MANAGE_RUNTIME = 'false'
$env:UTEN_SMS_PROVIDER = 'log'
$env:UTEN_ATTACHMENT_SCANNER_PROVIDER = 'test-only'
$env:UTEN_JWT_ISSUER = 'uten-mobile-review-20261102'
$env:UTEN_DB_POOL_MAX = '8'
$env:UTEN_STORAGE_ROOT = Join-Path $private 'storage'
Write-Output 'Starting isolated local backend: API 127.0.0.1:8281, PostgreSQL 127.0.0.1:5548; no company system.'
& (Join-Path $repo 'server/dev.ps1') -BuildDirectory 'target-dev-mobile-review' -Port 8281
exit $LASTEXITCODE
