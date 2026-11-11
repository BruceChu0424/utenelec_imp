param([Parameter(Mandatory=$true)][string]$Tag)
$ErrorActionPreference = 'Stop'
$taskRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Set-Location -LiteralPath $taskRoot
$testFiles = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'test-list.json') | ConvertFrom-Json
& python -X utf8 (Join-Path $PSScriptRoot 'private_flutter.py') $Tag test --no-pub --reporter=expanded --concurrency=4 @testFiles
if ($LASTEXITCODE -ne 0) { throw "Flutter exit $LASTEXITCODE" }
