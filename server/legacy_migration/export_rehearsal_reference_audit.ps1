param(
    [string]$Database = 'YTDQ_rehearsal_20261022',
    [string]$Server = '(localdb)\MSSQLLocalDB',
    [Parameter(Mandatory = $true)][string]$SourceExportManifest,
    [Parameter(Mandatory = $true)][string]$OutDir
)
# Read-only source audit. Export counts and non-personal workshop references.
# Never exports payroll amounts, identity numbers, passwords or phone numbers.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Data
$auditOutput = [System.IO.Path]::GetFullPath($OutDir)
[void][System.IO.Directory]::CreateDirectory($auditOutput)
$auditConnection = New-Object System.Data.SqlClient.SqlConnection("Server=$Server;Database=$Database;Integrated Security=true;TrustServerCertificate=true;")
$auditConnection.Open()
function Read-AuditTable([string]$Sql) {
    $auditCommand = $auditConnection.CreateCommand()
    $auditCommand.CommandText = $Sql
    $auditCommand.CommandTimeout = 300
    $auditAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($auditCommand)
    $auditTable = New-Object System.Data.DataTable
    [void]$auditAdapter.Fill($auditTable)
    return ,$auditTable
}
try {
    $modeCommand = $auditConnection.CreateCommand()
    try {
        $modeCommand.CommandText = "SELECT CONVERT(varchar(30),DATABASEPROPERTYEX(DB_NAME(),'Updateability'))"
        $sourceUpdateability = [string]$modeCommand.ExecuteScalar()
    } finally { $modeCommand.Dispose() }
    if ($sourceUpdateability -ne 'READ_ONLY') { throw 'Reference audit requires the actual offline source to be READ_ONLY' }
    $sourceExport = Get-Content -Raw -LiteralPath $SourceExportManifest | ConvertFrom-Json
    if ($sourceExport.formatVersion -ne 4 -or $sourceExport.target -ne 'All') { throw 'Reference audit requires the complete source export manifest' }
    $sourceManifestSha = (Get-FileHash -LiteralPath $SourceExportManifest -Algorithm SHA256).Hash.ToLowerInvariant()
    $sourceTables = Read-AuditTable 'SELECT s.name AS schema_name,t.name AS table_name FROM sys.tables t JOIN sys.schemas s ON s.schema_id=t.schema_id WHERE t.is_ms_shipped=0 ORDER BY s.name,t.name'
    $exporterText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'export_legacy.ps1') -Raw
    $exportedNames = @{}
    foreach ($match in [regex]::Matches($exporterText, '(?i)\b(?:FROM|JOIN)\s+(?:dbo\.)?\[?(?<name>[A-Za-z_][A-Za-z0-9_$]*)\]?')) {
        $exportedNames[$match.Groups['name'].Value] = $true
    }
    $discardPermissions = @('Sys_Group','Sys_Operator','Sys_OperatorPurview','Sys_Purview','SystemPart','Sys_BasicView')
    $derived = @('ProductMore','StockLabel','StockSLabel','P_OrderMore')
    $historicalConfig = @('W_Formula','W_Project','W_PATWork','W_Laborage','Sys_Logs','SystemAccinfo','SystemSource','SetColumnsWidth','PrintFile','B_Education','B_NPlace','B_Sex','B_YesOrNo','B_AssTeam','B_AStyle','B_BillStyle','B_BStyle','B_GStyle','B_PFormula','B_Step','B_StoragePlace','dbom','hhhhhh$','MK_StockGoods','SystemItem_bak20230607','temp_20250103','ys2017')
    $reviewedReasons = @{
        'Sys_BasicView'='旧主体逐资料可见性配置（OperatorID/TableID/ItemID/VStatus），不迁为新数据权限'
        'B_StoragePlace'='旧位置字典；独立来源CSV保留与库存历史引用，126/127等不能未经现场核验变当前货架'
        'dbom'='临时货品代码对照，qty为非数字代码；不视为BOM用量'
        'hhhhhh$'='Excel式客户应收余额旧快照，缺可靠期间；不与当前AR叠加'
        'ys2017'='Excel式客户应收余额历史快照，缺可靠期间；不与当前AR叠加'
        'MK_StockGoods'='另套库存账，仅2012年一条零库存；当前库存以StockGoods为准，不叠加'
        'SystemItem_bak20230607'='2023字典备份，当前字典用SystemItem；旧备份不覆盖当前关系'
        'temp_20250103'='2025货品包装标识备注旧快照；完整独立CSV保留，与当前Paper不同时不覆盖当前值'
    }
    $counts = @()
    foreach ($source in $sourceTables.Rows) {
        $quotedSchema = '[' + $source.schema_name.Replace(']', ']]') + ']'
        $quotedTable = '[' + $source.table_name.Replace(']', ']]') + ']'
        $countCommand = $auditConnection.CreateCommand()
        $countCommand.CommandTimeout = 300
        $countCommand.CommandText = "SELECT COUNT_BIG(*) FROM $quotedSchema.$quotedTable"
        $actualRows = [long]$countCommand.ExecuteScalar()
        $name = [string]$source.table_name
        $disposition = '未知待核验'
        $reason = '完整备份保留；未获证据确认当前业务落点，不擅自导入'
        if ($actualRows -eq 0) {
            $disposition = '来源为空'
            $reason = 'COUNT_BIG精确计数为零，不生成业务数据'
        } elseif ($discardPermissions -contains $name) {
            $disposition = '旧账号权限丢弃'
            $reason = '不迁登录、密码或有效授权；Sys_Operator仅按已审导出保留单据制单审核姓名快照'
        } elseif ($derived -contains $name) {
            $disposition = '派生缓存归档'
            $reason = '原始备份保留；根据已迁销售、采购、生产业务重算，不叠加库存'
        } elseif ($historicalConfig -contains $name) {
            $disposition = '历史配置归档'
            $reason = '完整备份保留；配置只作映射参考，历史工资不写当期工资'
        } elseif ($name -eq 'B_WorkShop') {
            $disposition = '导入及来源对照'
            $reason = '4车间映射既有部门，10注塑机台停用导入，20安装线独立来源对照'
        } elseif ($exportedNames.ContainsKey($name)) {
            $disposition = '导入'
            $reason = '现有受审导出SQL已引用；按对应模块字段映射、清洗及事务对账导入'
        }
        if ($actualRows -gt 0 -and $reviewedReasons.ContainsKey($name)) { $reason=$reviewedReasons[$name] }
        $counts += [pscustomobject]@{schema_name=$source.schema_name;table_name=$name;actual_rows=$actualRows;disposition=$disposition;reason=$reason}
    }
    $counts | Export-Csv -LiteralPath (Join-Path $auditOutput 'source_table_disposition_exact.csv') -NoTypeInformation -Encoding utf8
    $workshops = Read-AuditTable 'SELECT ID AS legacy_id,WorkShop AS source_name FROM B_WorkShop ORDER BY ID'
    $workshops | Select-Object legacy_id,source_name | Export-Csv -LiteralPath (Join-Path $auditOutput 'legacy_workshops_source.csv') -NoTypeInformation -Encoding utf8
    $machineRows = @()
    $lineRows = @()
    foreach ($workshop in $workshops.Rows) {
        if ([string]$workshop.source_name -match '^注塑(?<number>\d+)号机$') {
            $machineRows += [pscustomobject]@{legacy_id=$workshop.legacy_id;source_name=$workshop.source_name;dept_code='WS_ZHUSU';new_code=[string][int]$Matches.number;new_name=$workshop.source_name;enabled='false'}
        } elseif ([string]$workshop.source_name -match '^安装(?<number>\d+)线$') {
            $lineRows += [pscustomobject]@{legacy_id=$workshop.legacy_id;source_name=$workshop.source_name;dept_code='WS_ZHUANG';line_number=[int]$Matches.number;disposition='历史产线对照，当前无独立产线主档'}
        }
    }
    $machineRows | Sort-Object {[int]$_.new_code} | Export-Csv -LiteralPath (Join-Path $auditOutput 'legacy_injection_machines.csv') -Delimiter '|' -NoTypeInformation -Encoding utf8
    $lineRows | Sort-Object line_number | Export-Csv -LiteralPath (Join-Path $auditOutput 'legacy_assembly_lines.csv') -NoTypeInformation -Encoding utf8
    $placeRows = Read-AuditTable 'SELECT ID AS legacy_id,Storage_Name AS source_name,Number AS source_code,ParentID AS parent_legacy_id,Status AS source_status FROM B_StoragePlace ORDER BY ID'
    $placeRows | Select-Object legacy_id,source_name,source_code,parent_legacy_id,source_status | Export-Csv -LiteralPath (Join-Path $auditOutput 'legacy_storage_places.csv') -NoTypeInformation -Encoding utf8
    $remarkRows = Read-AuditTable "SELECT t.[编号] AS goods_code,t.[备注] AS historical_remark,g.ID AS goods_legacy_id,CASE WHEN g.ID IS NULL THEN 'unmatched_old_code' WHEN LTRIM(RTRIM(ISNULL(g.Paper,'')))=LTRIM(RTRIM(ISNULL(t.[备注],''))) THEN 'same_as_current_paper' ELSE 'historical_conflict_keep_current' END AS resolution FROM temp_20250103 t LEFT JOIN B_Goods g ON g.ANumber=t.[编号] ORDER BY t.[编号]"
    $remarkRows | Select-Object goods_code,historical_remark,goods_legacy_id,resolution | Export-Csv -LiteralPath (Join-Path $auditOutput 'legacy_goods_remark_history.csv') -NoTypeInformation -Encoding utf8
    $summary = [pscustomobject]@{database=$Database;database_updateability=$sourceUpdateability;source_export_manifest_sha256=$sourceManifestSha;source_backup_sha256=$sourceExport.sourceBackupSha256;source_snapshot_as_of_utc=$sourceExport.sourceSnapshotAsOfUtc;count_method='COUNT_BIG(*) per user table';table_count=$counts.Count;nonempty_table_count=@($counts | Where-Object actual_rows -gt 0).Count;total_rows=($counts | Measure-Object actual_rows -Sum).Sum;machines=$machineRows.Count;assembly_lines=$lineRows.Count;generated_utc=[DateTime]::UtcNow.ToString('o')}
    $summary | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $auditOutput 'source_table_audit_summary.json') -Encoding utf8
    $summary | ConvertTo-Json
} finally {
    $auditConnection.Close()
}
