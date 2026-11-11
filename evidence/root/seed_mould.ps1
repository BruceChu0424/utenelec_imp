param([Parameter(Mandatory)][string]$BSeed)
$ErrorActionPreference='Stop'
$runtime=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'private/runtime.json') -Raw|ConvertFrom-Json
$seed=Get-Content -LiteralPath $BSeed -Raw|ConvertFrom-Json
$maker=[Guid]::Parse($seed.maker.userId).ToString()
$log=Join-Path $PSScriptRoot 'logs/mould-seed.log'
if(Test-Path -LiteralPath $log){throw 'Preserve existing mould fixture evidence; do not seed it twice.'}
Get-Content -LiteralPath (Join-Path $PSScriptRoot 'seed_mould.sql') -Raw |
 & docker exec -i $runtime.container psql -U $runtime.username -d feedback -v ON_ERROR_STOP=1 -v "bootstrap_login=$($runtime.bootstrapLogin)" -v "maker_id=$maker" *> $log
if($LASTEXITCODE){exit $LASTEXITCODE}
@{webLogin='feedback-mould-qa';windowsLogin='feedback-mould-win-qa';passwordSource='private/runtime.json syntheticAccountPassword (not exported)';categoryId='73000000-0000-4000-8000-000000000005';rows=1626;firstAscendingQuantityCode='AU-01626';firstAscendingQuantity='1.125'}|
 ConvertTo-Json|Set-Content -LiteralPath (Join-Path $PSScriptRoot 'mould-web-fixture.json') -Encoding utf8NoBOM
