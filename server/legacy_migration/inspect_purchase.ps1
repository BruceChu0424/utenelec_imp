# =====================================================================
# Legacy DB (YTDQ_2023) purchase-module schema dump (ASCII only!)
# =====================================================================
# Why ASCII: Windows PowerShell 5.1 reads a no-BOM .ps1 as system ANSI
# (CP936 here); any non-ASCII byte swallows a quote and silently breaks
# parsing. Keep this file pure ASCII. Output goes to ./data/*.txt.
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
                if ($line.Length -gt 4000) { $line = $line.Substring(0,4000) }
                $w.WriteLine($line)
            }
        } finally { $w.Close(); $fs.Close(); $r.Close() }
    } finally { $conn.Close() }
    Write-Host ('OK  ' + $File + '  (' + (Get-Item $path).Length + ' bytes)')
}

# 1. P_ tables + row counts
Dump "SELECT t.name AS table_name, MAX(p.rows) AS row_count FROM sys.tables t JOIN sys.partitions p ON t.object_id=p.object_id WHERE t.name LIKE 'P[_]%' AND p.index_id IN (0,1) GROUP BY t.name ORDER BY t.name" 'purchase_tables.txt'

# 2. Columns of every P_ table
Dump "SELECT c.TABLE_NAME, c.ORDINAL_POSITION, c.COLUMN_NAME, c.DATA_TYPE, c.CHARACTER_MAXIMUM_LENGTH AS char_len, c.NUMERIC_PRECISION AS num_prec, c.NUMERIC_SCALE AS num_scale, c.IS_NULLABLE, COLUMNPROPERTY(OBJECT_ID(c.TABLE_SCHEMA+'.'+c.TABLE_NAME), c.COLUMN_NAME, 'IsIdentity') AS is_identity FROM INFORMATION_SCHEMA.COLUMNS c WHERE c.TABLE_NAME LIKE 'P[_]%' ORDER BY c.TABLE_NAME, c.ORDINAL_POSITION" 'purchase_columns.txt'

# 3. Primary keys of P_ tables
Dump "SELECT tc.TABLE_NAME, kcu.COLUMN_NAME, kcu.ORDINAL_POSITION AS key_ordinal FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu ON tc.CONSTRAINT_NAME=kcu.CONSTRAINT_NAME AND tc.TABLE_SCHEMA=kcu.TABLE_SCHEMA WHERE tc.CONSTRAINT_TYPE='PRIMARY KEY' AND tc.TABLE_NAME LIKE 'P[_]%' ORDER BY tc.TABLE_NAME, kcu.ORDINAL_POSITION" 'purchase_pkeys.txt'

# 4. Foreign keys on P_ tables
Dump "SELECT OBJECT_NAME(fk.parent_object_id) AS table_name, c.name AS column_name, OBJECT_NAME(fk.referenced_object_id) AS ref_table, rc.name AS ref_column FROM sys.foreign_keys fk JOIN sys.foreign_key_columns fkc ON fk.object_id=fkc.constraint_object_id JOIN sys.columns c ON fkc.parent_object_id=c.object_id AND fkc.parent_column_id=c.column_id JOIN sys.columns rc ON fkc.referenced_object_id=rc.object_id AND fkc.referenced_column_id=rc.column_id WHERE OBJECT_NAME(fk.parent_object_id) LIKE 'P[_]%' ORDER BY table_name, column_name" 'purchase_fkeys.txt'

# 5. Indexes on P_ tables
Dump "SELECT OBJECT_NAME(i.object_id) AS table_name, i.name AS index_name, i.is_unique AS is_unique, i.type_desc AS index_type, STUFF((SELECT ', '+c.name FROM sys.index_columns ic JOIN sys.columns c ON ic.object_id=c.object_id AND ic.column_id=c.column_id WHERE ic.object_id=i.object_id AND ic.index_id=i.index_id AND ic.is_included_column=0 ORDER BY ic.key_ordinal FOR XML PATH('')),1,2,'') AS key_cols FROM sys.indexes i WHERE OBJECT_NAME(i.object_id) LIKE 'P[_]%' AND i.name IS NOT NULL ORDER BY table_name, index_name" 'purchase_indexes.txt'

# 6. Triggers on P_ tables (+ definition, truncated to 4000 chars per row)
Dump "SELECT t.name AS table_name, tr.name AS trigger_name, m.definition FROM sys.tables t JOIN sys.triggers tr ON t.object_id=tr.parent_id JOIN sys.sql_modules m ON tr.object_id=m.object_id WHERE t.name LIKE 'P[_]%' ORDER BY t.name, tr.name" 'purchase_triggers.txt'

# 7. Views referencing purchase (View_P_*) + which tables each view reads
Dump "SELECT v.name AS view_name, referencing_table = (SELECT TOP 1 d.referenced_entity_name FROM sys.sql_expression_dependencies d WHERE d.referencing_id=v.object_id AND d.referenced_class=1 ORDER BY d.referenced_entity_name FOR XML PATH('')) FROM sys.views v WHERE v.name LIKE 'View[_]P[_]%' ORDER BY v.name" 'purchase_views.txt'

Write-Host 'DONE'
