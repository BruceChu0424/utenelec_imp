# =====================================================================
# Legacy DB (YTDQ_2023) warehouse-management module schema dump (ASCII only!)
# Why ASCII: Windows PowerShell 5.1 reads a no-BOM .ps1 as system ANSI
# (CP936 here); any non-ASCII byte swallows a quote and silently breaks
# parsing. Keep this file pure ASCII. Output -> ./data/*.txt
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

# 1. ALL tables + row counts (the master inventory: find every table and what has data)
Dump "SELECT t.name AS table_name, MAX(p.rows) AS row_count FROM sys.tables t JOIN sys.partitions p ON t.object_id=p.object_id WHERE p.index_id IN (0,1) GROUP BY t.name ORDER BY MAX(p.rows) DESC, t.name" 'all_tables_rowcount.txt'

# 2. ALL views + row counts (views reveal the doc/report structure the old UI used)
Dump "SELECT v.name AS view_name, MAX(p.rows) AS row_count FROM sys.views v JOIN sys.partitions p ON v.object_id=p.object_id WHERE p.index_id IN (0,1) GROUP BY v.name ORDER BY v.name" 'all_views_rowcount.txt'

Write-Host 'DONE'
