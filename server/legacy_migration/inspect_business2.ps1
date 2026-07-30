# =====================================================================
# Legacy DB (YTDQ_2023) targeted re-dump (ASCII only!)
# ---------------------------------------------------------------------
# Fills gaps flagged by sourcing-doc agents:
#   1. FULL trigger source via sp_helptext (no 4000-char truncation) for
#      the cross-module AR/AP posting triggers (S_Out/S_OtherOut/S_Withdraw/
#      P_In/P_Withdraw/E_In/E_WithDraw -> M_in/M_out) + M_Get/M_Paid/M_Acc.
#   2. M_Style full tree (124 rows) for payment_styles master design.
#   3. Small style dictionaries (B_BillStyle/B_PStyle/B_GStyle/B_AStyle)
#      to decode BStyle/PStyle type codes.
#   4. SystemSource (BStyle mapping, 53 rows).
# Output -> ./data/biz2_*.txt
# WHY ASCII: PS 5.1 reads no-BOM .ps1 as CP936; keep pure ASCII.
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
                $w.WriteLine($line)
            }
        } finally { $w.Close(); $fs.Close(); $r.Close() }
    } finally { $conn.Close() }
    Write-Host ('OK  ' + $File)
}

# Full trigger source via sp_helptext for target tables.
# sp_helptext returns one row per source line (column "Text").
$targets = @('S_Out','S_OtherOut','S_Withdraw','P_In','P_Withdraw','E_In','E_WithDraw','M_Get','M_Paid','M_Acc','M_in','M_Out')
$conn = New-Object System.Data.SqlClient.SqlConnection($cs)
$conn.Open()
$trigList = @()
foreach ($t in $targets) {
    # enumerate triggers on this table
    $listCmd = $conn.CreateCommand()
    $listCmd.CommandText = "SELECT tr.name FROM sys.triggers tr JOIN sys.tables tb ON tr.parent_id=tb.object_id WHERE tb.name='$t' ORDER BY tr.name"
    $rdr = $listCmd.ExecuteReader()
    $names = @()
    while ($rdr.Read()) { $names += $rdr.GetString(0) }
    $rdr.Close()
    foreach ($tr in $names) {
        $trigList += [pscustomobject]@{ Table=$t; Trigger=$tr }
        # dump full source
        $out = Join-Path $outDir ("biz2_trig_" + $tr + ".txt")
        $htCmd = $conn.CreateCommand()
        $htCmd.CommandText = "sp_helptext"
        $htCmd.CommandType = [System.Data.CommandType]::StoredProcedure
        $p = $htCmd.Parameters.AddWithValue("@objname", $tr)
        $hr = $htCmd.ExecuteReader()
        $enc = New-Object System.Text.UTF8Encoding($false)
        $fs = [System.IO.File]::Create($out)
        $w = New-Object System.IO.StreamWriter($fs, $enc)
        try { while ($hr.Read()) { $w.WriteLine($hr.GetString(0)) } } finally { $w.Close(); $fs.Close(); $hr.Close() }
        Write-Host ('HELPTXT  ' + $tr)
    }
}
$conn.Close()

# Trigger inventory (which tables have which triggers) for the targets
$inv = ($trigList | ForEach-Object { $_.Table + '|' + $_.Trigger }) -join "`r`n"
[System.IO.File]::WriteAllText((Join-Path $outDir 'biz2_trigger_inventory.txt'), "table|trigger`r`n" + $inv, [System.Text.UTF8Encoding]::new($false))
Write-Host 'OK  biz2_trigger_inventory.txt'

# M_Style full (payment category tree, 124 rows)
Dump "SELECT * FROM M_Style ORDER BY StyleClassid, Parentid, StyleNumber" 'biz2_m_style_full.txt'

# Small style dictionaries (decode BStyle/PStyle/GStyle/AStyle codes)
Dump "SELECT 'B_BillStyle' AS src, * FROM B_BillStyle UNION ALL SELECT 'B_PStyle', * FROM B_PStyle UNION ALL SELECT 'B_GStyle', * FROM B_GStyle UNION ALL SELECT 'B_AStyle', * FROM B_AStyle UNION ALL SELECT 'B_Sex', * FROM B_Sex ORDER BY src" 'biz2_style_dicts.txt'

# SystemSource (BStyle mapping, 53 rows) + SystemPart
Dump "SELECT * FROM SystemSource ORDER BY ID" 'biz2_systemsource.txt'

# BStyle / PStyle distribution across the money + sales/subcontract/purchase main tables (decode type codes by usage)
Dump "SELECT 'M_in' AS t, BStyle AS code, COUNT(*) AS cnt FROM M_in GROUP BY BStyle UNION ALL SELECT 'M_Out', BStyle, COUNT(*) FROM M_Out GROUP BY BStyle UNION ALL SELECT 'M_Get', RecStyle, COUNT(*) FROM M_Get GROUP BY RecStyle UNION ALL SELECT 'M_Paid', PaidStyle, COUNT(*) FROM M_Paid GROUP BY PaidStyle UNION ALL SELECT 'M_DPaid', PaidStyle, COUNT(*) FROM M_DPaid GROUP BY PaidStyle UNION ALL SELECT 'M_OGet', RecStyle, COUNT(*) FROM M_OGet GROUP BY RecStyle UNION ALL SELECT 'S_Order', PStyle, COUNT(*) FROM S_Order GROUP BY PStyle UNION ALL SELECT 'S_Out', PStyle, COUNT(*) FROM S_Out GROUP BY PStyle UNION ALL SELECT 'P_Order', PStyle, COUNT(*) FROM P_Order GROUP BY PStyle UNION ALL SELECT 'P_In', PStyle, COUNT(*) FROM P_In GROUP BY PStyle UNION ALL SELECT 'E_In', PStyle, COUNT(*) FROM E_In GROUP BY PStyle UNION ALL SELECT 'E_SOut', WorkID, COUNT(*) FROM E_SOut GROUP BY WorkID ORDER BY t, code" 'biz2_style_dist.txt'

Write-Host 'DONE'
