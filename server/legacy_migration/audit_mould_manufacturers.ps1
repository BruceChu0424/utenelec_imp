param(
    [string]$LegacyServer = '(localdb)\MSSQLLocalDB',
    [string]$LegacyDatabase = 'YTDQ_2023',
    [string]$CompanySshHost = 'uten-imp-server',
    [string]$CompanyDatabase = 'uten_imp',
    [string]$OutputDirectory = 'output/mould-manufacturer-audit'
)
$ErrorActionPreference = 'Stop'
if ($CompanyDatabase -notmatch '^[a-zA-Z0-9_]+$' -or $CompanySshHost -notmatch '^[a-zA-Z0-9_.-]+$') {
    throw 'Invalid company connection identifier'
}
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
Add-Type -AssemblyName System.Data
$builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
$builder['Data Source'] = $LegacyServer
$builder['Initial Catalog'] = $LegacyDatabase
$builder['Integrated Security'] = $true
$builder['ApplicationIntent'] = 'ReadOnly'
$connection = New-Object System.Data.SqlClient.SqlConnection $builder.ConnectionString
$connection.Open()
try {
    function Read-LegacyRows([string]$sql) {
        $command = $connection.CreateCommand()
        $command.CommandText = $sql
        $reader = $command.ExecuteReader()
        try {
            while ($reader.Read()) {
                $row = [ordered]@{}
                for ($i = 0; $i -lt $reader.FieldCount; $i++) {
                    $row[$reader.GetName($i)] = if ($reader.IsDBNull($i)) { $null } else { $reader.GetValue($i) }
                }
                [pscustomobject]$row
            }
        } finally { $reader.Close(); $command.Dispose() }
    }
    $source = @(Read-LegacyRows 'SELECT ID legacy_id,Number code,MouldName name,summary FROM dbo.B_Mould ORDER BY ID')
    $suppliers = @(Read-LegacyRows 'SELECT ID legacy_id,Vend_Name name,Vend_Desc alias FROM dbo.B_Provider ORDER BY ID')
    $columns = @(Read-LegacyRows "SELECT c.name FROM sys.columns c WHERE c.object_id=OBJECT_ID('dbo.B_Mould') ORDER BY c.column_id")
} finally { $connection.Close(); $connection.Dispose() }

$sql = @'
BEGIN READ ONLY;
SELECT json_build_object(
  'database',current_database(), 'queriedAt',current_timestamp,
  'moulds',(SELECT json_agg(row_to_json(m)) FROM
    (SELECT id,legacy_id,code,name,manufacturer,keeper,keeper_id FROM moulds WHERE NOT is_deleted ORDER BY legacy_id,id) m),
  'supplierCount',(SELECT count(*) FROM suppliers WHERE NOT is_deleted),
  'latestMigration',(SELECT version FROM flyway_schema_history WHERE success AND version IS NOT NULL ORDER BY string_to_array(version, '.')::numeric[] DESC LIMIT 1));
ROLLBACK;
'@
$raw = $sql | & ssh -o BatchMode=yes -o ConnectTimeout=12 $CompanySshHost "sudo -n -u postgres psql -X -qAt -v ON_ERROR_STOP=1 -d $CompanyDatabase"
if ($LASTEXITCODE -ne 0) { throw 'Company read-only query failed' }
$company = ($raw -join "`n") | ConvertFrom-Json
$live = @{}
foreach ($m in $company.moulds) { if ($null -ne $m.legacy_id) { $live[[int]$m.legacy_id] = $m } }
$matches = @(); $missing = @(); $drift = @(); $candidates = @()
foreach ($m in $source) {
    $current = $live[[int]$m.legacy_id]
    if ($null -eq $current) { $missing += $m.legacy_id; continue }
    if ([string]$current.keeper -ceq [string]$m.summary) { $matches += $m.legacy_id }
    else { $drift += $m.legacy_id }
    if (-not [string]::IsNullOrWhiteSpace($m.summary) -and
        [string]::IsNullOrWhiteSpace($current.manufacturer)) {
        $candidates += [pscustomobject]@{
            legacyId = $m.legacy_id; id = $current.id; code = $current.code
            originalSummary = $m.summary; currentKeeper = $current.keeper
            keeperId = $current.keeper_id
            exactSourceText = ([string]$current.keeper -ceq [string]$m.summary)
            # No automatic classification or supplier UUID matching.
            reviewRequired = $true
        }
    }
}
$report = [ordered]@{
    readOnly = $true; oldDatabase = $LegacyDatabase
    oldSource = 'restored local backup, not the running legacy server'
    oldMouldCount = $source.Count; oldSupplierCount = $suppliers.Count
    oldColumns = @($columns | ForEach-Object { $_.name })
    oldSummaryNonempty = @($source | Where-Object { -not [string]::IsNullOrWhiteSpace($_.summary) }).Count
    companyDatabase = $company.database; companyQueriedAt = $company.queriedAt
    companyMouldCount = @($company.moulds).Count
    companyManufacturerCount = @($company.moulds | Where-Object { -not [string]::IsNullOrWhiteSpace($_.manufacturer) }).Count
    companySupplierCount = $company.supplierCount; companyLatestMigration = $company.latestMigration
    matchingOriginalSummaryCount = $matches.Count; missingSourceIds = $missing; changedSourceTextIds = $drift
    candidateCount = $candidates.Count
    summaryGroups = @($source | Group-Object summary | Sort-Object Count -Descending | ForEach-Object {
        $value = $_.Name
        [pscustomobject]@{
            originalSummary = $value; count = $_.Count
            supplierNameCandidates = @($suppliers | Where-Object {
                -not [string]::IsNullOrWhiteSpace($value) -and
                (([string]$_.name).Contains($value) -or ([string]$_.alias).Contains($value))
            } | ForEach-Object { $_.name } | Select-Object -Unique)
        }
    })
    candidates = $candidates
}
$report | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8 (Join-Path $OutputDirectory 'audit.json')
$report.GetEnumerator() | Where-Object { $_.Key -notin @('candidates','summaryGroups','oldColumns') } |
    ForEach-Object { '{0}: {1}' -f $_.Key,($_.Value | ConvertTo-Json -Compress) }
