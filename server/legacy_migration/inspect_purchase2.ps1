# =====================================================================
# Legacy purchase follow-up dump (ASCII only!)
# - enumerate P_ / View_P_ objects (look for any "summary purchase" concept)
# - P_OrderMore purpose (refs + sample)
# - B_Currency / B_Storage schema + data (dictionaries to migrate)
# - View_P_OrderNoRec definition (unreceived-order, likely the "summary" source)
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
        $cmd.CommandTimeout = 120
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
                if ($line.Length -gt 8000) { $line = $line.Substring(0, 8000) }
                $w.WriteLine($line)
            }
        } finally { $w.Close(); $fs.Close(); $r.Close() }
    } finally { $conn.Close() }
    Write-Host ('OK  ' + $File + '  (' + (Get-Item $path).Length + ' bytes)')
}

# A. All P_ / View_P_ objects (hunt for a "summary/merge purchase" concept)
Dump "SELECT name, type_desc FROM sys.objects WHERE name LIKE 'P[_]%' OR name LIKE 'View[_]P[_]%' ORDER BY type_desc, name" 'pur2_objects.txt'

# B. P_OrderMore sample (GoodsID+ColorID -> MQTY)
Dump "SELECT TOP 40 GoodsID, ColorID, MQTY FROM P_OrderMore ORDER BY MQTY DESC" 'pur2_ordermore_sample.txt'

# C. P_OrderMore references
Dump "SELECT OBJECT_NAME(referencing_id) AS referencing_object, OBJECT_NAME(referenced_id) AS referenced_object FROM sys.sql_expression_dependencies WHERE referenced_id = OBJECT_ID('P_OrderMore')" 'pur2_ordermore_refs.txt'

# D. B_Currency columns
Dump "SELECT ORDINAL_POSITION, COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH AS len, IS_NULLABLE FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'B_Currency' ORDER BY ORDINAL_POSITION" 'pur2_currency_cols.txt'

# E. B_Currency data
Dump "SELECT * FROM B_Currency ORDER BY ID" 'pur2_currency_data.txt'

# F. B_Storage columns (warehouse master)
Dump "SELECT ORDINAL_POSITION, COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH AS len, IS_NULLABLE FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'B_Storage' ORDER BY ORDINAL_POSITION" 'pur2_storage_cols.txt'

# G. B_Storage data (warehouses)
Dump "SELECT * FROM B_Storage ORDER BY ID" 'pur2_storage_data.txt'

# H. View_P_OrderNoRec definition (unreceived orders)
Dump "SELECT definition FROM sys.sql_modules WHERE object_id = OBJECT_ID('View_P_OrderNoRec')" 'pur2_view_ordernorec.txt'

# I. Distinct PStyle values in P_Order / P_In / P_Withdraw (document subtype meaning)
Dump "SELECT 'P_Order' AS src, PStyle, COUNT(*) AS cnt FROM P_Order GROUP BY PStyle UNION ALL SELECT 'P_In', PStyle, COUNT(*) FROM P_In GROUP BY PStyle UNION ALL SELECT 'P_Withdraw', PStyle, COUNT(*) FROM P_Withdraw GROUP BY PStyle ORDER BY src, PStyle" 'pur2_pstyle.txt'

# J. Status value distribution (confirm state machine: 0/1/-1 etc.)
Dump "SELECT 'P_Order' AS src, Status, COUNT(*) AS cnt FROM P_Order GROUP BY Status UNION ALL SELECT 'P_In', Status, COUNT(*) FROM P_In GROUP BY Status UNION ALL SELECT 'P_Application', Status, COUNT(*) FROM P_Application GROUP BY Status UNION ALL SELECT 'P_Withdraw', Status, COUNT(*) FROM P_Withdraw GROUP BY Status ORDER BY src, Status" 'pur2_status.txt'

Write-Host 'DONE'
