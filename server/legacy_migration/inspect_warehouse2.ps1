# =====================================================================
# Legacy DB (YTDQ_2023) warehouse-mgmt deep dive (ASCII only!)
# Confirm O_* table -> Chinese doc mapping via BillNo samples + columns,
# and inspect StockGoods ledger (the backbone all docs write to).
# =====================================================================
param()
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Data
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$outDir = Join-Path $here 'data'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
$cs = 'Server=(localdb)\MSSQLLocalDB;Database=YTDQ_2023;Integrated Security=true;TrustServerCertificate=true;'

function Dump([string]$Sql, [string]$File) {
    $conn = New-Object System.Data.SqlClient.SqlConnection($cs)
    $conn.Open()
    try {
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $Sql
        $cmd.CommandTimeout = 300
        $r = $cmd.ExecuteReader()
        $enc = New-Object System.Text.UTF8Encoding($false)
        $path = Join-Path $outDir $File
        $fs = [System.IO.File]::Create($path)
        $w = New-Object System.IO.StreamWriter($fs, $enc)
        try {
            $headers = for ($i = 0; $i -lt $r.FieldCount; $i++) { $r.GetName($i) }
            $w.WriteLine(($headers -join '|'))
            while ($r.Read()) {
                $vals = for ($i = 0; $i -lt $r.FieldCount; $i++) {
                    if ($r.IsDBNull($i)) { '' } else { $r.GetValue($i).ToString() }
                }
                $line = ($vals -join '|')
                if ($line.Length -gt 4000) { $line = $line.Substring(0,4000) }
                $w.WriteLine($line)
            }
        } finally { $w.Close(); $fs.Close(); $r.Close() }
    } finally { $conn.Close() }
    Write-Host ('OK  ' + $File + '  (' + (Get-Item $path).Length + ' bytes)')
}

# 1. Columns of every O_* table (warehouse-mgmt doc set)
Dump "SELECT c.TABLE_NAME, c.ORDINAL_POSITION, c.COLUMN_NAME, c.DATA_TYPE, c.CHARACTER_MAXIMUM_LENGTH AS char_len, c.NUMERIC_PRECISION AS num_prec, c.NUMERIC_SCALE AS num_scale, c.IS_NULLABLE FROM INFORMATION_SCHEMA.COLUMNS c WHERE c.TABLE_NAME LIKE 'O[_]%' ORDER BY c.TABLE_NAME, c.ORDINAL_POSITION" 'warehouse_o_columns.txt'

# 2. BillNo samples per O_ main table (prefix reveals Chinese doc type) + suspects M_/E_
Dump "SELECT 'O_Transfer' AS src, BillNo FROM (SELECT TOP 3 BillNo FROM O_Transfer WHERE BillNo IS NOT NULL ORDER BY ID) a UNION ALL SELECT 'O_In', BillNo FROM (SELECT TOP 3 BillNo FROM O_In WHERE BillNo IS NOT NULL ORDER BY ID) b UNION ALL SELECT 'O_Out', BillNo FROM (SELECT TOP 3 BillNo FROM O_Out WHERE BillNo IS NOT NULL ORDER BY ID) c UNION ALL SELECT 'O_OtherIn', BillNo FROM (SELECT TOP 3 BillNo FROM O_OtherIn WHERE BillNo IS NOT NULL ORDER BY ID) d UNION ALL SELECT 'O_OtherOut', BillNo FROM (SELECT TOP 3 BillNo FROM O_OtherOut WHERE BillNo IS NOT NULL ORDER BY ID) e UNION ALL SELECT 'O_PDraw', BillNo FROM (SELECT TOP 3 BillNo FROM O_PDraw WHERE BillNo IS NOT NULL ORDER BY ID) f UNION ALL SELECT 'O_WDraw', BillNo FROM (SELECT TOP 3 BillNo FROM O_WDraw WHERE BillNo IS NOT NULL ORDER BY ID) g UNION ALL SELECT 'O_Check', BillNo FROM (SELECT TOP 3 BillNo FROM O_Check WHERE BillNo IS NOT NULL ORDER BY ID) h UNION ALL SELECT 'M_In', BillNo FROM (SELECT TOP 3 BillNo FROM M_In WHERE BillNo IS NOT NULL ORDER BY ID) i UNION ALL SELECT 'M_Out', BillNo FROM (SELECT TOP 3 BillNo FROM M_Out WHERE BillNo IS NOT NULL ORDER BY ID) j UNION ALL SELECT 'E_In', BillNo FROM (SELECT TOP 3 BillNo FROM E_In WHERE BillNo IS NOT NULL ORDER BY ID) k UNION ALL SELECT 'E_SOut', BillNo FROM (SELECT TOP 3 BillNo FROM E_SOut WHERE BillNo IS NOT NULL ORDER BY ID) l" 'warehouse_billno_samples.txt'

# 3. Doc-style dictionaries (BillNo prefix -> Chinese name)
Dump "SELECT 'B_BillStyle' AS src, * FROM B_BillStyle UNION ALL SELECT 'B_BStyle', CAST(0 AS INT) AS dummy1, CAST(0 AS INT) AS dummy2 FROM B_BStyle" 'warehouse_dict_billstyle.txt'

# 4. StockGoods ledger columns (the unified stock backbone, 454104 rows)
Dump "SELECT c.ORDINAL_POSITION, c.COLUMN_NAME, c.DATA_TYPE, c.CHARACTER_MAXIMUM_LENGTH AS char_len, c.NUMERIC_PRECISION AS num_prec, c.NUMERIC_SCALE AS num_scale, c.IS_NULLABLE FROM INFORMATION_SCHEMA.COLUMNS c WHERE c.TABLE_NAME = 'StockGoods' ORDER BY c.ORDINAL_POSITION" 'warehouse_stockgoods_columns.txt'

# 5. O_ main tables Status distribution (state machine: how many 草稿/已审/红冲)
Dump "SELECT 'O_Transfer' AS src, Status, COUNT(*) AS cnt FROM O_Transfer GROUP BY Status UNION ALL SELECT 'O_In', Status, COUNT(*) FROM O_In GROUP BY Status UNION ALL SELECT 'O_OtherIn', Status, COUNT(*) FROM O_OtherIn GROUP BY Status UNION ALL SELECT 'O_OtherOut', Status, COUNT(*) FROM O_OtherOut GROUP BY Status UNION ALL SELECT 'O_PDraw', Status, COUNT(*) FROM O_PDraw GROUP BY Status UNION ALL SELECT 'O_Check', Status, COUNT(*) FROM O_Check GROUP BY Status ORDER BY src, Status" 'warehouse_status_dist.txt'

Write-Host 'DONE'
