$ErrorActionPreference='Stop'
$PSNativeCommandUseErrorActionPreference=$false
$taskBase='build/loading-validation/main-3068-output-fixed'
$env:PYTHONIOENCODING='utf-8'
& 'C:/Program Files/LibreOffice/program/python.exe' (Join-Path $taskBase 'prepare-cost-close.py')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$taskSelection=(Get-Content -Raw -LiteralPath (Join-Path $taskBase 'final-extra-selection.txt')).Trim()
& (Join-Path $taskBase 'run-suite.ps1') -Label final-extra -Selection $taskSelection
$taskCostCode=$LASTEXITCODE
if ($taskCostCode -ne 0) { exit $taskCostCode }
& 'C:/Program Files/LibreOffice/program/python.exe' (Join-Path $taskBase 'seal-current.py') *> (Join-Path $taskBase 'final-65-seal.log')
$taskSealCode=$LASTEXITCODE
Get-Content -LiteralPath (Join-Path $taskBase 'final-65-seal.log') -Tail 8
exit $taskSealCode
