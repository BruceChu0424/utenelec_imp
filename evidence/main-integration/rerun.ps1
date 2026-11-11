param([Parameter(Mandatory=$true)][string]$Tag, [switch]$Server)
$ErrorActionPreference = 'Stop'
$taskRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Set-Location -LiteralPath $taskRoot
if ($Server) {
  $taskBuild = Join-Path $PSScriptRoot "server/rerun-$Tag"
  if (Test-Path -LiteralPath $taskBuild) { throw "Preserve existing run: $taskBuild" }
  $taskTmp = Join-Path $taskBuild 'tmp'
  New-Item -ItemType Directory -Path $taskTmp | Out-Null
  $env:TMP = $taskTmp
  $env:TEMP = $taskTmp
  Push-Location -LiteralPath (Join-Path $taskRoot 'server')
  try {
    & mvn "-Duten.build.directory=$taskBuild" "-Duten.test.tmpdir=$taskTmp" '-DforkCount=1' '-Dtest=CompleteStreamStagingTest,CompleteStreamCompressionTomcatTest,MasterSummaryStreamTest,InstantInventoryCompleteStreamServiceTest' test 2>&1 | Tee-Object -FilePath (Join-Path $taskBuild 'maven.log')
    if ($LASTEXITCODE -ne 0) { throw "Maven exit $LASTEXITCODE" }
  } finally { Pop-Location }
} else {
  $testFiles = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'frontend-test-list.json') | ConvertFrom-Json
  & python -X utf8 (Join-Path $PSScriptRoot 'private_flutter.py') $Tag test --concurrency=4 --timeout=90s @testFiles
  if ($LASTEXITCODE -ne 0) { throw "Flutter exit $LASTEXITCODE" }
}
