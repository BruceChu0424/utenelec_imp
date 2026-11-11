param(
  [Parameter(Mandatory=$true)][string]$RuntimeConfig,
  [Parameter(Mandatory=$true)][string]$OutputPath,
  [Parameter(Mandatory=$true)][string]$BuildDirectory,
  [Parameter(Mandatory=$true)][string]$EvidenceDirectory,
  [string]$JdbcUrl='jdbc:postgresql://127.0.0.1:26630/feedback',
  [string]$DatabaseUser='feedback',
  [switch]$LegacyDrafts
)
$ErrorActionPreference='Stop'
$root=(Resolve-Path "$PSScriptRoot/../..").Path
New-Item -ItemType Directory -Force -Path $EvidenceDirectory | Out-Null
$evidence=(Resolve-Path -LiteralPath $EvidenceDirectory).Path
if(Test-Path -LiteralPath "$evidence/seed-web.log"){throw 'Use a new evidence directory; seed logs are immutable.'}
$config=Get-Content -LiteralPath $RuntimeConfig -Raw | ConvertFrom-Json
$env:UTEN_REMEDIATION_B_ALLOW_SEED='true'
$env:UTEN_REMEDIATION_B_JDBC_URL=$JdbcUrl
$env:UTEN_REMEDIATION_B_DB_USER=$DatabaseUser
$env:UTEN_REMEDIATION_B_DB_PASSWORD=$config.password
$env:UTEN_REMEDIATION_B_ACCOUNT_PASSWORD=$config.syntheticAccountPassword
$env:UTEN_REMEDIATION_B_JWT_SECRET=$config.jwtSecret
$env:UTEN_REMEDIATION_B_HMAC_KEY=$config.hmacKey
$env:UTEN_REMEDIATION_B_PGP_MASTER_KEY=$config.pgpMasterKey
$env:UTEN_REMEDIATION_B_SEED_OUTPUT=$OutputPath
$env:UTEN_REMEDIATION_B_INCLUDE_LEGACY_DRAFTS=if($LegacyDrafts){'true'}else{'false'}
$env:UTEN_RUN_DB_TESTS='true'
New-Item -ItemType Directory -Force -Path "$evidence/tmp" | Out-Null
$env:TEMP="$evidence/tmp";$env:TMP=$env:TEMP
$env:MAVEN_OPTS="-Xmx1400m -Djava.io.tmpdir=$env:TEMP"
try {
  mvn -B --offline -f "$root/server/pom.xml" "-Duten.build.directory=$BuildDirectory" "-Duten.test.tmpdir=$env:TEMP" '-Dtest=FeedbackBWebSeedTest#seedOrdinaryWebReturnAndOrderScenarios' surefire:test *> "$evidence/seed-web.log"
  $result=$LASTEXITCODE
  $result | Set-Content "$evidence/seed-web.exit"
} finally {
  Remove-Item Env:UTEN_REMEDIATION_B_DB_PASSWORD,Env:UTEN_REMEDIATION_B_ACCOUNT_PASSWORD,Env:UTEN_REMEDIATION_B_JWT_SECRET,Env:UTEN_REMEDIATION_B_HMAC_KEY,Env:UTEN_REMEDIATION_B_PGP_MASTER_KEY,Env:UTEN_REMEDIATION_B_ALLOW_SEED,Env:UTEN_REMEDIATION_B_INCLUDE_LEGACY_DRAFTS,Env:UTEN_REMEDIATION_B_JDBC_URL,Env:UTEN_REMEDIATION_B_DB_USER,Env:UTEN_REMEDIATION_B_SEED_OUTPUT -ErrorAction SilentlyContinue
}
exit $result
