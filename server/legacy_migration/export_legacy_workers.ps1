# 生成 legacy_workers.csv（B_Worker → employees stub 用）：legacy_id|name|sub_class
# 复用 export_legacy.ps1 的 SqlClient + RFC4180 管道符转义，单表聚焦（独立于 WarehouseDocs）。
# 用法：powershell -ExecutionPolicy Bypass -File export_legacy_workers.ps1
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Data
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$dataDir = Join-Path $here 'data'
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir | Out-Null }
$cs = 'Server=(localdb)\MSSQLLocalDB;Database=YTDQ_2023;Integrated Security=true;TrustServerCertificate=true;'
$sql = 'SELECT ID AS legacy_id, Emp_Name AS name, CONVERT(varchar(50), NULL) AS sub_class FROM B_Worker ORDER BY ID'
$out = Join-Path $dataDir 'legacy_workers.csv'

$conn = New-Object System.Data.SqlClient.SqlConnection($cs); $conn.Open()
try {
    $cmd = $conn.CreateCommand(); $cmd.CommandText = $sql
    $r = $cmd.ExecuteReader()
    $enc = New-Object System.Text.UTF8Encoding($false)
    $fs = [System.IO.File]::Create($out)
    $w = New-Object System.IO.StreamWriter($fs, $enc)
    try {
        $headers = for ($i = 0; $i -lt $r.FieldCount; $i++) { $r.GetName($i) }
        $w.WriteLine(($headers -join '|'))
        while ($r.Read()) {
            $vals = for ($i = 0; $i -lt $r.FieldCount; $i++) {
                if ($r.IsDBNull($i)) { '' }
                else {
                    $v = $r.GetValue($i).ToString()
                    if ($v.Contains('|') -or $v.Contains('"') -or $v.Contains("`r") -or $v.Contains("`n")) {
                        '"' + ($v -replace '"', '""') + '"'
                    } else { $v }
                }
            }
            $w.WriteLine(($vals -join '|'))
        }
    }
    finally { $w.Close(); $fs.Close(); $r.Close() }
}
finally { $conn.Close() }
Write-Host ('OK  ' + $out + '  (' + (Get-Item $out).Length + ' bytes)')
