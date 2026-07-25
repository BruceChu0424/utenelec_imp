# =====================================================================
# Legacy DB (YTDQ_2023) offline export via .NET SqlClient -> UTF-8 CSV
# =====================================================================
# Why this exists: sqlcmd -f 65001 mangles GBK varchar into mojibake.
# .NET SqlClient decodes varchar by the column collation (Chinese_PRC_CI_AS
# -> CP936/GBK) into a correct Unicode String; we then write it to a file
# as UTF-8 directly (bypassing the GBK console). The produced CSVs feed
# migrate.sh's \copy step.
#
# IMPORTANT (Windows PowerShell 5.1): keep this file ASCII-only. PS 5.1 reads
# a no-BOM .ps1 as the system ANSI codepage (CP936 here); non-ASCII bytes
# in comments/strings can swallow quotes and silently break parsing. If you
# add Chinese, save the file as UTF-8 *with BOM*.
#
# Usage (from bash or PowerShell):
#   powershell -ExecutionPolicy Bypass -File export_legacy.ps1 MouldCategory
#   powershell -ExecutionPolicy Bypass -File export_legacy.ps1 MouldData
#   powershell -ExecutionPolicy Bypass -File export_legacy.ps1 GoodsCategory
#   powershell -ExecutionPolicy Bypass -File export_legacy.ps1 All
#
# Output lands in ./data/ (next to goods_categories.csv / goods.csv).
# =====================================================================
param(
    [Parameter(Position = 0)] [ValidateSet('MouldCategory', 'MouldData', 'GoodsCategory', 'ClientCategory', 'ClientData', 'SupplierCategory', 'SupplierData', 'ColorData', 'UnitData', 'All')]
    [string]$Target = 'All'
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Data   # preload SqlClient for Windows PowerShell 5.1
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$dataDir = Join-Path $here 'data'
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir | Out-Null }

$cs = 'Server=(localdb)\MSSQLLocalDB;Database=YTDQ_2023;Integrated Security=true;TrustServerCertificate=true;'

function Export-Query {
    param(
        [string]$Sql,
        [string]$OutPath,
        [char]$Delimiter = '|'
    )
    if ([string]::IsNullOrEmpty($Sql)) { throw 'Export-Query: Sql is empty' }
    $conn = New-Object System.Data.SqlClient.SqlConnection($cs)
    $conn.Open()
    try {
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $Sql
        $r = $cmd.ExecuteReader()
        $enc = New-Object System.Text.UTF8Encoding($false)
        $fs = [System.IO.File]::Create($OutPath)
        $w = New-Object System.IO.StreamWriter($fs, $enc)
        try {
            $headers = for ($i = 0; $i -lt $r.FieldCount; $i++) { $r.GetName($i) }
            $w.WriteLine(($headers -join $Delimiter))
            while ($r.Read()) {
                $vals = for ($i = 0; $i -lt $r.FieldCount; $i++) {
                    if ($r.IsDBNull($i)) {
                        ''
                    } else {
                        # RFC4180: quote fields that contain the delimiter, a double-quote, or a newline;
                        # otherwise PostgreSQL COPY (FORMAT csv, DELIMITER '|') mis-parses them (e.g. an
                        # address containing '|' shifts every later column -> "missing data for column X").
                        $v = $r.GetValue($i).ToString()
                        if ($v.Contains([string]$Delimiter) -or $v.Contains('"') -or $v.Contains("`r") -or $v.Contains("`n")) {
                            '"' + ($v -replace '"', '""') + '"'
                        } else {
                            $v
                        }
                    }
                }
                $w.WriteLine(($vals -join $Delimiter))
            }
        }
        finally {
            $w.Close(); $fs.Close(); $r.Close()
        }
    }
    finally { $conn.Close() }
    Write-Host ('OK  ' + $OutPath + '  (' + (Get-Item $OutPath).Length + ' bytes)')
}

# --- SQL as single-line single-quoted strings (no here-strings, no '' literals;
#     NULLs are turned into '' by the reader). ---

# Mould category tree: SystemItem ItemclassID=18 (65 flat roots).
$mouldCatSql = 'SELECT ItemID AS legacy_id, ISNULL(ParentID,0) AS parent_legacy, Number AS code, Name AS name FROM SystemItem WHERE ItemclassID=18 ORDER BY Number, ItemID'

# Mould master: B_Mould (1605 rows, 12 cols).
$mouldDataSql = 'SELECT ID AS legacy_id, ISNULL(ParentID,0) AS parent_legacy, MouldName AS name, Number AS code, Mnumber AS mnumber, QTY AS qty, ISNULL(TQTY,0) AS tqty, MStatus AS mstatus, [Status] AS status, Place AS place, summary AS summary, Remark AS remark FROM B_Mould ORDER BY ID'

# Goods category tree: ItemclassID=1 (reconciliation vs goods_categories.csv).
$goodsCatSql = 'SELECT ItemID AS legacy_id, ISNULL(ParentID,0) AS parent_legacy, Number AS code, Name AS name FROM SystemItem WHERE ItemclassID=1 ORDER BY ItemID'

# Client category tree: SystemItem ItemclassID=2 (10 roots / 40 nodes / depth 3: foreign-trade/region/province).
$clientCatSql = 'SELECT ItemID AS legacy_id, ISNULL(ParentID,0) AS parent_legacy, Number AS code, Name AS name FROM SystemItem WHERE ItemclassID=2 ORDER BY ItemID'

# Client master: B_Client (260 rows, 34 cols). Column order MUST match migrate_client_data.sql client_stage.
$clientDataSql = 'SELECT ID AS legacy_id, ISNULL(ParentID,0) AS parent_legacy, Client_Name AS name, Number AS code, Full_Name AS full_name, Client_Rank AS client_rank, PlaceID AS place_id, Emp_ID AS emp_id, Juri_Per AS legal_person, Link_Man AS linkman, Mobile AS mobile, Phone AS phone, Phone2 AS phone2, Fax AS fax, Post AS postcode, Link_Addr AS address, Email AS email, Http AS website, Shipvia AS ship_via, Ship_Addr AS ship_address, Client_Bank AS bank, Client_BankNo AS bank_account, Tax_ID AS tax_id, Credit AS credit, InitTotal AS init_total, InitTotal2 AS init_total2, CRate AS exchange_rate, TDay AS tday, PStyle AS price_style, ZJID AS zj_id, QYName AS region, ClientXZ AS client_xz, [Status] AS status, Remark AS remark FROM B_Client ORDER BY ID'

# Supplier category tree: SystemItem ItemclassID=3 (15 flat roots: hardware/plastic/glass-panel...).
$supplierCatSql = 'SELECT ItemID AS legacy_id, ISNULL(ParentID,0) AS parent_legacy, Number AS code, Name AS name FROM SystemItem WHERE ItemclassID=3 ORDER BY ItemID'

# Supplier master: B_Provider (386 rows, 29 cols). Column order MUST match migrate_supplier_data.sql supplier_stage.
$supplierDataSql = 'SELECT ID AS legacy_id, ISNULL(ParentID,0) AS parent_legacy, Vend_Name AS name, Number AS code, Vend_Desc AS description, Vend_Place AS place, Emp_ID AS emp_id, Juri_Per AS legal_person, Link_Man AS linkman, Mobile AS mobile, Phone AS phone, Phone2 AS phone2, Fax AS fax, Post AS postcode, Link_Addr AS address, Email AS email, Http AS website, Shipvia AS ship_via, Ship_Addr AS ship_address, Vend_Bank AS bank, Vend_BankNo AS bank_account, Tax_ID AS tax_id, InitTotal AS init_total, InitTotal2 AS init_total2, CRate AS exchange_rate, TDay AS tday, PStyle AS price_style, [Status] AS status, Remark AS remark FROM B_Provider ORDER BY ID'

# Color master: B_Color (151 rows, flat table — ParentID all 0, NOT a tree). 4 cols match migrate_color.sql color_stage.
$colorDataSql = 'SELECT ID AS legacy_id, Number AS code, ColorName AS name, Status AS status FROM B_Color ORDER BY ID'

# Unit master: B_Unit (66 rows, same shape as B_Color, flat). 4 cols match migrate_unit.sql unit_stage.
$unitDataSql = 'SELECT ID AS legacy_id, Number AS code, Unit_Name AS name, Status AS status FROM B_Unit ORDER BY ID'

switch ($Target) {
    'MouldCategory'   { Export-Query -Sql $mouldCatSql    -OutPath (Join-Path $dataDir 'mould_categories.csv') }
    'MouldData'       { Export-Query -Sql $mouldDataSql   -OutPath (Join-Path $dataDir 'mould.csv') }
    'GoodsCategory'   { Export-Query -Sql $goodsCatSql    -OutPath (Join-Path $dataDir 'goods_categories.csv') }
    'ClientCategory'  { Export-Query -Sql $clientCatSql   -OutPath (Join-Path $dataDir 'client_categories.csv') }
    'ClientData'      { Export-Query -Sql $clientDataSql  -OutPath (Join-Path $dataDir 'client.csv') }
    'SupplierCategory' { Export-Query -Sql $supplierCatSql  -OutPath (Join-Path $dataDir 'supplier_categories.csv') }
    'SupplierData'    { Export-Query -Sql $supplierDataSql -OutPath (Join-Path $dataDir 'supplier.csv') }
    'ColorData'       { Export-Query -Sql $colorDataSql    -OutPath (Join-Path $dataDir 'color.csv') }
    'UnitData'        { Export-Query -Sql $unitDataSql     -OutPath (Join-Path $dataDir 'unit.csv') }
    'All' {
        Export-Query -Sql $goodsCatSql     -OutPath (Join-Path $dataDir 'goods_categories.csv')
        Export-Query -Sql $mouldCatSql     -OutPath (Join-Path $dataDir 'mould_categories.csv')
        Export-Query -Sql $mouldDataSql    -OutPath (Join-Path $dataDir 'mould.csv')
        Export-Query -Sql $clientCatSql    -OutPath (Join-Path $dataDir 'client_categories.csv')
        Export-Query -Sql $clientDataSql   -OutPath (Join-Path $dataDir 'client.csv')
        Export-Query -Sql $supplierCatSql  -OutPath (Join-Path $dataDir 'supplier_categories.csv')
        Export-Query -Sql $supplierDataSql -OutPath (Join-Path $dataDir 'supplier.csv')
        Export-Query -Sql $colorDataSql    -OutPath (Join-Path $dataDir 'color.csv')
        Export-Query -Sql $unitDataSql     -OutPath (Join-Path $dataDir 'unit.csv')
    }
}
