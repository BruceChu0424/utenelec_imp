param([Parameter(Mandatory)][ValidatePattern('^[a-z0-9-]+$')][string]$Attempt)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$settings=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'private/runtime.json') -Raw | ConvertFrom-Json
if($settings.jdbcUrl -ne 'jdbc:postgresql://127.0.0.1:26630/feedback' -or $settings.username -ne 'feedback') {
  throw 'This runner only accepts its explicitly prepared isolated feedback database.'
}
$env:TMP=Join-Path $PSScriptRoot "tmp/runtime/$Attempt"; $env:TEMP=$env:TMP
New-Item -ItemType Directory -Force $env:TMP | Out-Null
$env:UTEN_DB_URL=$settings.jdbcUrl; $env:UTEN_DB_USER=$settings.username; $env:UTEN_DB_PASSWORD=$settings.password
$env:SPRING_DATASOURCE_URL=$settings.jdbcUrl; $env:SPRING_DATASOURCE_USERNAME=$settings.username; $env:SPRING_DATASOURCE_PASSWORD=$settings.password
$env:SPRING_FLYWAY_URL=$settings.jdbcUrl; $env:SPRING_FLYWAY_USER=$settings.username; $env:SPRING_FLYWAY_PASSWORD=$settings.password
$env:BOOTSTRAP_ADMIN_LOGIN=$settings.bootstrapLogin; $env:BOOTSTRAP_ADMIN_PASSWORD=$settings.bootstrapPassword
$env:UTEN_PROFILE='dev'; $env:SERVER_PORT=[string]$settings.backendPort
$env:UTEN_CORS_ORIGINS="http://127.0.0.1:$($settings.frontendPort)"
$env:UTEN_JWT_SECRET=$settings.jwtSecret
$env:UTEN_HMAC_KEY=$settings.hmacKey
$env:UTEN_PGP_MASTER_KEY=$settings.pgpMasterKey
if(!$env:UTEN_JWT_SECRET -or !$env:UTEN_HMAC_KEY -or !$env:UTEN_PGP_MASTER_KEY){throw 'Persist the isolated runtime crypto configuration before starting or seeding.'}
$env:UTEN_REPORT_EXPORT_DIRECTORY=Join-Path $PSScriptRoot 'private/exports'
$env:UTEN_STORAGE_LOCAL_DIR=Join-Path $PSScriptRoot 'private/storage'
$env:UTEN_STORAGE_PROVIDER='local'; $env:UTEN_SMS_PROVIDER='disabled'; $env:UTEN_ATTACHMENT_SCANNER_PROVIDER='test-only'
$env:UTEN_REPORT_REFRESH_ENABLED='false'; $env:UTEN_MATERIAL_FORECAST_MANAGE_RUNTIME='false'
$env:LOGGING_FILE_NAME=Join-Path $PSScriptRoot "logs/runtime-$Attempt-spring.log"
$env:MAVEN_OPTS="-Xmx1800m -Djava.io.tmpdir=$env:TMP"
$log=Join-Path $PSScriptRoot "logs/runtime-$Attempt-server.log"
if(Test-Path -LiteralPath $log){throw 'Preserve the previous runtime log; choose a new attempt path.'}
Set-Location (Join-Path $root 'server')
& mvn.cmd -o -B -ntp -Pdev-run "-Duten.build.directory=$PSScriptRoot/runtime-maven-$Attempt" "-Dspring-boot.run.jvmArguments=-Xmx1800m -Djava.io.tmpdir=$env:TMP" spring-boot:run *> $log
exit $LASTEXITCODE
