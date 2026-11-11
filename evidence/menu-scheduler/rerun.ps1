param(
  [Parameter(Mandatory=$true)][string]$Tag,
  [ValidateSet('vm','chrome')][string]$Platform = 'vm',
  [ValidateSet('mount','beforeMenu')][string]$Timing = 'mount',
  [ValidateSet('true','false')][string]$Hover = 'false',
  [ValidateSet('true','false')][string]$Semantics = 'true'
)
$ErrorActionPreference = 'Stop'
$taskRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Set-Location -LiteralPath $taskRoot
$probe = Join-Path $PSScriptRoot 'probe-real-semantics.dart.txt'
$target = Join-Path $taskRoot 'test/features/basic_data/pages/master_menu_scheduler_probe_test.dart'
if (Test-Path -LiteralPath $target) {
  if ((Get-FileHash -LiteralPath $target).Hash -ne (Get-FileHash -LiteralPath $probe).Hash) { throw 'Preserve existing diagnostic test; use an isolated worktree.' }
} else { Copy-Item -LiteralPath $probe -Destination $target }
if (-not (Test-Path -LiteralPath '.dart_tool/package_config.json')) {
  & python -X utf8 (Join-Path $PSScriptRoot 'private_flutter.py') "$Tag-deps" pub get --offline --enforce-lockfile
  if ($LASTEXITCODE -ne 0) { throw "Dependencies exit $LASTEXITCODE" }
}
$testArgs = @('test','--no-pub','--reporter=expanded','--timeout=90s',"--name=hover=$Hover semantics=$Semantics timing=$Timing",'test/features/basic_data/pages/master_menu_scheduler_probe_test.dart')
if ($Platform -eq 'chrome') { $testArgs += @('--platform','chrome') }
& python -X utf8 (Join-Path $PSScriptRoot 'private_flutter.py') $Tag @testArgs
if ($LASTEXITCODE -ne 0) { throw "Probe exit $LASTEXITCODE (inspect the first phase/stack; never overwrite the run)." }
