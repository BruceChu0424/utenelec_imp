param([string]$CandidateBuild=(Join-Path $PSScriptRoot 'maven/build'),[string]$RunName='final-7b912287')
$ErrorActionPreference='Stop'
$base=$PSScriptRoot
$env:C_FINAL_BUILD=$CandidateBuild
foreach($phase in @('originals','v2','v1','files')) {
  $stage="$RunName-$phase"
  & python -X utf8 "$base/source-proof.py" start $stage
  if($LASTEXITCODE){throw 'Frozen-source proof failed before execution'}
  if($phase -eq 'originals') {
    & pwsh -File "$base/run-originals.ps1" -CandidateBuild $CandidateBuild -RunName $stage
  } elseif($phase -eq 'v2') {
    & pwsh -File "$base/run-upgrade.ps1" -Phase verify -CandidateBuild $CandidateBuild -RunName $stage
  } else {
    $operation=if($phase -eq 'files'){'files'}else{'verify'}
    & pwsh -File "$base/run-v1-verify.ps1" -Phase $operation -CandidateBuild $CandidateBuild -RunName $stage
  }
  $code=$LASTEXITCODE
  & python -X utf8 "$base/source-proof.py" end $stage $code
  if($LASTEXITCODE){throw 'Frozen-source proof failed after execution'}
  if($code){throw "$phase failed with $code; original log retained"}
}
