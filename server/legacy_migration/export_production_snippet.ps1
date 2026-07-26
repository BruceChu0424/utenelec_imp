# =====================================================================
# Production module export snippet (standalone companion to migrate_production.sql)
# =====================================================================
# Exports the 5 production tables (F_Plan / F_PlanItem / F_PlanCostItem /
# F_DateReport / F_DateReportItem) from legacy YTDQ_2023 to UTF-8 CSV,
# pipe-delimited, RFC4180-quoting as needed.
#
# Pairs with migrate_production.sql. Column aliases AND column order MUST
# align with the staging tables defined there (CSVs are positional).
#
# F_PlanCostItem is the heavy one: 1,359,875 rows / ~150 MB CSV. Its 9
# multi-value source-doc columns (POrderNo / PInNo / PWDrawNo / PDrawNo /
# OWDrawNo / EONo / EINo / EWNo / PAppNo) are merged HERE via CONCAT_WS
# with type prefixes (PO:/PI:/PW:/PD:/OW:/EO:/EI:/EW:/PA:) so the migrate
# SQL consumes a single source_doc_no TEXT column (33 cols in staging,
# not 41). F_PlanItem's InNo/TranNo pair is intentionally kept separate
# in staging and merged at INSERT time (mirrors design 24 §7.2).
#
# F_DateReport / F_DateReportItem are 0 rows in YTDQ_2023; we still export
# them so the staging shape is exercised and a future non-empty legacy
# DB works without code change.
#
# IMPORTANT (Windows PowerShell 5.1): keep this file ASCII-only. PS 5.1
# reads a no-BOM .ps1 as the system ANSI codepage (CP936 here); non-ASCII
# bytes in comments/strings can swallow quotes and silently break parsing.
# If you must add Chinese, save the file as UTF-8 *with BOM*.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File export_production_snippet.ps1
# Output lands in ./data/ next to export_legacy.ps1's output.
# =====================================================================
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
                        # otherwise PostgreSQL COPY (FORMAT csv, DELIMITER '|') mis-parses them (e.g. a
                        # remark containing '|' shifts every later column -> "missing data for column X").
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

# --- SQL as single-line single-quoted strings (no here-strings, no '' literals
#     inside SQL except via doubled '' escape; NULLs are turned into '' by the
#     reader). Each SELECT column order MUST match the staging CREATE TEMP TABLE
#     in migrate_production.sql (\copy is positional). ---

# ---- F_Plan (7,235 rows -> production_plans). 15 cols; ISR + Status2 dropped
#      per design 24 §7.1 (ISR = deprecated derived qty; Status2 = prior state).
$planSql = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, FStyle AS f_style, DDate AS delivery_date, WorkShop AS workshop_name, WorkerID AS worker_name, Seller AS seller_name, MakeID AS maker_legacy, ApproverID AS approver_legacy, Remark AS remark, Status AS status, Fulfill AS fulfill_bit, Stop AS stop_bit, Cancel AS cancel_bit FROM F_Plan ORDER BY ID'

# ---- F_PlanItem (73,388 rows -> production_plan_items). 45 cols; Stop bit
#      dropped (new schema has no per-item stop flag). Note: design 24 §8.1
#      wrote "Remark AS remark" but F_PlanItem has no Remark column (it has
#      Summary); corrected here to Summary AS remark.
$planItemSql = 'SELECT ID AS legacy_id, BillID AS plan_legacy_id, ProductNo AS product_no, GoodsID AS goods_legacy_id, ColorID AS color_legacy_id, MGoodsID AS mgoods_legacy_id, UnitID AS unit_legacy_id, URate AS unit_rate, S_OrderID AS s_order_item_legacy, S_OrderNo AS sales_order_no, Client AS client_name, ClientNo AS client_no, OQTY AS oqty, QTY AS qty, LQTY AS lqty, IQTY AS iqty, FQTY AS fqty, RQTY AS rqty, BQTY AS bqty, TQTY AS tqty, PAQTY AS paqty, ISRQTY AS isrqty, CPQTY AS cpqty, POQTY AS poqty, PIQTY AS piqty, OderDate AS order_date, OutDate AS outbound_date, PBeginDate AS plan_begin_date, PEndDate AS plan_end_date, FWeight AS finished_weight, IWeight AS inbound_weight, LStatus AS lstatus, CStatus AS cstatus, StepID AS step_legacy_id, VeilID AS veil_legacy_id, AssTeamID AS ass_team_legacy_id, Fittings AS fittings, Request AS request_note, CNumber AS customer_model, Discount AS discount, LabelNo AS label_no, PAppNo AS plan_app_no, InNo AS in_no, TranNo AS tran_no, Summary AS remark FROM F_PlanItem ORDER BY ID'

# ---- F_PlanCostItem (1,359,875 rows -> production_plan_costs partitioned).
#      33 cols in staging: 41 source cols - 9 multi-value source-doc cols
#      merged here into source_doc_no. CONCAT_WS skips NULL args, so NULLIF
#      empties first; outer NULLIF collapses all-empty result back to NULL.
#      Prefix scheme (design 24 §7.3): PO=POrderNo, PI=PInNo, PW=PWDrawNo,
#      PD=PDrawNo, OW=OWDrawNo, EO=EONo, EI=EINo, EW=EWNo, PA=PAppNo.
$planCostSql = 'SELECT ID AS legacy_id, BillID AS bill_item_legacy_id, GoodsID AS goods_legacy_id, ColorID AS color_legacy_id, QTY AS qty, Price AS price, Total AS total, Summary AS summary, VendID AS supplier_legacy_id, OrderQTY AS order_qty, PDrawQTY AS pdraw_qty, Class AS node_class, MGoodsID AS mgoods_legacy_id, MColorID AS mcolor_legacy_id, AssTeamID AS ass_team_legacy_id, ParentID AS parent_legacy_id, DQTY AS dqty, INQTY AS in_qty, PWDrawQTY AS pwdraw_qty, SOCItemID AS soc_item_legacy_id, OWDrawQTY AS owdraw_qty, LQTY AS lqty, PQTY AS pqty, SLQTY AS slqty, RQTY AS rqty, LStatus AS lstatus, MQTY AS mqty, EOQTY AS eo_qty, EIQTY AS ei_qty, EWQTY AS ew_qty, Level AS level, PAQTY AS pa_qty, NULLIF(CONCAT_WS('' | '', CASE WHEN NULLIF(POrderNo,'''') IS NULL THEN NULL ELSE ''PO:'' + POrderNo END, CASE WHEN NULLIF(PInNo,'''') IS NULL THEN NULL ELSE ''PI:'' + PInNo END, CASE WHEN NULLIF(PWDrawNo,'''') IS NULL THEN NULL ELSE ''PW:'' + PWDrawNo END, CASE WHEN NULLIF(PDrawNo,'''') IS NULL THEN NULL ELSE ''PD:'' + PDrawNo END, CASE WHEN NULLIF(OWDrawNo,'''') IS NULL THEN NULL ELSE ''OW:'' + OWDrawNo END, CASE WHEN NULLIF(EONo,'''') IS NULL THEN NULL ELSE ''EO:'' + EONo END, CASE WHEN NULLIF(EINo,'''') IS NULL THEN NULL ELSE ''EI:'' + EINo END, CASE WHEN NULLIF(EWNo,'''') IS NULL THEN NULL ELSE ''EW:'' + EWNo END, CASE WHEN NULLIF(PAppNo,'''') IS NULL THEN NULL ELSE ''PA:'' + PAppNo END), '''') AS source_doc_no FROM F_PlanCostItem ORDER BY ID'

# ---- F_DateReport (0 rows -> production_daily_reports, empty structure).
#      12 cols; Status2 dropped. WorkShop is INT here (vs F_Plan varchar);
#      design 24 §7.4 unifies to department_id UUID + workshop_name TEXT in
#      new schema; we expose workshop_legacy_id INT and let migrate SQL
#      decide (NULL department_id, name-only fallback for 0 rows).
$drSql = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, StockID AS warehouse_legacy_id, WorkerID AS worker_legacy_id, MakeID AS maker_legacy, ApproverID AS approver_legacy, Remark AS remark, Status AS status, VendID AS supplier_legacy_id, Cancel AS cancel_bit, WorkShop AS workshop_legacy_id FROM F_DateReport ORDER BY ID'

# ---- F_DateReportItem (0 rows -> production_daily_report_items, empty).
#      24 cols; PQTY dropped (no matching column in V55 production_daily_report_items).
#      GoodsID/ColorID/UnitID kept as *_legacy_id for the day this table has rows.
$driSql = 'SELECT ID AS legacy_id, BillID AS report_legacy_id, GoodsID AS goods_legacy_id, ColorID AS color_legacy_id, QTY AS qty, Summary AS remark, OrderNo AS sales_order_no, PlanNo AS plan_no, OrderID AS sales_order_item_legacy, PlanID AS plan_item_legacy_id, Price AS price, Total AS total, Client AS client_name, UnitID AS unit_legacy_id, URate AS unit_rate, Boxs AS boxes, KQTY AS per_box_qty, STotal AS stotal, Weight AS weight, OrderDate AS order_date, OrderQTY AS order_qty, OutQTY AS outbound_qty, OutNo AS outbound_no, StepID AS step_legacy_id FROM F_DateReportItem ORDER BY ID'

Export-Query -Sql $planSql     -OutPath (Join-Path $dataDir 'production_plans.csv')
Export-Query -Sql $planItemSql -OutPath (Join-Path $dataDir 'production_plan_items.csv')
Export-Query -Sql $planCostSql -OutPath (Join-Path $dataDir 'production_plan_costs.csv')
Export-Query -Sql $drSql        -OutPath (Join-Path $dataDir 'production_daily_reports.csv')
Export-Query -Sql $driSql       -OutPath (Join-Path $dataDir 'production_daily_report_items.csv')
