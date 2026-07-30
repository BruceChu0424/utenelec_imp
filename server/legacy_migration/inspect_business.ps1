# =====================================================================
# Legacy DB (YTDQ_2023) business-modules schema dump (ASCII only!)
# ---------------------------------------------------------------------
# Covers S_ (Sales), E_ (Subcontract), F_ (Production), M_ (Money).
# Mirrors inspect_purchase.ps1. Output -> ./data/biz_*.txt
#
# WHY ASCII: Windows PowerShell 5.1 reads a no-BOM .ps1 as system ANSI
# (CP936 here); any non-ASCII byte swallows a quote and silently breaks
# parsing. Keep this file pure ASCII. Output goes to ./data/biz_*.txt.
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

# Prefix filter: S_ E_ F_ M_ (single-letter + underscore). Escaped [_].
$pre = "(c.TABLE_NAME LIKE 'S[_]%' OR c.TABLE_NAME LIKE 'E[_]%' OR c.TABLE_NAME LIKE 'F[_]%' OR c.TABLE_NAME LIKE 'M[_]%')"

# 1. Columns of all S_/E_/F_/M_ tables
Dump "SELECT c.TABLE_NAME, c.ORDINAL_POSITION, c.COLUMN_NAME, c.DATA_TYPE, c.CHARACTER_MAXIMUM_LENGTH AS char_len, c.NUMERIC_PRECISION AS num_prec, c.NUMERIC_SCALE AS num_scale, c.IS_NULLABLE, COLUMNPROPERTY(OBJECT_ID(c.TABLE_SCHEMA+'.'+c.TABLE_NAME), c.COLUMN_NAME, 'IsIdentity') AS is_identity FROM INFORMATION_SCHEMA.COLUMNS c WHERE $pre ORDER BY c.TABLE_NAME, c.ORDINAL_POSITION" 'biz_columns.txt'

# 2. Primary keys
Dump "SELECT tc.TABLE_NAME, kcu.COLUMN_NAME, kcu.ORDINAL_POSITION AS key_ordinal FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu ON tc.CONSTRAINT_NAME=kcu.CONSTRAINT_NAME AND tc.TABLE_SCHEMA=kcu.TABLE_SCHEMA WHERE tc.CONSTRAINT_TYPE='PRIMARY KEY' AND (tc.TABLE_NAME LIKE 'S[_]%' OR tc.TABLE_NAME LIKE 'E[_]%' OR tc.TABLE_NAME LIKE 'F[_]%' OR tc.TABLE_NAME LIKE 'M[_]%') ORDER BY tc.TABLE_NAME, kcu.ORDINAL_POSITION" 'biz_pkeys.txt'

# 3. Foreign keys
Dump "SELECT OBJECT_NAME(fk.parent_object_id) AS table_name, c.name AS column_name, OBJECT_NAME(fk.referenced_object_id) AS ref_table, rc.name AS ref_column FROM sys.foreign_keys fk JOIN sys.foreign_key_columns fkc ON fk.object_id=fkc.constraint_object_id JOIN sys.columns c ON fkc.parent_object_id=c.object_id AND fkc.parent_column_id=c.column_id JOIN sys.columns rc ON fkc.referenced_object_id=rc.object_id AND fkc.referenced_column_id=rc.column_id WHERE OBJECT_NAME(fk.parent_object_id) LIKE 'S[_]%' OR OBJECT_NAME(fk.parent_object_id) LIKE 'E[_]%' OR OBJECT_NAME(fk.parent_object_id) LIKE 'F[_]%' OR OBJECT_NAME(fk.parent_object_id) LIKE 'M[_]%' ORDER BY table_name, column_name" 'biz_fkeys.txt'

# 4. Indexes
Dump "SELECT OBJECT_NAME(i.object_id) AS table_name, i.name AS index_name, i.is_unique AS is_unique, i.type_desc AS index_type, STUFF((SELECT ', '+c.name FROM sys.index_columns ic JOIN sys.columns c ON ic.object_id=c.object_id AND ic.column_id=c.column_id WHERE ic.object_id=i.object_id AND ic.index_id=i.index_id AND ic.is_included_column=0 ORDER BY ic.key_ordinal FOR XML PATH('')),1,2,'') AS key_cols FROM sys.indexes i WHERE (OBJECT_NAME(i.object_id) LIKE 'S[_]%' OR OBJECT_NAME(i.object_id) LIKE 'E[_]%' OR OBJECT_NAME(i.object_id) LIKE 'F[_]%' OR OBJECT_NAME(i.object_id) LIKE 'M[_]%') AND i.name IS NOT NULL ORDER BY table_name, index_name" 'biz_indexes.txt'

# 5. Triggers + definition (truncated 4000) -- the business-rule gold
Dump "SELECT t.name AS table_name, tr.name AS trigger_name, m.definition FROM sys.tables t JOIN sys.triggers tr ON t.object_id=tr.parent_id JOIN sys.sql_modules m ON tr.object_id=m.object_id WHERE t.name LIKE 'S[_]%' OR t.name LIKE 'E[_]%' OR t.name LIKE 'F[_]%' OR t.name LIKE 'M[_]%' ORDER BY t.name, tr.name" 'biz_triggers.txt'

# 6. Views for these modules
Dump "SELECT v.name AS view_name FROM sys.views v WHERE v.name LIKE 'View[_]S[_]%' OR v.name LIKE 'View[_]E[_]%' OR v.name LIKE 'View[_]F[_]%' OR v.name LIKE 'View[_]M[_]%' ORDER BY v.name" 'biz_views.txt'

# 7. View definitions for the money module (decode M_In/M_Out/Get/Paid reports)
Dump "SELECT v.name AS view_name, m.definition FROM sys.views v JOIN sys.sql_modules m ON v.object_id=m.object_id WHERE v.name LIKE 'View[_]M[_]%' ORDER BY v.name" 'biz_m_views_def.txt'

# 8. View definitions for sales reports
Dump "SELECT v.name AS view_name, m.definition FROM sys.views v JOIN sys.sql_modules m ON v.object_id=m.object_id WHERE v.name LIKE 'View[_]S[_]%' ORDER BY v.name" 'biz_s_views_def.txt'

# 9. View definitions for subcontract + production
Dump "SELECT v.name AS view_name, m.definition FROM sys.views v JOIN sys.sql_modules m ON v.object_id=m.object_id WHERE v.name LIKE 'View[_]E[_]%' OR v.name LIKE 'View[_]F[_]%' ORDER BY v.name" 'biz_ef_views_def.txt'

# ---- Samples (decode semantics) ----
Dump "SELECT TOP 20 * FROM M_In ORDER BY ID DESC" 'biz_sample_m_in.txt'
Dump "SELECT TOP 20 * FROM M_Out ORDER BY ID DESC" 'biz_sample_m_out.txt'
Dump "SELECT TOP 10 * FROM M_Get ORDER BY ID DESC" 'biz_sample_m_get.txt'
Dump "SELECT TOP 10 * FROM M_Paid ORDER BY ID DESC" 'biz_sample_m_paid.txt'
Dump "SELECT TOP 5 * FROM M_DPaid ORDER BY ID DESC" 'biz_sample_m_dpaid.txt'
Dump "SELECT TOP 5 * FROM M_OGet ORDER BY ID DESC" 'biz_sample_m_oget.txt'
Dump "SELECT * FROM M_Acc ORDER BY ID" 'biz_sample_m_acc.txt'
Dump "SELECT TOP 5 * FROM M_AllCheck ORDER BY ID DESC" 'biz_sample_m_allcheck.txt'
Dump "SELECT TOP 5 * FROM E_In ORDER BY ID DESC" 'biz_sample_e_in.txt'
Dump "SELECT TOP 5 * FROM E_SOut ORDER BY ID DESC" 'biz_sample_e_sout.txt'
Dump "SELECT TOP 5 * FROM E_WithDraw ORDER BY ID DESC" 'biz_sample_e_wd.txt'
Dump "SELECT TOP 3 * FROM F_Plan ORDER BY ID DESC" 'biz_sample_f_plan.txt'
Dump "SELECT TOP 3 * FROM F_PlanItem ORDER BY ID DESC" 'biz_sample_f_planitem.txt'
Dump "SELECT TOP 3 * FROM F_PlanCostItem ORDER BY ID DESC" 'biz_sample_f_plancost.txt'
Dump "SELECT TOP 3 * FROM S_Order ORDER BY ID DESC" 'biz_sample_s_order.txt'
Dump "SELECT TOP 3 * FROM S_Out ORDER BY ID DESC" 'biz_sample_s_out.txt'
Dump "SELECT TOP 3 * FROM S_OtherOut ORDER BY ID DESC" 'biz_sample_s_otherout.txt'
Dump "SELECT TOP 3 * FROM S_Withdraw ORDER BY ID DESC" 'biz_sample_s_wd.txt'

# ---- Code dictionaries (decode BStyle/PStyle/status) ----
Dump "SELECT 'S_Order' AS t, BStyle AS code, COUNT(*) AS cnt FROM S_Order GROUP BY BStyle UNION ALL SELECT 'S_Out', BStyle, COUNT(*) FROM S_Out GROUP BY BStyle UNION ALL SELECT 'S_OtherOut', BStyle, COUNT(*) FROM S_OtherOut GROUP BY BStyle UNION ALL SELECT 'S_Withdraw', BStyle, COUNT(*) FROM S_Withdraw GROUP BY BStyle ORDER BY t, code" 'biz_dict_s_bstyle.txt'
Dump "SELECT 'M_In' AS t, MStyle AS code, COUNT(*) AS cnt FROM M_In GROUP BY MStyle UNION ALL SELECT 'M_Out', MStyle, COUNT(*) FROM M_Out GROUP BY MStyle UNION ALL SELECT 'M_Get', MStyle, COUNT(*) FROM M_Get GROUP BY MStyle UNION ALL SELECT 'M_Paid', MStyle, COUNT(*) FROM M_Paid GROUP BY MStyle ORDER BY t, code" 'biz_dict_m_style.txt'
Dump "SELECT 'S_Order' AS t, Status AS code, COUNT(*) AS cnt FROM S_Order GROUP BY Status UNION ALL SELECT 'S_Out', Status, COUNT(*) FROM S_Out GROUP BY Status UNION ALL SELECT 'E_In', Status, COUNT(*) FROM E_In GROUP BY Status UNION ALL SELECT 'E_SOut', Status, COUNT(*) FROM E_SOut GROUP BY Status UNION ALL SELECT 'F_Plan', Status, COUNT(*) FROM F_Plan GROUP BY Status UNION ALL SELECT 'M_In', Status, COUNT(*) FROM M_In GROUP BY Status UNION ALL SELECT 'M_Out', Status, COUNT(*) FROM M_Out GROUP BY Status ORDER BY t, code" 'biz_dict_status.txt'

# ---- Search for check/cheque-like columns across M_ (locate cheque mgmt) ----
Dump "SELECT c.TABLE_NAME, c.COLUMN_NAME, c.DATA_TYPE FROM INFORMATION_SCHEMA.COLUMNS c WHERE c.TABLE_NAME LIKE 'M[_]%' AND (c.COLUMN_NAME LIKE '%Check%' OR c.COLUMN_NAME LIKE '%Cheque%' OR c.COLUMN_NAME LIKE '%Draft%' OR c.COLUMN_NAME LIKE '%Bill%') ORDER BY c.TABLE_NAME, c.COLUMN_NAME" 'biz_cheque_cols.txt'

Write-Host 'DONE'
