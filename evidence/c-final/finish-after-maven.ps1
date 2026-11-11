$ErrorActionPreference='Stop'
$base=$PSScriptRoot
$exitFile=Join-Path $base 'maven/exit.txt'
while(!(Test-Path -LiteralPath $exitFile)) { Start-Sleep -Seconds 2 }
$code=[int](Get-Content -LiteralPath $exitFile -Raw).Trim()
& python -X utf8 "$base/source-proof.py" end maven-23-classes $code
if($LASTEXITCODE){throw 'Maven source objects changed'}
if($code){throw "Maven failed with $code; preserve all reports"}
& pwsh -File "$base/run-finish.ps1" -CandidateBuild (Join-Path $base 'maven/build')
exit $LASTEXITCODE
