# Preserve original legacy goods image bytes. SELECT only; never changes either database.
param(
    [Parameter(Mandatory = $true)] [string]$OutputDir,
    [Parameter(Mandatory = $true)] [string]$SourceExportManifest,
    [ValidatePattern('^[A-Za-z0-9_]+$')] [string]$Database = 'YTDQ_rehearsal_20261022'
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Data
$columns = @('GroundGraph','ProductGraph1','ProductGraph2','ProductGraph3','ProductGraph4','ProductGraph5','ProductGraph6','BudgetGraph')
$manifestPath = (Resolve-Path -LiteralPath $SourceExportManifest).Path
$sourceManifest = [System.IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
if ($sourceManifest.target -ne 'All' -or $sourceManifest.sourceBackupSha256 -notmatch '^[0-9a-f]{64}$') {
    throw 'A reviewed All export manifest with the original backup digest is required'
}
[System.IO.Directory]::CreateDirectory([System.IO.Path]::GetFullPath($OutputDir)) | Out-Null
$output = [System.IO.Path]::GetFullPath($OutputDir)
$connection = New-Object System.Data.SqlClient.SqlConnection(
    ('Server=(localdb)\MSSQLLocalDB;Database=' + $Database + ';Integrated Security=true;TrustServerCertificate=true;'))
$connection.Open()
$transaction = $connection.BeginTransaction([System.Data.IsolationLevel]::Serializable)
try {
    $command = $connection.CreateCommand()
    $command.Transaction = $transaction
    $command.CommandTimeout = 120
    $command.CommandText = "SELECT CAST(DATABASEPROPERTYEX(DB_NAME(),'Updateability') AS nvarchar(20))"
    # The final rehearsal input must be a physically sealed offline snapshot.
    # This script only observes the flag; it never changes database state.
    $updateability = $command.ExecuteScalar().ToString()
    if ($updateability -ne 'READ_ONLY') { throw 'Final legacy media extraction requires a physically read-only offline database' }
    $aggregate = @('COUNT_BIG(*) AS goods_rows')
    foreach ($column in $columns) {
        $aggregate += ('COUNT_BIG(CASE WHEN DATALENGTH([' + $column + '])>0 THEN 1 END) AS [' + $column + ']')
    }
    $command.CommandText = 'SELECT ' + ($aggregate -join ',') + ' FROM B_Goods'
    $reader = $command.ExecuteReader()
    try {
        if (-not $reader.Read()) { throw 'Missing goods media inventory' }
        $inventory = [ordered]@{goods_rows = $reader.GetInt64(0)}
        for ($index=0; $index -lt $columns.Count; $index++) { $inventory[$columns[$index]]=$reader.GetInt64($index+1) }
    } finally { $reader.Dispose() }
    $expectedGoods = @($sourceManifest.files | Where-Object file -eq 'goods.csv')
    if ($expectedGoods.Count -ne 1 -or $expectedGoods[0].rows -ne $inventory.goods_rows) {
        throw 'Legacy media inventory differs from the reviewed goods export'
    }
    $projection = ($columns | ForEach-Object { '[' + $_ + ']' }) -join ','
    $predicate = ($columns | ForEach-Object { 'DATALENGTH([' + $_ + '])>0' }) -join ' OR '
    $command.CommandText = 'SELECT ID,ANumber,Goods_Name,' + $projection + ' FROM B_Goods WHERE ' + $predicate + ' ORDER BY ID'
    $reader = $command.ExecuteReader()
    $files = @()
    try {
        while ($reader.Read()) {
            $identity = $reader.GetInt32(0)
            $code = $reader.GetValue(1).ToString().Trim()
            $name = $reader.GetValue(2).ToString().Trim()
            for ($index=0; $index -lt $columns.Count; $index++) {
                if ($reader.IsDBNull($index+3)) { continue }
                [byte[]]$bytes = $reader.GetValue($index+3)
                if ($bytes.Length -eq 0) { continue }
                $algorithm = [System.Security.Cryptography.SHA256]::Create()
                try { $sha=([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-','').ToLowerInvariant() }
                finally { $algorithm.Dispose() }
                $jpeg = $bytes.Length -ge 3 -and $bytes[0] -eq 255 -and $bytes[1] -eq 216 -and $bytes[2] -eq 255
                $extension = if ($jpeg) { '.jpg' } else { '.bin' }
                $safeCode = [regex]::Replace($code,'[^A-Za-z0-9._-]','_')
                $filename = $identity.ToString() + '__' + $safeCode + '__' + $columns[$index] + '__' + $sha + $extension
                $path = Join-Path $output $filename
                if (Test-Path -LiteralPath $path) {
                    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant() -ne $sha) { throw 'Existing media output differs; use a new run directory' }
                } else { [System.IO.File]::WriteAllBytes($path,$bytes) }
                $files += [pscustomobject][ordered]@{file=$filename; legacy_goods_id=$identity; goods_code=$code;
                    goods_name=$name; source_table='B_Goods'; source_column=$columns[$index]; bytes=$bytes.Length;
                    sha256=$sha; content_type=$(if ($jpeg) {'image/jpeg'} else {'application/octet-stream'})}
            }
        }
    } finally { $reader.Dispose(); $command.Dispose() }
    $manifest = [ordered]@{format='uten-legacy-goods-original-media-v1'; database=$Database;
        read_only_queries=$true; database_updateability=$updateability;
        source_export_manifest_sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $manifestPath).Hash.ToLowerInvariant();
        source_backup_sha256=$sourceManifest.sourceBackupSha256; source_snapshot_as_of_utc=$sourceManifest.sourceSnapshotAsOfUtc;
        exporter_sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $PSCommandPath).Hash.ToLowerInvariant();
        inventory=$inventory; files=@($files)}
    $receipt = Join-Path $output 'legacy_goods_media_manifest.json'
    $json = $manifest | ConvertTo-Json -Depth 10
    if ((Test-Path -LiteralPath $receipt) -and [System.IO.File]::ReadAllText($receipt) -ne $json) {
        $oldSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $receipt).Hash.ToLowerInvariant()
        $archive = Join-Path $output ('legacy_goods_media_receipt_' + $oldSha + '.json')
        if (-not (Test-Path -LiteralPath $archive)) { [System.IO.File]::Copy($receipt, $archive, $false) }
    }
    [System.IO.File]::WriteAllText($receipt, $json, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host ('Preserved ' + $files.Count + ' original media objects; no database writes')
} finally { $transaction.Rollback(); $connection.Dispose() }
