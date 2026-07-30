# =====================================================================
# Legacy DB (YTDQ_2023) StockGoods ledger + O_ status + style dict (ASCII only!)
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
        $cmd = $conn.CreateCommand(); $cmd.CommandText = $Sql; $cmd.CommandTimeout = 300
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

# StockGoods ledger columns (backbone: 454104 rows)
Dump "SELECT c.ORDINAL_POSITION, c.COLUMN_NAME, c.DATA_TYPE, c.CHARACTER_MAXIMUM_LENGTH AS char_len, c.NUMERIC_PRECISION AS num_prec, c.NUMERIC_SCALE AS num_scale, c.IS_NULLABLE FROM INFORMATION_SCHEMA.COLUMNS c WHERE c.TABLE_NAME = 'StockGoods' ORDER BY c.ORDINAL_POSITION" 'warehouse_stockgoods_columns.txt'

# Status distribution across O_ main tables
Dump "SELECT 'O_Transfer' AS src, Status, COUNT(*) AS cnt FROM O_Transfer GROUP BY Status UNION ALL SELECT 'O_In', Status, COUNT(*) FROM O_In GROUP BY Status UNION ALL SELECT 'O_Out', Status, COUNT(*) FROM O_Out GROUP BY Status UNION ALL SELECT 'O_OtherIn', Status, COUNT(*) FROM O_OtherIn GROUP BY Status UNION ALL SELECT 'O_OtherOut', Status, COUNT(*) FROM O_OtherOut GROUP BY Status UNION ALL SELECT 'O_PDraw', Status, COUNT(*) FROM O_PDraw GROUP BY Status UNION ALL SELECT 'O_WDraw', Status, COUNT(*) FROM O_WDraw GROUP BY Status UNION ALL SELECT 'O_Check', Status, COUNT(*) FROM O_Check GROUP BY Status ORDER BY src, Status" 'warehouse_status_dist.txt'

# B_BillStyle dict (columns first to know shape)
Dump "SELECT c.COLUMN_NAME, c.DATA_TYPE FROM INFORMATION_SCHEMA.COLUMNS c WHERE c.TABLE_NAME='B_BillStyle' ORDER BY c.ORDINAL_POSITION" 'warehouse_billstyle_cols.txt'

Write-Host 'DONE'
