#requires -Version 7.4
param(
    [Parameter(Mandatory=$true)][string]$Database,
    [Parameter(Mandatory=$true)][string]$OutputDir,
    [Parameter(Mandatory=$true)][string]$SourceExportManifest,
    [Parameter(Mandatory=$true)][ValidateRange(1,2147483647)][int]$BackupSetPosition
)

# Read-only supplement to All export; never restores, changes or imports data.
# The caller must use a new directory beneath the private run directory.
$ErrorActionPreference = 'Stop'
if ($Database -notmatch '^YTDQ_(?:rehearsal|completeness_audit)_[0-9]{8}(?:_[A-Za-z0-9]+)*$') {
    throw 'Only an explicitly named isolated local source is permitted'
}
if (Test-Path -LiteralPath $OutputDir) { throw 'Use a fresh private completeness audit directory' }
$rawText = Get-Content -Raw -LiteralPath $SourceExportManifest
$raw = $rawText | ConvertFrom-Json
if ($raw.formatVersion -ne 4 -or $raw.target -ne 'All' -or $raw.sourceBackupSha256 -notmatch '^[0-9a-f]{64}$') {
    throw 'A complete format-4 source manifest with its backup SHA is required'
}
$jsonDocument = [System.Text.Json.JsonDocument]::Parse([string]$rawText,[System.Text.Json.JsonDocumentOptions]::new())
try { $cutoffText=$jsonDocument.RootElement.GetProperty('sourceSnapshotAsOfUtc').GetString() }
finally { $jsonDocument.Dispose() }
if ($cutoffText -notmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$') {
    throw 'The reviewed source snapshot must have an explicit UTC cutoff'
}
$cutoff = [DateTimeOffset]::Parse($cutoffText)
if ($cutoff.Offset -ne [TimeSpan]::Zero) { throw 'The source cutoff must be UTC' }
$rawSha = (Get-FileHash -LiteralPath $SourceExportManifest -Algorithm SHA256).Hash.ToLowerInvariant()
$generatorSha = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
Add-Type -AssemblyName System.Data
function Read-SourceTable([System.Data.SqlClient.SqlConnection]$Connection,
                          [string]$Sql,[System.Data.SqlClient.SqlTransaction]$Transaction=$null) {
    $command=$Connection.CreateCommand(); $command.CommandText=$Sql; $command.CommandTimeout=600
    if ($null -ne $Transaction) { $command.Transaction=$Transaction }
    $adapter=$null
    try {
        $adapter=[System.Data.SqlClient.SqlDataAdapter]::new($command)
        $table=[System.Data.DataTable]::new()
        [void]$adapter.Fill($table)
        return ,$table
    } finally {
        if ($null -ne $adapter) { $adapter.Dispose() }
        $command.Dispose()
    }
}
$connection=[System.Data.SqlClient.SqlConnection]::new("Server=(localdb)\MSSQLLocalDB;Database=$Database;Integrated Security=true;TrustServerCertificate=true;")
$connection.Open()
try {
    $mode=Read-SourceTable $connection "SELECT CONVERT(varchar(30),DATABASEPROPERTYEX(DB_NAME(),'Updateability')) AS mode"
    if ([string]$mode.Rows[0].mode -ne 'READ_ONLY') { throw 'The actual isolated source must be physically READ_ONLY' }
    $transaction=$connection.BeginTransaction([System.Data.IsolationLevel]::Serializable)
    try {
        [void](New-Item -ItemType Directory -Path $OutputDir)
        $queries=[ordered]@{
            'source_columns.csv'='SELECT s.name AS schema_name,t.name AS table_name,c.column_id,c.name AS column_name,ty.name AS data_type,c.max_length,c.precision,c.scale,c.is_nullable,c.is_identity,c.is_computed FROM sys.tables t JOIN sys.schemas s ON s.schema_id=t.schema_id JOIN sys.columns c ON c.object_id=t.object_id JOIN sys.types ty ON ty.user_type_id=c.user_type_id WHERE t.is_ms_shipped=0 ORDER BY s.name,t.name,c.column_id'
            'system_item_full.csv'='SELECT * FROM dbo.SystemItem ORDER BY ItemclassID,ItemID'
            'system_item_class_counts.csv'='SELECT ItemclassID AS item_class_id,COUNT_BIG(*) AS actual_rows FROM dbo.SystemItem GROUP BY ItemclassID ORDER BY ItemclassID'
            'system_part_full.csv'='SELECT * FROM dbo.SystemPart ORDER BY ID'
            'mk_stock_goods_full.csv'='SELECT * FROM dbo.MK_StockGoods ORDER BY StockID,GoodsID,ColorID,Year'
        }
        $records=@()
        foreach ($name in $queries.Keys) {
            $path=Join-Path $OutputDir $name
            $table=Read-SourceTable $connection $queries[$name] $transaction
            $table | Export-Csv -LiteralPath $path -Delimiter '|' -NoTypeInformation -Encoding utf8
            $records+=@{file=$name;rows=$table.Rows.Count;bytes=(Get-Item -LiteralPath $path).Length;sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}
        }
        if ((Get-FileHash -LiteralPath $SourceExportManifest -Algorithm SHA256).Hash.ToLowerInvariant() -ne $rawSha -or
            (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $generatorSha) {
            throw 'The source manifest or audit generator changed during capture'
        }
        $transaction.Commit()
    } catch {
        $transaction.Rollback()
        throw
    } finally { $transaction.Dispose() }
    $manifest=@{format='source-completeness-audit-v1';database=$Database;updateability='READ_ONLY';isolation='Serializable';
        source_backup_sha256=$raw.sourceBackupSha256;backup_file=$BackupSetPosition;raw_export_manifest_sha256=$rawSha;
        source_snapshot_as_of_utc=$cutoffText;generator_sha256=$generatorSha;
        files=$records;generated_utc=[DateTime]::UtcNow.ToString('o')}
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDir 'audit-manifest.json') -Encoding utf8
    Write-Output ('SOURCE_COMPLETENESS_AUDIT_SUCCESS files='+$records.Count)
} finally { $connection.Dispose() }
