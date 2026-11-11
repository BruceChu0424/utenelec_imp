$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$private=Join-Path $PSScriptRoot 'private'
New-Item -ItemType Directory -Force $private | Out-Null
$config=Join-Path $private 'runtime.json'
if(Test-Path -LiteralPath $config){throw 'Preserve the existing runtime configuration and container.'}
function New-SyntheticSecret {
  return [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(30))
}
$settings=@{
  container='uten-feedback-final-20261110'; jdbcUrl='jdbc:postgresql://127.0.0.1:26630/feedback';
  username='feedback'; password=(New-SyntheticSecret); syntheticAccountPassword=(New-SyntheticSecret);
  bootstrapLogin='feedback-bootstrap'; bootstrapPassword=(New-SyntheticSecret);
  jwtSecret=(New-SyntheticSecret); hmacKey=(New-SyntheticSecret); pgpMasterKey=(New-SyntheticSecret);
  backendPort=28630; frontendPort=28631
}
$settings | ConvertTo-Json | Set-Content -LiteralPath $config -Encoding utf8NoBOM
$env:POSTGRES_PASSWORD=$settings.password
try {
  & docker run --detach --name $settings.container --publish '127.0.0.1:26630:5432' --env POSTGRES_PASSWORD --env 'POSTGRES_USER=feedback' --env 'POSTGRES_DB=feedback' postgres:16-alpine
  if($LASTEXITCODE){throw 'Unable to start the isolated feedback database; configuration retained.'}
} finally {Remove-Item Env:POSTGRES_PASSWORD -ErrorAction SilentlyContinue}
Write-Output 'Prepared isolated PostgreSQL on 127.0.0.1:26630; credentials retained only in ignored private runtime.json.'
