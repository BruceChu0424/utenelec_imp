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
#   powershell -ExecutionPolicy Bypass -File export_legacy.ps1 GoodsData
#   powershell -ExecutionPolicy Bypass -File export_legacy.ps1 All
#
# Output lands in ./data/ (next to goods_categories.csv / goods.csv).
# =====================================================================
param(
    [Parameter(Position = 0)] [ValidateSet('MouldCategory', 'MouldData', 'GoodsCategory', 'GoodsData', 'GoodsBom', 'ClientCategory', 'ClientData', 'SupplierCategory', 'SupplierData', 'ColorData', 'UnitData', 'CurrencyData', 'WarehouseData', 'PurchaseApplication', 'PurchaseOrder', 'PurchaseReceipt', 'PurchaseReturn', 'WarehouseDocs', 'SalesQuote', 'SalesOrder', 'SalesShipment', 'SalesOtherShipment', 'SalesReturn', 'SalesDocs', 'SubcontractData', 'ProductionData', 'HrWorkers', 'M_Acc', 'M_Style', 'M_in', 'M_out', 'M_Get', 'M_Paid', 'M_DPaid', 'M_DPaidItem', 'M_OGet', 'M_OGetItem', 'M_Bank', 'M_AllCheck', 'All')]
    [string]$Target = 'All'
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Data   # preload SqlClient for Windows PowerShell 5.1
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$dataDir = Join-Path $here 'data'
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir | Out-Null }

$cs = if ([string]::IsNullOrWhiteSpace($env:LEGACY_DB_CONNECTION_STRING)) {
    'Server=(localdb)\MSSQLLocalDB;Database=YTDQ_2023;Integrated Security=true;TrustServerCertificate=true;'
} else {
    $env:LEGACY_DB_CONNECTION_STRING
}
$script:exportResults = @()

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
            $rowCount = 0
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
                $rowCount++
            }
        }
        finally {
            $w.Close(); $fs.Close(); $r.Close()
        }
    }
    finally { $conn.Close() }
    $file = Get-Item $OutPath
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $OutPath).Hash.ToLowerInvariant()
    $script:exportResults += [pscustomobject]@{
        file = $file.Name
        rows = $rowCount
        bytes = $file.Length
        sha256 = $hash
    }
    Write-Host ('OK  ' + $OutPath + '  (' + $rowCount + ' rows, ' + $file.Length + ' bytes)')
}

# --- SQL as single-line single-quoted strings (no here-strings, no '' literals;
#     NULLs are turned into '' by the reader). ---

# Mould category tree: SystemItem ItemclassID=18 (65 flat roots).
$mouldCatSql = 'SELECT ItemID AS legacy_id, ISNULL(ParentID,0) AS parent_legacy, Number AS code, Name AS name FROM SystemItem WHERE ItemclassID=18 ORDER BY Number, ItemID'

# Mould master: B_Mould (1605 rows, 12 cols).
$mouldDataSql = 'SELECT ID AS legacy_id, ISNULL(ParentID,0) AS parent_legacy, MouldName AS name, Number AS code, Mnumber AS mnumber, QTY AS qty, ISNULL(TQTY,0) AS tqty, MStatus AS mstatus, [Status] AS status, Place AS place, summary AS summary, Remark AS remark FROM B_Mould ORDER BY ID'

# Goods category tree: ItemclassID=1 (reconciliation vs goods_categories.csv).
$goodsCatSql = 'SELECT ItemID AS legacy_id, ISNULL(ParentID,0) AS parent_legacy, Number AS code, Name AS name FROM SystemItem WHERE ItemclassID=1 ORDER BY ItemID'

# Goods master: B_Goods. Column order MUST match migrate_goods_data.sql goods_stage.
# Binary image columns are intentionally excluded; V32 keeps bytea placeholders for a separate image import.
$goodsDataSql = 'SELECT ID AS legacy_id, ANumber AS code, Goods_Name AS name, Short_Name AS short_name, Number AS model, Standard AS spec, ISNULL(ParentID,0) AS parent_legacy, UnitID AS unit_legacy_id, MColorID AS color_legacy_id, MouldID AS mould_legacy_id, ClientID AS client_legacy_id, VendID AS vend_legacy_id, VendID2 AS vend2_legacy_id, AssTeamID AS assteam_legacy_id, VeilID AS veil_legacy_id, ApproverID AS approver_legacy_id, MakeID AS make_legacy_id, Price AS price, APrice AS a_price, Price2 AS price2, Max_QTY AS max_qty, Min_QTY AS min_qty, InitStock AS init_stock, InitCount AS init_count, InitWeight AS init_weight, KQTY AS kqty, KQTY2 AS kqty2, Pieces AS pieces, LostRate AS lost_rate, CAP AS cap, Material AS material, Thickness AS thickness, LStyle AS l_style, ZWeight AS z_weight, MWeight AS m_weight, Pack AS pack, BPack AS b_pack, Paper AS paper, Series AS series, ChartID AS chart_id, Lights AS lights, StockPlace AS stock_place, CNumber AS c_number, VNumber AS v_number, BSTest AS bs_test, [Require] AS require_remark, SourceE AS source_e, WorkE AS work_e, LacquerE AS lacquer_e, IncidentalE AS incidental_e, PlatingE AS plating_e, CasingE AS casing_e, ManageE AS manage_e, PolishE AS polish_e, ElectricE AS electric_e, MachiningE AS machining_e, LostE AS lost_e, RentE AS rent_e, MakeE AS make_e, WorkRate AS work_rate, MakeRate AS make_rate, RentRate AS rent_rate, Total AS total, CTotal AS c_total, GTotal AS g_total, BomStatus AS bom_status, [Status] AS status, AppStatus AS app_status, AppStatus2 AS app_status2, GStyle AS g_style, ck AS ck, zk AS zk FROM B_Goods ORDER BY ID'

# Goods assembly BOM: B_BomItem (218k rows). BillID=parent goods (B_Goods.ID), GoodsID=component goods.
# Col order MUST match migrate_goods_bom.sql bom_stage.
$goodsBomSql = 'SELECT ID AS legacy_id, BillID AS goods_legacy_id, GoodsID AS component_legacy_id, ISNULL(ColorID,0) AS color_legacy_id, QTY AS qty, Price AS price, Total AS total, ISNULL(VendID,0) AS vend_legacy_id, Summary AS summary, BomStatus AS bom_status, SStatus AS sstatus FROM B_BomItem ORDER BY ID'

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

# Currency master: B_Currency (3 rows: CNY/USD/HKD). 5 cols match migrate_currency.sql currency_stage.
$currencyDataSql = 'SELECT ID AS legacy_id, Number AS code, CurName AS name, ExRate AS exchange_rate, Status AS status FROM B_Currency ORDER BY ID'

# Warehouse master: B_Storage (6 rows: finished/raw/goods...). Cols match migrate_warehouse.sql warehouse_stage.
$warehouseDataSql = 'SELECT ID AS legacy_id, Number AS code, Storage_Name AS name, Location AS location, Remark AS remark, IsCal AS is_accountable, ISNULL(WorkID,0) AS workshop_legacy_id, Status AS status FROM B_Storage ORDER BY ID'

# ---- Purchase documents (master + items). Cols match migrate_purchase_*.sql staging. ----
$purchaseApplicationSql     = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, Applier AS applicant_legacy, MakeID AS maker_legacy, ApproverID AS approver_legacy, Remark AS remark, Total AS total_original, Status AS status, Fulfill AS fulfill_bit, Stop AS stop_bit, Cancel AS cancel_bit, StepID AS step_id, BStyle AS b_style, AppDate AS app_date, StockID AS warehouse_legacy_id FROM P_Application ORDER BY ID'
$purchaseApplicationItemSql = 'SELECT ID AS legacy_id, BillID AS bill_legacy_id, GoodsID AS goods_legacy_id, ColorID AS color_legacy_id, QTY AS qty, Price AS price, Total AS amount_original, RQTY AS ordered_qty, UnitID AS unit_legacy_id, URate AS unit_rate, Weight AS weight, SOrderNo AS source_doc_no, SOrderNo AS sales_order_no, ProduceNo AS production_no, POrderNo AS purchase_order_no, FPlanNo AS production_plan_no, Pback AS purchase_reply, Summary AS summary, SendDate AS deliver_date FROM P_ApplicationItem ORDER BY ID'
$purchaseOrderSql           = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, SendDate AS deliver_date, Purchaser AS purchaser_legacy, MakeID AS maker_legacy, ApproverID AS approver_legacy, Remark AS remark, Total AS total_original, Status AS status, Fulfill AS fulfill_bit, Stop AS stop_bit, VendID AS supplier_legacy_id, TRate AS tax_rate, CurID AS currency_legacy_id, CRate AS exchange_rate, Cancel AS cancel_bit, PStyle AS settlement_style_legacy FROM P_Order ORDER BY ID'
$purchaseOrderItemSql       = 'SELECT ID AS legacy_id, BillID AS bill_legacy_id, GoodsID AS goods_legacy_id, ColorID AS color_legacy_id, QTY AS qty, Price AS price, Total AS amount_original, RQTY AS received_qty, WQTY AS returned_qty, ApplyID AS request_item_legacy_id, UnitID AS unit_legacy_id, URate AS unit_rate, SendDate AS deliver_date, Weight AS weight, SOrderNo AS source_doc_no, SOrderNo AS sales_order_no, PInNo AS receipt_no, FPlanNo AS production_plan_no FROM P_OrderItem ORDER BY ID'
$purchaseReceiptSql         = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, VendID AS supplier_legacy_id, StockID AS warehouse_legacy_id, SenderID AS sender_legacy, Receiver AS receiver_legacy, MakeID AS maker_legacy, ApproverID AS approver_legacy, Remark AS remark, Total AS total_original, Status AS status, TRate AS tax_rate, CurID AS currency_legacy_id, CRate AS exchange_rate, Cancel AS cancel_bit, Last_Date AS last_date, PStyle AS settlement_style_legacy, sman AS salesman_legacy FROM P_In ORDER BY ID'
$purchaseReceiptItemSql     = 'SELECT ID AS legacy_id, BillID AS bill_legacy_id, GoodsID AS goods_legacy_id, ColorID AS color_legacy_id, QTY AS qty, Price AS price, Total AS amount_original, OrderID AS order_item_legacy_id, UnitID AS unit_legacy_id, URate AS unit_rate, WQTY AS returned_qty, BPQTY AS gift_qty, Weight AS weight, SOrderNo AS source_doc_no, OrderNo AS order_no, SOrderNo AS sales_order_no, FPlanNo AS production_plan_no FROM P_InItem ORDER BY ID'
$purchaseReturnSql          = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, VendID AS supplier_legacy_id, StockID AS warehouse_legacy_id, MakeID AS maker_legacy, ApproverID AS approver_legacy, Remark AS remark, Total AS total_original, Status AS status, CurID AS currency_legacy_id, CRate AS exchange_rate, Cancel AS cancel_bit, Last_Date AS last_date, PStyle AS settlement_style_legacy FROM P_Withdraw ORDER BY ID'
$purchaseReturnItemSql      = 'SELECT ID AS legacy_id, BillID AS bill_legacy_id, GoodsID AS goods_legacy_id, ColorID AS color_legacy_id, QTY AS qty, Price AS price, Total AS amount_original, InID AS receipt_item_legacy_id, OrderID AS order_item_legacy_id, UnitID AS unit_legacy_id, URate AS unit_rate, Weight AS weight, SOrderNo AS source_doc_no, InNo AS receipt_no, OrderNo AS order_no, SOrderNo AS sales_order_no, FPlanNo AS production_plan_no FROM P_WithdrawItem ORDER BY ID'

# ---- B_Worker 参考导出（ID + 姓名）：委外/采购等迁移建 employees stub 用（legacy_id=B_Worker.ID）----
$legacyWorkerRefSql         = 'SELECT ID AS legacy_id, Emp_Name AS name FROM B_Worker ORDER BY ID'

# ---- B_Worker 完整导出（仓库人员补录用：legacy_id+name+sub_class 子类占位）----
# sub_class 暂为 NULL（B_Worker 子类字段未确认）；确认列名后把 NULL AS sub_class 改成 <列名> AS sub_class 即贯通。
$legacyWorkersSql           = 'SELECT ID AS legacy_id, Emp_Name AS name, NULL AS sub_class FROM B_Worker ORDER BY ID'

# ---- B_Worker schema 发现（确认是否有子类/部门/在职字段供 sub_class 用）----
$bWorkerSchemaSql           = 'SELECT ORDINAL_POSITION AS pos, COLUMN_NAME AS col, DATA_TYPE AS dtype, IS_NULLABLE AS nullable, CHARACTER_MAXIMUM_LENGTH AS len FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME=''B_Worker'' ORDER BY ORDINAL_POSITION'

# ---- Sys_Operator 参考导出（ID + fname）：制单员/审核员（MakeID/ApproverID）名冻结用，不入 employees 表（避免与 B_Worker 撞号）----
$legacyOperatorRefSql       = 'SELECT ID AS legacy_id, fname AS name FROM Sys_Operator ORDER BY ID'

# ---- 老库部门参考导出（SystemItem ItemclassID=5）：采购申请单 StepID → 部门名（老视图 View_P_Application 口径）----
$legacyDeptSql              = 'SELECT ItemID AS legacy_id, Name AS name, Number AS code FROM SystemItem WHERE ItemclassID = 5 ORDER BY ItemID'

# ---- B_Worker 人事全量导出（试迁测试数据用；可选列全部按文本导，迁移端 NULLIF 处理空串）----
# Emp_Style=工种/职位（老库 Post/Duty 全空）；ParentID=部门（SystemItem ItemclassID=5）。
$hrWorkersSql               = 'SELECT ID AS legacy_id, Emp_Name AS full_name, Number AS worker_number, ParentID AS dept_legacy_id, BirthDay AS birth_date, Sex AS sex, Education AS education, Emp_Style AS emp_style, Work_Date AS work_date, ID_Card AS id_card, Mobile AS mobile, Nat_Place AS nat_place, Phone AS phone, Work_Phone AS work_phone, Email AS email, Address AS address, Remark AS remark, Status AS legacy_status FROM B_Worker ORDER BY ID'

# ---- Warehouse-management docs (O_* unified -> stock_documents). ----
# 8 doc main/item tables aliased to ONE staging shape (see migrate_stock_docs.sql
# doc_stage/item_stage). Absent cols filled with 0/NULL. So each doc in the migrate
# SQL is just \copy + INSERT with a different doc_type literal (reusable).
# Column order MUST match migrate_stock_docs.sql doc_stage/item_stage exactly:
# main: legacy_id,bill_no,bill_date,stock_legacy_id,to_stock_legacy_id,client_legacy_id,supplier_legacy_id,worker_legacy,maker_legacy,approver_legacy,plan_no,bill_type,remark,total_original,status,cancel_bit,ass_team
# item: legacy_id,bill_legacy_id,goods_legacy_id,color_legacy_id,qty,price,amount,unit_legacy_id,unit_rate,weight,surplus_qty,count_qty,place_legacy_id,upstream_legacy_id,source_doc_no,summary
# worker_legacy 源随单据类型不同：TRANSFER/OTHER_IN/OTHER_OUT/FINISHED_*=WorkerID(经办/跟单)，
#   DRAW=GetID(领料人)、WDRAW=ReturnID(退料人)、CHECK=CheckID(盘点人/跟单员)。ass_team 仅 DRAW(O_PDraw.AssTeam)。

# TRANSFER warehouse transfer (O_Transfer: OStockID out / IStockID in)
$whTransferMain = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, OStockID AS stock_legacy_id, IStockID AS to_stock_legacy_id, 0 AS client_legacy_id, 0 AS supplier_legacy_id, WorkerID AS worker_legacy, MakeID AS maker_legacy, ApproverID AS approver_legacy, NULL AS plan_no, NULL AS bill_type, Remark AS remark, NULL AS total_original, Status AS status, Cancel AS cancel_bit, NULL AS ass_team FROM O_Transfer ORDER BY ID'
$whTransferItem = 'SELECT ID AS legacy_id, BillID AS bill_legacy_id, GoodsID AS goods_legacy_id, ColorID AS color_legacy_id, QTY AS qty, NULL AS price, STotal AS amount, UnitID AS unit_legacy_id, URate AS unit_rate, Weight AS weight, NULL AS surplus_qty, NULL AS count_qty, StorgePlace AS place_legacy_id, 0 AS upstream_legacy_id, NULL AS source_doc_no, Summary AS summary FROM O_TransferItem ORDER BY ID'

# OTHER_IN other inbound (O_OtherIn: BillType subtype)
$whOtherInMain = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, StockID AS stock_legacy_id, 0 AS to_stock_legacy_id, 0 AS client_legacy_id, 0 AS supplier_legacy_id, WorkerID AS worker_legacy, MakeID AS maker_legacy, ApproverID AS approver_legacy, NULL AS plan_no, BillType AS bill_type, Remark AS remark, NULL AS total_original, Status AS status, Cancel AS cancel_bit, NULL AS ass_team FROM O_OtherIn ORDER BY ID'
$whOtherInItem = 'SELECT ID AS legacy_id, BillID AS bill_legacy_id, GoodsID AS goods_legacy_id, ColorID AS color_legacy_id, QTY AS qty, NULL AS price, STotal AS amount, UnitID AS unit_legacy_id, URate AS unit_rate, Weight AS weight, NULL AS surplus_qty, NULL AS count_qty, StorgePlace AS place_legacy_id, 0 AS upstream_legacy_id, NULL AS source_doc_no, Summary AS summary FROM O_OtherInItem ORDER BY ID'

# OTHER_OUT other outbound (O_OtherOut)
$whOtherOutMain = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, StockID AS stock_legacy_id, 0 AS to_stock_legacy_id, 0 AS client_legacy_id, 0 AS supplier_legacy_id, WorkerID AS worker_legacy, MakeID AS maker_legacy, ApproverID AS approver_legacy, NULL AS plan_no, NULL AS bill_type, Remark AS remark, NULL AS total_original, Status AS status, Cancel AS cancel_bit, NULL AS ass_team FROM O_OtherOut ORDER BY ID'
$whOtherOutItem = 'SELECT ID AS legacy_id, BillID AS bill_legacy_id, GoodsID AS goods_legacy_id, ColorID AS color_legacy_id, QTY AS qty, NULL AS price, STotal AS amount, UnitID AS unit_legacy_id, URate AS unit_rate, Weight AS weight, NULL AS surplus_qty, NULL AS count_qty, StorgePlace AS place_legacy_id, 0 AS upstream_legacy_id, NULL AS source_doc_no, Summary AS summary FROM O_OtherOutItem ORDER BY ID'

# DRAW production material requisition (O_PDraw: ClientID, GetID=领料人, AssTeam=装配班组)
$whDrawMain = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, StockID AS stock_legacy_id, 0 AS to_stock_legacy_id, ClientID AS client_legacy_id, 0 AS supplier_legacy_id, GetID AS worker_legacy, MakeID AS maker_legacy, ApproverID AS approver_legacy, NULL AS plan_no, NULL AS bill_type, Remark AS remark, NULL AS total_original, Status AS status, Cancel AS cancel_bit, AssTeam AS ass_team FROM O_PDraw ORDER BY ID'
$whDrawItem = 'SELECT ID AS legacy_id, BillID AS bill_legacy_id, GoodsID AS goods_legacy_id, ColorID AS color_legacy_id, QTY AS qty, NULL AS price, STotal AS amount, UnitID AS unit_legacy_id, URate AS unit_rate, Weight AS weight, NULL AS surplus_qty, NULL AS count_qty, StorgePlace AS place_legacy_id, 0 AS upstream_legacy_id, SOrderNo AS source_doc_no, Summary AS summary FROM O_PDrawItem ORDER BY ID'

# WDRAW production material return (O_WDraw: ReturnID=退料人; item PDrawID -> upstream DRAW item)
$whWDrawMain = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, StockID AS stock_legacy_id, 0 AS to_stock_legacy_id, 0 AS client_legacy_id, 0 AS supplier_legacy_id, ReturnID AS worker_legacy, MakeID AS maker_legacy, ApproverID AS approver_legacy, NULL AS plan_no, NULL AS bill_type, Remark AS remark, NULL AS total_original, Status AS status, Cancel AS cancel_bit, NULL AS ass_team FROM O_WDraw ORDER BY ID'
$whWDrawItem = 'SELECT ID AS legacy_id, BillID AS bill_legacy_id, GoodsID AS goods_legacy_id, ColorID AS color_legacy_id, QTY AS qty, NULL AS price, STotal AS amount, UnitID AS unit_legacy_id, URate AS unit_rate, Weight AS weight, NULL AS surplus_qty, NULL AS count_qty, StorgePlace AS place_legacy_id, PDrawID AS upstream_legacy_id, PDrawNo AS source_doc_no, Summary AS summary FROM O_WDrawItem ORDER BY ID'

# FINISHED_IN finished-goods inbound (O_In: VendID supplier; item Price/Total, OrderNo)
$whFinishedInMain = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, StockID AS stock_legacy_id, 0 AS to_stock_legacy_id, 0 AS client_legacy_id, VendID AS supplier_legacy_id, WorkerID AS worker_legacy, MakeID AS maker_legacy, ApproverID AS approver_legacy, NULL AS plan_no, NULL AS bill_type, Remark AS remark, NULL AS total_original, Status AS status, Cancel AS cancel_bit, NULL AS ass_team FROM O_In ORDER BY ID'
$whFinishedInItem = 'SELECT ID AS legacy_id, BillID AS bill_legacy_id, GoodsID AS goods_legacy_id, ColorID AS color_legacy_id, QTY AS qty, Price AS price, Total AS amount, UnitID AS unit_legacy_id, URate AS unit_rate, Weight AS weight, NULL AS surplus_qty, NULL AS count_qty, 0 AS place_legacy_id, 0 AS upstream_legacy_id, OrderNo AS source_doc_no, Summary AS summary FROM O_InItem ORDER BY ID'

# FINISHED_OUT finished-goods outbound (O_Out: ClientID, Total; item Price/Total, OutNo)
$whFinishedOutMain = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, StockID AS stock_legacy_id, 0 AS to_stock_legacy_id, ClientID AS client_legacy_id, 0 AS supplier_legacy_id, WorkerID AS worker_legacy, MakeID AS maker_legacy, ApproverID AS approver_legacy, NULL AS plan_no, NULL AS bill_type, Remark AS remark, Total AS total_original, Status AS status, Cancel AS cancel_bit, NULL AS ass_team FROM O_Out ORDER BY ID'
$whFinishedOutItem = 'SELECT ID AS legacy_id, BillID AS bill_legacy_id, GoodsID AS goods_legacy_id, ColorID AS color_legacy_id, QTY AS qty, Price AS price, Total AS amount, UnitID AS unit_legacy_id, URate AS unit_rate, Weight AS weight, NULL AS surplus_qty, NULL AS count_qty, 0 AS place_legacy_id, 0 AS upstream_legacy_id, OutNo AS source_doc_no, Summary AS summary FROM O_OutItem ORDER BY ID'

# CHECK stocktaking (O_Check: CheckID=盘点人/跟单员; item NowQTY actual / SurplusQTY diff / Reason)
$whCheckMain = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, StockID AS stock_legacy_id, 0 AS to_stock_legacy_id, 0 AS client_legacy_id, 0 AS supplier_legacy_id, CheckID AS worker_legacy, MakeID AS maker_legacy, ApproverID AS approver_legacy, NULL AS plan_no, NULL AS bill_type, Remark AS remark, NULL AS total_original, Status AS status, Cancel AS cancel_bit, NULL AS ass_team FROM O_Check ORDER BY ID'
$whCheckItem = 'SELECT ID AS legacy_id, BillID AS bill_legacy_id, GoodsID AS goods_legacy_id, ColorID AS color_legacy_id, QTY AS qty, NULL AS price, STotal AS amount, UnitID AS unit_legacy_id, URate AS unit_rate, Weight AS weight, SurplusQTY AS surplus_qty, NowQTY AS count_qty, StorgePlace AS place_legacy_id, 0 AS upstream_legacy_id, NULL AS source_doc_no, Reason AS summary FROM O_CheckItem ORDER BY ID'

# StockGoods ledger (rebuild stock_balances opening; sg_stage: stock_legacy,goods_legacy,color_legacy,year,qty,fact_qty,total,weight,fact_weight)
# weight/fact_weight added for instant-inventory (V80): legacy 库存重量 column = latest-year FactWeight.
$whStockGoods = 'SELECT StockID AS stock_legacy, GoodsID AS goods_legacy, ColorID AS color_legacy, Year AS year, QTY AS qty, FactQTY AS fact_qty, Total AS total, Weight AS weight, FactWeight AS fact_weight FROM StockGoods ORDER BY StockID, GoodsID, ColorID, Year'

# ---- Sales documents (5 doc mains + 5 item tables + 1 BOM cost). Cols match migrate_sales.sql staging. ----
# S_Quote (0 rows in legacy; structure-only export keeps \copy idempotent).
$salesQuoteSql      = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, ClientID AS client_legacy, MakeID AS maker_legacy, ApproverID AS approver_legacy, [Stop] AS stop_bit, Remark AS remark, Total AS total_original, Status AS status, Status2 AS status2 FROM S_Quote ORDER BY ID'
$salesQuoteItemSql  = 'SELECT ID AS legacy_id, BillID AS bill_legacy, GoodsID AS goods_legacy, ColorID AS color_legacy, UnitID AS unit_legacy, URate AS unit_rate, BQTY AS qty, Price AS price, SPrice AS sprice, Summary AS remark FROM S_QuoteItem ORDER BY ID'
# S_Order / S_OrderItem / S_OrderCostItem. SStyle -> ship_addr (SStyle = shipping place). [Level]/[Stop] bracketed.
$salesOrderSql      = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, ClientID AS client_legacy, SendDate AS deliver_date, LinkPhone AS link_phone, SignAddr AS sign_addr, ContractNo AS contract_no, SellerID AS seller_legacy, PStyle AS p_style, MakeID AS maker_legacy, ApproverID AS approver_legacy, Remark AS remark, Total AS total_original, Status AS status, Fulfill AS fulfill_bit, [Stop] AS stop_bit, SStyle AS ship_addr, Deposit AS deposit, CurID AS cur_legacy, TRate AS tax_rate, CRate AS exchange_rate, Cancel AS cancel_bit, ClientNo AS client_no FROM S_Order ORDER BY ID'
$salesOrderItemSql  = 'SELECT ID AS legacy_id, BillID AS bill_legacy, GoodsID AS goods_legacy, ColorID AS color_legacy, QTY AS qty, Price AS price, Total AS amount_original, RQTY AS shipped_qty, WQTY AS returned_qty, FlagQTY AS flag_qty, Discount AS discount, TTotal AS tax_amount, UnitID AS unit_legacy, URate AS unit_rate, Weight AS weight, NULL AS client_no, CNumber AS client_model, InNo AS in_no, PlanNo AS plan_no, OutNo AS out_no, SWDrawNo AS swdraw_no, Summary AS remark, IQTY AS inbound_qty, KQTY2 AS circumference, SPrice AS material_price, WPrice AS die_cast_price, JPrice AS machining_price FROM S_OrderItem ORDER BY ID'
$salesOrderCostSql  = 'SELECT ID AS legacy_id, BillID AS bill_legacy, ParentID AS parent_legacy, [Level] AS level, Class AS class_code, GoodsID AS goods_legacy, ColorID AS color_legacy, MGoodsID AS alt_goods_legacy, MColorID AS alt_color_legacy, QTY AS qty, Price AS price, Total AS amount_original, OrderQTY AS order_qty, INQTY AS received_qty, PDrawQTY AS draw_qty, PWDrawQTY AS purge_qty, OWDrawQTY AS other_draw_qty, VendID AS supplier_legacy, LStatus AS l_status, POrderNo AS porder_no, PDrawNo AS pdraw_no, PInNo AS pin_no, PWDrawNo AS pwdraw_no, OWDrawNo AS owdraw_no, Summary AS remark FROM S_OrderCostItem ORDER BY ID'
# S_Out / S_OutItem (main volume). KQTY -> parcel_qty, Boxs -> carton_count, STotal -> cost_amount.
$salesOutSql        = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, ClientID AS client_legacy, StockID AS warehouse_legacy, LinkPhone AS link_phone, PCount AS p_count, SenderID AS sender_legacy, ShipAddr AS ship_addr, PStyle AS p_style, MakeID AS maker_legacy, ApproverID AS approver_legacy, Remark AS remark, Total AS total_original, Status AS status, PrintTable AS print_count, Last_Date AS last_date, TRate AS tax_rate, CurID AS cur_legacy, CRate AS exchange_rate, SellerID AS seller_legacy, Cancel AS cancel_bit FROM S_Out ORDER BY ID'
$salesOutItemSql    = 'SELECT ID AS legacy_id, BillID AS bill_legacy, GoodsID AS goods_legacy, ColorID AS color_legacy, QTY AS qty, Price AS price, Total AS amount_original, OrderID AS order_item_legacy, STotal AS cost_amount, WQTY AS returned_qty, SWDrawNo AS swdraw_no, OrderNo AS order_no, UnitID AS unit_legacy, URate AS unit_rate, SWTotal AS returned_amount, Discount AS discount, TTotal AS tax_amount, Boxs AS carton_count, KQTY AS parcel_qty, Weight AS weight, ClientNo AS client_no, CNumber AS client_model, Summary AS remark, KQTY2 AS circumference, SPrice AS material_price, WPrice AS die_cast_price, JPrice AS machining_price FROM S_OutItem ORDER BY ID'
# S_OtherOut / S_OtherOutItem (same column shape as S_Out / S_OutItem).
$salesOtherOutSql   = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, ClientID AS client_legacy, StockID AS warehouse_legacy, LinkPhone AS link_phone, PCount AS p_count, SenderID AS sender_legacy, ShipAddr AS ship_addr, PStyle AS p_style, MakeID AS maker_legacy, ApproverID AS approver_legacy, Remark AS remark, Total AS total_original, Status AS status, PrintTable AS print_count, Last_Date AS last_date, TRate AS tax_rate, CurID AS cur_legacy, CRate AS exchange_rate, SellerID AS seller_legacy, Cancel AS cancel_bit FROM S_OtherOut ORDER BY ID'
$salesOtherOutItemSql = 'SELECT ID AS legacy_id, BillID AS bill_legacy, GoodsID AS goods_legacy, ColorID AS color_legacy, QTY AS qty, Price AS price, Total AS amount_original, OrderID AS order_item_legacy, STotal AS cost_amount, WQTY AS returned_qty, SWDrawNo AS swdraw_no, OrderNo AS order_no, UnitID AS unit_legacy, URate AS unit_rate, SWTotal AS returned_amount, Discount AS discount, TTotal AS tax_amount, Boxs AS carton_count, KQTY AS parcel_qty, Weight AS weight, ClientNo AS client_no, CNumber AS client_model, Summary AS remark, KQTY2 AS circumference, SPrice AS material_price, WPrice AS die_cast_price, JPrice AS machining_price FROM S_OtherOutItem ORDER BY ID'
# S_Withdraw / S_WithdrawItem (no TRate / SendDate / ShipAddr / SenderID).
$salesWithdrawSql   = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, ClientID AS client_legacy, StockID AS warehouse_legacy, PStyle AS p_style, MakeID AS maker_legacy, ApproverID AS approver_legacy, Remark AS remark, Total AS total_original, Status AS status, Last_Date AS last_date, CurID AS cur_legacy, CRate AS exchange_rate, SellerID AS seller_legacy, Cancel AS cancel_bit FROM S_Withdraw ORDER BY ID'
$salesWithdrawItemSql = 'SELECT ID AS legacy_id, BillID AS bill_legacy, GoodsID AS goods_legacy, ColorID AS color_legacy, QTY AS qty, Price AS price, Total AS amount_original, OutNo AS out_no, OutID AS out_item_legacy, OrderID AS order_item_legacy, SOrderNo AS sorder_no, UnitID AS unit_legacy, URate AS unit_rate, Weight AS weight, KQTY AS parcel_qty, Boxs AS carton_count, Discount AS discount, STotal AS cost_amount, CNumber AS client_model, qlfa AS solution, zrdw AS responsible, Summary AS remark FROM S_WithdrawItem ORDER BY ID'

# ---- Subcontract (E_*) 8 docs + 8 items + 1 BOM cost (17 tables). Cols match migrate_subcontract.sql staging. ----
# Multi-value source columns (BomItemID / EOrderNo / SOrderNo / PlanNo / ... ) merged via CONCAT_WS into source_doc_no.
$subAskSql     = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, VendID AS supplier_legacy_id, MakeID AS maker_legacy, ApproverID AS approver_legacy, [Status] AS status, Total AS total_original, [Stop] AS stop_bit, Cancel AS cancel_bit, Remark AS remark FROM E_Ask ORDER BY ID'
$subAskItemSql = 'SELECT ID AS legacy_id, BillID AS bill_legacy_id, GoodsID AS goods_legacy_id, ColorID AS color_legacy_id, UnitID AS unit_legacy_id, URate AS unit_rate, Price AS price, Summary AS summary FROM E_AskItem ORDER BY ID'
$subApplicationSql     = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, VendID AS supplier_legacy_id, SenderID AS sender_legacy, MakeID AS maker_legacy, ApproverID AS approver_legacy, Last_Date AS last_date, CurID AS currency_legacy_id, CRate AS exchange_rate, TRate AS tax_rate, [Status] AS status, Total AS total_original, Cancel AS cancel_bit, Remark AS remark FROM E_Application ORDER BY ID'
$subApplicationItemSql = 'SELECT ID AS legacy_id, BillID AS bill_legacy_id, GoodsID AS goods_legacy_id, ColorID AS color_legacy_id, QTY AS qty, Price AS price, Total AS amount_original, OrderID AS order_item_legacy_id, UnitID AS unit_legacy_id, URate AS unit_rate, CQTY AS check_qty, Weight AS weight, NULLIF(CONCAT_WS('' | '', NULLIF(SOrderNo, ''''), NULLIF(PlanNo, ''''), NULLIF(BomItemID, ''''), NULLIF(OrderNo, '''')), '''') AS source_doc_no FROM E_ApplicationItem ORDER BY ID'
$subOrderSql         = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, VendID AS supplier_legacy_id, SendDate AS deliver_date, SendID AS send_legacy, MakeID AS maker_legacy, ApproverID AS approver_legacy, Fulfill AS fulfill_bit, [Stop] AS stop_bit, CurID AS currency_legacy_id, CRate AS exchange_rate, TRate AS tax_rate, Total AS total_original, [Status] AS status, Cancel AS cancel_bit, Remark AS remark FROM E_Order ORDER BY ID'
$subOrderItemSql     = 'SELECT ID AS legacy_id, BillID AS bill_legacy_id, GoodsID AS goods_legacy_id, ColorID AS color_legacy_id, UnitID AS unit_legacy_id, URate AS unit_rate, QTY AS qty, Price AS price, Total AS amount_original, IQTY AS received_qty, OQTY AS issued_qty, WQTY AS returned_qty, Weight AS weight, NULLIF(CONCAT_WS('' | '', NULLIF(ESONo, ''''), NULLIF(ESWNo, ''''), NULLIF(EInNo, ''''), NULLIF(SWDrawNo, ''''), NULLIF(SOrderNo, ''''), NULLIF(PlanNo, ''''), NULLIF(BomItemID, '''')), '''') AS source_doc_no FROM E_OrderItem ORDER BY ID'
$subOrderCostItemSql = 'SELECT ID AS legacy_id, BillID AS bill_legacy_id, GoodsID AS goods_legacy_id, ColorID AS color_legacy_id, QTY AS qty, MGoodsID AS m_goods_legacy_id, MColorID AS m_color_legacy_id, ParentID AS parent_legacy_id, DQTY AS unit_qty, SQTY AS issued_qty, WQTY AS returned_qty, [Class] AS line_class, [Level] AS bom_level, NULLIF(CONCAT_WS('' | '', NULLIF(SendNo, ''''), NULLIF(WDrawNo, '''')), '''') AS source_doc_no FROM E_OrderCostItem ORDER BY ID'
$subInSql     = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, VendID AS supplier_legacy_id, StockID AS warehouse_legacy_id, SenderID AS sender_legacy, MakeID AS maker_legacy, ApproverID AS approver_legacy, Last_Date AS last_date, CurID AS currency_legacy_id, CRate AS exchange_rate, TRate AS tax_rate, Total AS total_original, PStyle AS settlement_style_legacy, [Status] AS status, Cancel AS cancel_bit, Remark AS remark FROM E_In ORDER BY ID'
$subInItemSql = 'SELECT ID AS legacy_id, BillID AS bill_legacy_id, GoodsID AS goods_legacy_id, ColorID AS color_legacy_id, QTY AS qty, Price AS price, Total AS amount_original, OrderID AS order_item_legacy_id, UnitID AS unit_legacy_id, URate AS unit_rate, STotal AS amount_local, CQTY AS check_qty, OrderQTY AS order_qty, WQTY AS returned_qty, Weight AS weight, KQTY AS girth_qty, StepID AS step_legacy_id, EWTotal AS return_amount, NULLIF(EWDrawNo, '''') AS return_no, NULLIF(OrderNo, '''') AS order_no, NULLIF(CONCAT_WS('' | '', NULLIF(SOrderNo, ''''), NULLIF(PlanNo, ''''), NULLIF(BomItemID, '''')), '''') AS source_doc_no FROM E_InItem ORDER BY ID'
$subSOutSql     = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, VendID AS supplier_legacy_id, StockID AS warehouse_legacy_id, WorkID AS worker_legacy, MakeID AS maker_legacy, ApproverID AS approver_legacy, SendDate AS deliver_date, [Status] AS status, Cancel AS cancel_bit, Remark AS remark FROM E_SOut ORDER BY ID'
$subSOutItemSql = 'SELECT ID AS legacy_id, BillID AS bill_legacy_id, GoodsID AS goods_legacy_id, ColorID AS color_legacy_id, UnitID AS unit_legacy_id, URate AS unit_rate, QTY AS qty, STQTY AS stqty, EOrderID AS order_item_legacy_id, STotal AS amount_local, WQTY AS returned_qty, MGoodsID AS parent_goods_legacy_id, MColorID AS parent_color_legacy_id, Weight AS weight, NULLIF(WDrawNo, '''') AS return_no, NULLIF(EOrderNo, '''') AS order_no, NULLIF(BomItemID, '''') AS source_doc_no FROM E_SOutItem ORDER BY ID'
$subWithdrawSql     = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, VendID AS supplier_legacy_id, StockID AS warehouse_legacy_id, MakeID AS maker_legacy, ApproverID AS approver_legacy, Last_Date AS last_date, CurID AS currency_legacy_id, CRate AS exchange_rate, Total AS total_original, PStyle AS settlement_style_legacy, [Status] AS status, Cancel AS cancel_bit, Remark AS remark FROM E_WithDraw ORDER BY ID'
$subWithdrawItemSql = 'SELECT ID AS legacy_id, BillID AS bill_legacy_id, GoodsID AS goods_legacy_id, ColorID AS color_legacy_id, QTY AS qty, Price AS price, Total AS amount_original, InID AS receipt_item_legacy_id, OrderID AS order_item_legacy_id, UnitID AS unit_legacy_id, URate AS unit_rate, STotal AS amount_local, Weight AS weight, KQTY AS girth_qty, StepID AS step_legacy_id, NULLIF(InNo, '''') AS receipt_no, NULLIF(OrderNo, '''') AS order_no, NULLIF(CONCAT_WS('' | '', NULLIF(SOrderNo, ''''), NULLIF(PlanNo, ''''), NULLIF(BomItemID, '''')), '''') AS source_doc_no FROM E_WithDrawItem ORDER BY ID'
$subSWithdrawSql     = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, VendID AS supplier_legacy_id, StockID AS warehouse_legacy_id, WorkID AS worker_legacy, MakeID AS maker_legacy, ApproverID AS approver_legacy, BStyle AS b_style, [Status] AS status, Cancel AS cancel_bit, Remark AS remark FROM E_SWithDraw ORDER BY ID'
$subSWithdrawItemSql = 'SELECT ID AS legacy_id, BillID AS bill_legacy_id, GoodsID AS goods_legacy_id, ColorID AS color_legacy_id, UnitID AS unit_legacy_id, URate AS unit_rate, QTY AS qty, EOutID AS material_issue_item_legacy_id, EOrderID AS order_item_legacy_id, STotal AS amount_local, MGoodsID AS parent_goods_legacy_id, MColorID AS parent_color_legacy_id, Weight AS weight, KQTY AS girth_qty, NULLIF(EOutNo, '''') AS issue_no, NULLIF(EOrderNo, '''') AS order_no, NULLIF(CONCAT_WS('' | '', NULLIF(BomItemID, ''''), NULLIF(SWasteNo, '''')), '''') AS source_doc_no FROM E_SWithDrawItem ORDER BY ID'
$subSWasteSql     = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, VendID AS supplier_legacy_id, StockID AS warehouse_legacy_id, WorkerID AS worker_legacy, MakeID AS maker_legacy, ApproverID AS approver_legacy, Weight AS total_weight, [Status] AS status, Cancel AS cancel_bit, Remark AS remark FROM E_SWaste ORDER BY ID'
$subSWasteItemSql = 'SELECT ID AS legacy_id, BillID AS bill_legacy_id, GoodsID AS goods_legacy_id, ColorID AS color_legacy_id, UnitID AS unit_legacy_id, URate AS unit_rate, QTY AS qty, FQTY AS ending_qty, OQTY AS standard_qty, WRate AS waste_rate, Cause AS cause, OutID AS material_issue_item_legacy_id, STotal AS amount_local, Weight AS weight, NULLIF(CONCAT_WS('' | '', NULLIF(OutNo, ''''), NULLIF(WDrawNo, ''''), NULLIF(EOrderNo, '''')), '''') AS source_doc_no FROM E_SWasteItem ORDER BY ID'

# ---- Production (F_*) 5 tables. Cols match migrate_production.sql staging. ----
# F_PlanCostItem merges 9 multi-value source-doc cols into source_doc_no with PO:/PI:/... prefixes.
$planSql = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, FStyle AS f_style, DDate AS delivery_date, WorkShop AS workshop_name, WorkerID AS worker_name, Seller AS seller_name, MakeID AS maker_legacy, ApproverID AS approver_legacy, Remark AS remark, Status AS status, Fulfill AS fulfill_bit, Stop AS stop_bit, Cancel AS cancel_bit FROM F_Plan ORDER BY ID'
$planItemSql = 'SELECT ID AS legacy_id, BillID AS plan_legacy_id, ProductNo AS product_no, GoodsID AS goods_legacy_id, ColorID AS color_legacy_id, MGoodsID AS mgoods_legacy_id, UnitID AS unit_legacy_id, URate AS unit_rate, S_OrderID AS s_order_item_legacy, S_OrderNo AS sales_order_no, Client AS client_name, ClientNo AS client_no, OQTY AS oqty, QTY AS qty, LQTY AS lqty, IQTY AS iqty, FQTY AS fqty, RQTY AS rqty, BQTY AS bqty, TQTY AS tqty, PAQTY AS paqty, ISRQTY AS isrqty, CPQTY AS cpqty, POQTY AS poqty, PIQTY AS piqty, OderDate AS order_date, OutDate AS outbound_date, PBeginDate AS plan_begin_date, PEndDate AS plan_end_date, FWeight AS finished_weight, IWeight AS inbound_weight, LStatus AS lstatus, CStatus AS cstatus, StepID AS step_legacy_id, VeilID AS veil_legacy_id, AssTeamID AS ass_team_legacy_id, Fittings AS fittings, Request AS request_note, CNumber AS customer_model, Discount AS discount, LabelNo AS label_no, PAppNo AS plan_app_no, InNo AS in_no, TranNo AS tran_no, Summary AS remark FROM F_PlanItem ORDER BY ID'
$planCostSql = 'SELECT ID AS legacy_id, BillID AS bill_item_legacy_id, GoodsID AS goods_legacy_id, ColorID AS color_legacy_id, QTY AS qty, Price AS price, Total AS total, Summary AS summary, VendID AS supplier_legacy_id, OrderQTY AS order_qty, PDrawQTY AS pdraw_qty, Class AS node_class, MGoodsID AS mgoods_legacy_id, MColorID AS mcolor_legacy_id, AssTeamID AS ass_team_legacy_id, ParentID AS parent_legacy_id, DQTY AS dqty, INQTY AS in_qty, PWDrawQTY AS pwdraw_qty, SOCItemID AS soc_item_legacy_id, OWDrawQTY AS owdraw_qty, LQTY AS lqty, PQTY AS pqty, SLQTY AS slqty, RQTY AS rqty, LStatus AS lstatus, MQTY AS mqty, EOQTY AS eo_qty, EIQTY AS ei_qty, EWQTY AS ew_qty, Level AS level, PAQTY AS pa_qty, NULLIF(CONCAT_WS('' | '', CASE WHEN NULLIF(POrderNo,'''') IS NULL THEN NULL ELSE ''PO:'' + POrderNo END, CASE WHEN NULLIF(PInNo,'''') IS NULL THEN NULL ELSE ''PI:'' + PInNo END, CASE WHEN NULLIF(PWDrawNo,'''') IS NULL THEN NULL ELSE ''PW:'' + PWDrawNo END, CASE WHEN NULLIF(PDrawNo,'''') IS NULL THEN NULL ELSE ''PD:'' + PDrawNo END, CASE WHEN NULLIF(OWDrawNo,'''') IS NULL THEN NULL ELSE ''OW:'' + OWDrawNo END, CASE WHEN NULLIF(EONo,'''') IS NULL THEN NULL ELSE ''EO:'' + EONo END, CASE WHEN NULLIF(EINo,'''') IS NULL THEN NULL ELSE ''EI:'' + EINo END, CASE WHEN NULLIF(EWNo,'''') IS NULL THEN NULL ELSE ''EW:'' + EWNo END, CASE WHEN NULLIF(PAppNo,'''') IS NULL THEN NULL ELSE ''PA:'' + PAppNo END), '''') AS source_doc_no FROM F_PlanCostItem ORDER BY ID'
$drSql = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, StockID AS warehouse_legacy_id, WorkerID AS worker_legacy_id, MakeID AS maker_legacy, ApproverID AS approver_legacy, Remark AS remark, Status AS status, VendID AS supplier_legacy_id, Cancel AS cancel_bit, WorkShop AS workshop_legacy_id FROM F_DateReport ORDER BY ID'
$driSql = 'SELECT ID AS legacy_id, BillID AS report_legacy_id, GoodsID AS goods_legacy_id, ColorID AS color_legacy_id, QTY AS qty, Summary AS remark, OrderNo AS sales_order_no, PlanNo AS plan_no, OrderID AS sales_order_item_legacy, PlanID AS plan_item_legacy_id, Price AS price, Total AS total, Client AS client_name, UnitID AS unit_legacy_id, URate AS unit_rate, Boxs AS boxes, KQTY AS per_box_qty, STotal AS stotal, Weight AS weight, OrderDate AS order_date, OrderQTY AS order_qty, OutQTY AS outbound_qty, OutNo AS outbound_no, StepID AS step_legacy_id FROM F_DateReportItem ORDER BY ID'

# ---- Finance (M_*) 12 money-flow tables. Cols match migrate_finance.sql staging. ----
# M_Acc (27 rows) -> accounts. AStyle kept for reference (discarded in migrate).
$mAccSql = 'SELECT ID AS legacy_id, Number AS code, AccName AS name, AccNode AS bank_account_no, InitTotal AS init_balance, GetTotal AS receipts_total, PaidTotal AS payments_total, ISNULL(FactTotal,0) AS balance_current, ISNULL(Remark,'''') AS remark, ISNULL(ParentID,0) AS parent_legacy_id, ISNULL(Status,'''') AS status, ISNULL(StyleID,0) AS style_legacy_id, ISNULL(AStyle,1) AS a_style FROM M_Acc ORDER BY ID'
# M_Style (124 rows) -> payment_styles. Status/DeptStatus/QStatus/OrientStatus1/OrientStatus2 bit -> True/False.
$mStyleSql = 'SELECT ID AS legacy_id, StyleClassid AS style_class_id, StyleNumber AS code, StyleName AS name, ISNULL(Parentid,0) AS parent_legacy, ISNULL(Remark,'''') AS remark, ISNULL(Status,0) AS status, ISNULL(DeptStatus,0) AS dept_status, ISNULL(NextNumber,'''') AS next_number, InitTotal AS init_total, ISNULL(QStatus,0) AS q_status, ISNULL(OrientStatus1,0) AS orient_status1, ISNULL(OrientStatus2,0) AS orient_status2, ISNULL(Unit,'''') AS unit, ISNULL(ItemID,0) AS item_id FROM M_Style ORDER BY ID'
# M_in (42,489 rows) -> ar_ap_ledger direction=AR. [M_In] bracket-quoted (column shares table name).
$mInSql = 'SELECT ID AS legacy_id, BillNo AS bill_no, ISNULL(ClientID,0) AS client_legacy_id, MIn_Date AS bill_date, Last_Date AS due_date, Total AS total, [M_In] AS settled, M_Rare AS balance, ISNULL(Note,'''') AS note, Paid AS paid_bit, PaidDate AS paid_date, ISNULL(BStyle,0) AS b_style, ISNULL(PStyle,0) AS p_style, ISNULL(BillID,0) AS bill_legacy_id, ISNULL(CurID,0) AS currency_legacy_id, ISNULL(CRate,1) AS exchange_rate FROM M_In ORDER BY ID'
# M_out (44,534 rows) -> ar_ap_ledger direction=AP. Symmetric to M_in.
$mOutSql = 'SELECT ID AS legacy_id, BillNo AS bill_no, ISNULL(VendID,0) AS supplier_legacy_id, MOut_Date AS bill_date, Last_Date AS due_date, Total AS total, [M_Out] AS settled, M_Rare AS balance, ISNULL(Note,'''') AS note, Paid AS paid_bit, PaidDate AS paid_date, ISNULL(BStyle,0) AS b_style, ISNULL(PStyle,0) AS p_style, ISNULL(BillID,0) AS bill_legacy_id, ISNULL(CurID,0) AS currency_legacy_id, ISNULL(CRate,1) AS exchange_rate FROM M_Out ORDER BY ID'
# M_Get (7,804 rows) -> finance_receipts.
$mGetSql = 'SELECT ID AS legacy_id, BillNo AS bill_no, GetDate AS bill_date, ISNULL(ClientID,0) AS client_legacy_id, WorkID AS work_id, RecStyle AS rec_style, Total AS total, MakeID AS make_id, ApproverID AS approver_id, Status AS status, Status2 AS status2, ISNULL(Remark,'''') AS remark, ISNULL(RecAcc,0) AS rec_acc, CancelDate AS cancel_date, ISNULL(Source,'''') AS source, ISNULL(InvoicesNo,'''') AS invoices_no, MTotal AS mtotal, ISNULL(CurID,0) AS cur_id, ISNULL(CRate,1) AS crate, ISNULL(StepID,0) AS step_id, Cancel AS cancel, ISNULL(slf,0) AS slf, ISNULL(qtfy,0) AS qtfy, ISNULL(qtfymc,0) AS qtfymc, ISNULL(dfch,0) AS dfch, ISNULL((SELECT fname FROM Sys_Operator WHERE ID = M_Get.MakeID),'''') AS maker_name, ISNULL((SELECT fname FROM Sys_Operator WHERE ID = M_Get.ApproverID),'''') AS approver_name, ISNULL((SELECT Emp_Name FROM B_Worker WHERE ID = M_Get.WorkID),'''') AS work_name FROM M_Get ORDER BY ID'
# M_Paid (4,545 rows) -> finance_payments. Symmetric to M_Get (VendID/PaidAcc/dfzh/jsr).
$mPaidSql = 'SELECT ID AS legacy_id, BillNo AS bill_no, PaidDate AS bill_date, ISNULL(VendID,0) AS supplier_legacy_id, WorkID AS work_id, PaidStyle AS paid_style, Total AS total, MakeID AS make_id, ApproverID AS approver_id, Status AS status, Status2 AS status2, ISNULL(Remark,'''') AS remark, ISNULL(PaidAcc,0) AS paid_acc, CancelDate AS cancel_date, ISNULL(Source,'''') AS source, ISNULL(InvoicesNo,'''') AS invoices_no, MTotal AS mtotal, ISNULL(CurID,0) AS cur_id, ISNULL(CRate,1) AS crate, ISNULL(StepID,0) AS step_id, Cancel AS cancel, ISNULL(dfzh,0) AS dfzh, ISNULL(jsr,'''') AS jsr, ISNULL((SELECT fname FROM Sys_Operator WHERE ID = M_Paid.MakeID),'''') AS maker_name, ISNULL((SELECT fname FROM Sys_Operator WHERE ID = M_Paid.ApproverID),'''') AS approver_name, ISNULL((SELECT Emp_Name FROM B_Worker WHERE ID = M_Paid.WorkID),'''') AS work_name FROM M_Paid ORDER BY ID'
# M_DPaid (1,125 rows) -> finance_expenses.
$mDpaidSql = 'SELECT ID AS legacy_id, BillNo AS bill_no, PaidDate AS bill_date, WorkID AS work_id, Total AS total, MakeID AS make_id, ApproverID AS approver_id, Status AS status, Status2 AS status2, ISNULL(Remark,'''') AS remark, ISNULL(PaidAcc,0) AS paid_acc, ISNULL(InvoicesNo,'''') AS invoices_no, CancelDate AS cancel_date, ISNULL(Source,'''') AS source, ISNULL(PaidStyle,0) AS paid_style, MTotal AS mtotal, ISNULL(CurID,0) AS cur_id, ISNULL(CRate,1) AS crate, Cancel AS cancel, ISNULL(dfzh,0) AS dfzh, ISNULL((SELECT fname FROM Sys_Operator WHERE ID = M_DPaid.MakeID),'''') AS maker_name, ISNULL((SELECT fname FROM Sys_Operator WHERE ID = M_DPaid.ApproverID),'''') AS approver_name, ISNULL((SELECT Emp_Name FROM B_Worker WHERE ID = M_DPaid.WorkID),'''') AS work_name FROM M_DPaid ORDER BY ID'
# M_DPaidItem (8,537 rows) -> finance_expense_items.
$mDpaidItemSql = 'SELECT ID AS legacy_id, ISNULL(BillID,0) AS bill_legacy_id, ISNULL(StyleID,0) AS style_legacy_id, Total AS total, ISNULL(Summary,'''') AS summary, DeptID AS dept_legacy_id, CTotal AS ctotal, ISNULL(dfmc,'''') AS dfmc, QTY AS qty, Price AS price, ISNULL(AccID,0) AS acc_id FROM M_DPaidItem ORDER BY ID'
# M_OGet (1,552 rows) -> finance_other_incomes.
$mOgetSql = 'SELECT ID AS legacy_id, BillNo AS bill_no, GetDate AS bill_date, WorkID AS work_id, Total AS total, MakeID AS make_id, ApproverID AS approver_id, Status AS status, Status2 AS status2, ISNULL(Remark,'''') AS remark, ISNULL(RecAcc,0) AS rec_acc, ISNULL(InvoicesNo,'''') AS invoices_no, CancelDate AS cancel_date, ISNULL(Source,'''') AS source, ISNULL(RecStyle,0) AS rec_style, MTotal AS mtotal, ISNULL(CurID,0) AS cur_id, ISNULL(CRate,1) AS crate, Cancel AS cancel, ISNULL(dfzh,0) AS dfzh, ISNULL((SELECT fname FROM Sys_Operator WHERE ID = M_OGet.MakeID),'''') AS maker_name, ISNULL((SELECT fname FROM Sys_Operator WHERE ID = M_OGet.ApproverID),'''') AS approver_name, ISNULL((SELECT Emp_Name FROM B_Worker WHERE ID = M_OGet.WorkID),'''') AS work_name FROM M_OGet ORDER BY ID'
# M_OGetItem (1,551 rows) -> finance_other_income_items. NO QTY/Price in old schema.
$mOgetItemSql = 'SELECT ID AS legacy_id, ISNULL(BillID,0) AS bill_legacy_id, ISNULL(StyleID,0) AS style_legacy_id, Total AS total, ISNULL(Summary,'''') AS summary, DeptID AS dept_legacy_id, CTotal AS ctotal, ISNULL(df,'''') AS df FROM M_OGetItem ORDER BY ID'
# M_Bank (0 rows) -> empty CSV. migrate_finance.sql skips ingest; structure in V57 finance_bank_transfers.
$mBankSql = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, ISNULL(OutAcc,0) AS out_acc, WorkID AS work_id, Total AS total, MakeID AS make_id, ApproverID AS approver_id, Status AS status, Status2 AS status2, ISNULL(Remark,'''') AS remark, ISNULL(InvoicesNo,'''') AS invoices_no, CancelDate AS cancel_date, ISNULL(Source,'''') AS source, ISNULL(CurID,0) AS cur_id, ISNULL(CRate,1) AS crate, Cancel AS cancel FROM M_Bank ORDER BY ID'
# M_AllCheck (30,626 rows) -> finance_reconciliations.
$mAllcheckSql = 'SELECT ID AS legacy_id, ISNULL(BillNo,'''') AS bill_no, ISNULL(CheckNo,'''') AS check_no, ISNULL(Remark,'''') AS remark, ISNULL(Company,'''') AS company, InTotal AS in_total, OutTotal AS out_total, BillDate AS bill_date, OutDate AS out_date, ISNULL(AccID,0) AS acc_id, ISNULL(Source,'''') AS source, ISNULL(BStyle,0) AS b_style, ISNULL(BillID,0) AS bill_id FROM M_AllCheck ORDER BY ID'

switch ($Target) {
    'MouldCategory'   { Export-Query -Sql $mouldCatSql    -OutPath (Join-Path $dataDir 'mould_categories.csv') }
    'MouldData'       { Export-Query -Sql $mouldDataSql   -OutPath (Join-Path $dataDir 'mould.csv') }
    'GoodsCategory'   { Export-Query -Sql $goodsCatSql    -OutPath (Join-Path $dataDir 'goods_categories.csv') }
    'GoodsData'       { Export-Query -Sql $goodsDataSql   -OutPath (Join-Path $dataDir 'goods.csv') }
    'GoodsBom'        { Export-Query -Sql $goodsBomSql    -OutPath (Join-Path $dataDir 'goods_bom.csv') }
    'ClientCategory'  { Export-Query -Sql $clientCatSql   -OutPath (Join-Path $dataDir 'client_categories.csv') }
    'ClientData'      { Export-Query -Sql $clientDataSql  -OutPath (Join-Path $dataDir 'client.csv') }
    'SupplierCategory' { Export-Query -Sql $supplierCatSql  -OutPath (Join-Path $dataDir 'supplier_categories.csv') }
    'SupplierData'    { Export-Query -Sql $supplierDataSql -OutPath (Join-Path $dataDir 'supplier.csv') }
    'ColorData'       { Export-Query -Sql $colorDataSql    -OutPath (Join-Path $dataDir 'color.csv') }
    'UnitData'        { Export-Query -Sql $unitDataSql     -OutPath (Join-Path $dataDir 'unit.csv') }
    'CurrencyData'    { Export-Query -Sql $currencyDataSql -OutPath (Join-Path $dataDir 'currency.csv') }
    'WarehouseData'   { Export-Query -Sql $warehouseDataSql -OutPath (Join-Path $dataDir 'warehouse.csv') }
    'PurchaseApplication' {
        Export-Query -Sql $purchaseApplicationSql     -OutPath (Join-Path $dataDir 'purchase_applications.csv')
        Export-Query -Sql $purchaseApplicationItemSql -OutPath (Join-Path $dataDir 'purchase_application_items.csv')
        Export-Query -Sql $legacyWorkerRefSql         -OutPath (Join-Path $dataDir 'legacy_workers_ref.csv')
        Export-Query -Sql $legacyOperatorRefSql       -OutPath (Join-Path $dataDir 'legacy_operators_ref.csv')
        Export-Query -Sql $legacyDeptSql              -OutPath (Join-Path $dataDir 'legacy_departments.csv')
    }
    'PurchaseOrder' {
        Export-Query -Sql $purchaseOrderSql     -OutPath (Join-Path $dataDir 'purchase_orders.csv')
        Export-Query -Sql $purchaseOrderItemSql -OutPath (Join-Path $dataDir 'purchase_order_items.csv')
    }
    'PurchaseReceipt' {
        Export-Query -Sql $purchaseReceiptSql     -OutPath (Join-Path $dataDir 'purchase_receipts.csv')
        Export-Query -Sql $purchaseReceiptItemSql -OutPath (Join-Path $dataDir 'purchase_receipt_items.csv')
    }
    'PurchaseReturn' {
        Export-Query -Sql $purchaseReturnSql     -OutPath (Join-Path $dataDir 'purchase_returns.csv')
        Export-Query -Sql $purchaseReturnItemSql -OutPath (Join-Path $dataDir 'purchase_return_items.csv')
    }
    'WarehouseDocs' {
        # 8 warehouse docs (main+item) + StockGoods ledger. Filenames match migrate_stock_docs.sql \copy paths.
        Export-Query -Sql $whTransferMain     -OutPath (Join-Path $dataDir 'stock_transfer_m.csv')
        Export-Query -Sql $whTransferItem     -OutPath (Join-Path $dataDir 'stock_transfer_i.csv')
        Export-Query -Sql $whOtherInMain      -OutPath (Join-Path $dataDir 'stock_other_in_m.csv')
        Export-Query -Sql $whOtherInItem      -OutPath (Join-Path $dataDir 'stock_other_in_i.csv')
        Export-Query -Sql $whOtherOutMain     -OutPath (Join-Path $dataDir 'stock_other_out_m.csv')
        Export-Query -Sql $whOtherOutItem     -OutPath (Join-Path $dataDir 'stock_other_out_i.csv')
        Export-Query -Sql $whDrawMain         -OutPath (Join-Path $dataDir 'stock_draw_m.csv')
        Export-Query -Sql $whDrawItem         -OutPath (Join-Path $dataDir 'stock_draw_i.csv')
        Export-Query -Sql $whWDrawMain        -OutPath (Join-Path $dataDir 'stock_wdraw_m.csv')
        Export-Query -Sql $whWDrawItem        -OutPath (Join-Path $dataDir 'stock_wdraw_i.csv')
        Export-Query -Sql $whFinishedInMain   -OutPath (Join-Path $dataDir 'stock_finished_in_m.csv')
        Export-Query -Sql $whFinishedInItem   -OutPath (Join-Path $dataDir 'stock_finished_in_i.csv')
        Export-Query -Sql $whFinishedOutMain  -OutPath (Join-Path $dataDir 'stock_finished_out_m.csv')
        Export-Query -Sql $whFinishedOutItem  -OutPath (Join-Path $dataDir 'stock_finished_out_i.csv')
        Export-Query -Sql $whCheckMain        -OutPath (Join-Path $dataDir 'stock_check_m.csv')
        Export-Query -Sql $whCheckItem        -OutPath (Join-Path $dataDir 'stock_check_i.csv')
        Export-Query -Sql $whStockGoods       -OutPath (Join-Path $dataDir 'stock_goods.csv')
        # 人员：B_Worker 完整（建 employees stub）+ schema 发现（确认子类列）
        Export-Query -Sql $legacyWorkersSql   -OutPath (Join-Path $dataDir 'legacy_workers.csv')
        Export-Query -Sql $bWorkerSchemaSql   -OutPath (Join-Path $dataDir 'b_worker_columns.csv')
    }
    'SalesQuote' {
        Export-Query -Sql $salesQuoteSql     -OutPath (Join-Path $dataDir 'sales_quotes.csv')
        Export-Query -Sql $salesQuoteItemSql -OutPath (Join-Path $dataDir 'sales_quote_items.csv')
    }
    'SalesOrder' {
        Export-Query -Sql $salesOrderSql     -OutPath (Join-Path $dataDir 'sales_orders.csv')
        Export-Query -Sql $salesOrderItemSql -OutPath (Join-Path $dataDir 'sales_order_items.csv')
        Export-Query -Sql $salesOrderCostSql -OutPath (Join-Path $dataDir 'sales_order_cost_items.csv')
    }
    'SalesShipment' {
        Export-Query -Sql $salesOutSql     -OutPath (Join-Path $dataDir 'sales_shipments.csv')
        Export-Query -Sql $salesOutItemSql -OutPath (Join-Path $dataDir 'sales_shipment_items.csv')
    }
    'SalesOtherShipment' {
        Export-Query -Sql $salesOtherOutSql     -OutPath (Join-Path $dataDir 'sales_other_shipments.csv')
        Export-Query -Sql $salesOtherOutItemSql -OutPath (Join-Path $dataDir 'sales_other_shipment_items.csv')
    }
    'SalesReturn' {
        Export-Query -Sql $salesWithdrawSql     -OutPath (Join-Path $dataDir 'sales_returns.csv')
        Export-Query -Sql $salesWithdrawItemSql -OutPath (Join-Path $dataDir 'sales_return_items.csv')
    }
    'SalesDocs' {
        # All 11 sales CSVs in one go (matches migrate.sh --sales expected set).
        Export-Query -Sql $salesQuoteSql         -OutPath (Join-Path $dataDir 'sales_quotes.csv')
        Export-Query -Sql $salesQuoteItemSql     -OutPath (Join-Path $dataDir 'sales_quote_items.csv')
        Export-Query -Sql $salesOrderSql         -OutPath (Join-Path $dataDir 'sales_orders.csv')
        Export-Query -Sql $salesOrderItemSql     -OutPath (Join-Path $dataDir 'sales_order_items.csv')
        Export-Query -Sql $salesOrderCostSql     -OutPath (Join-Path $dataDir 'sales_order_cost_items.csv')
        Export-Query -Sql $salesOutSql           -OutPath (Join-Path $dataDir 'sales_shipments.csv')
        Export-Query -Sql $salesOutItemSql       -OutPath (Join-Path $dataDir 'sales_shipment_items.csv')
        Export-Query -Sql $salesOtherOutSql      -OutPath (Join-Path $dataDir 'sales_other_shipments.csv')
        Export-Query -Sql $salesOtherOutItemSql  -OutPath (Join-Path $dataDir 'sales_other_shipment_items.csv')
        Export-Query -Sql $salesWithdrawSql      -OutPath (Join-Path $dataDir 'sales_returns.csv')
        Export-Query -Sql $salesWithdrawItemSql  -OutPath (Join-Path $dataDir 'sales_return_items.csv')
    }
    'SubcontractData' {
        # 8 main + 8 items + 1 BOM cost = 17 CSVs. Filenames match migrate_subcontract.sql \copy paths.
        Export-Query -Sql $subAskSql              -OutPath (Join-Path $dataDir 'subcontract_ask_m.csv')
        Export-Query -Sql $subAskItemSql          -OutPath (Join-Path $dataDir 'subcontract_ask_i.csv')
        Export-Query -Sql $subApplicationSql      -OutPath (Join-Path $dataDir 'subcontract_application_m.csv')
        Export-Query -Sql $subApplicationItemSql  -OutPath (Join-Path $dataDir 'subcontract_application_i.csv')
        Export-Query -Sql $subOrderSql            -OutPath (Join-Path $dataDir 'subcontract_order_m.csv')
        Export-Query -Sql $subOrderItemSql        -OutPath (Join-Path $dataDir 'subcontract_order_i.csv')
        Export-Query -Sql $subOrderCostItemSql    -OutPath (Join-Path $dataDir 'subcontract_order_cost_i.csv')
        Export-Query -Sql $subInSql               -OutPath (Join-Path $dataDir 'subcontract_in_m.csv')
        Export-Query -Sql $subInItemSql           -OutPath (Join-Path $dataDir 'subcontract_in_i.csv')
        Export-Query -Sql $subSOutSql             -OutPath (Join-Path $dataDir 'subcontract_sout_m.csv')
        Export-Query -Sql $subSOutItemSql         -OutPath (Join-Path $dataDir 'subcontract_sout_i.csv')
        Export-Query -Sql $subWithdrawSql         -OutPath (Join-Path $dataDir 'subcontract_withdraw_m.csv')
        Export-Query -Sql $subWithdrawItemSql     -OutPath (Join-Path $dataDir 'subcontract_withdraw_i.csv')
        Export-Query -Sql $subSWithdrawSql        -OutPath (Join-Path $dataDir 'subcontract_swithdraw_m.csv')
        Export-Query -Sql $subSWithdrawItemSql    -OutPath (Join-Path $dataDir 'subcontract_swithdraw_i.csv')
        Export-Query -Sql $subSWasteSql           -OutPath (Join-Path $dataDir 'subcontract_swaste_m.csv')
        Export-Query -Sql $subSWasteItemSql       -OutPath (Join-Path $dataDir 'subcontract_swaste_i.csv')
        # 人员参考（收货人/经办人=B_Worker→employees stub；制单员/审核员=Sys_Operator→冻结名）
        Export-Query -Sql $legacyWorkerRefSql     -OutPath (Join-Path $dataDir 'legacy_workers_ref.csv')
        Export-Query -Sql $legacyOperatorRefSql   -OutPath (Join-Path $dataDir 'legacy_operators_ref.csv')
    }
    'ProductionData' {
        # 5 production CSVs (F_Plan / F_PlanItem / F_PlanCostItem / F_DateReport / F_DateReportItem).
        Export-Query -Sql $planSql     -OutPath (Join-Path $dataDir 'production_plans.csv')
        Export-Query -Sql $planItemSql -OutPath (Join-Path $dataDir 'production_plan_items.csv')
        Export-Query -Sql $planCostSql -OutPath (Join-Path $dataDir 'production_plan_costs.csv')
        Export-Query -Sql $drSql       -OutPath (Join-Path $dataDir 'production_daily_reports.csv')
        Export-Query -Sql $driSql      -OutPath (Join-Path $dataDir 'production_daily_report_items.csv')
    }
    'HrWorkers' {
        # B_Worker 人事全量 + 部门字典（迁移映射用）
        Export-Query -Sql $hrWorkersSql   -OutPath (Join-Path $dataDir 'hr_workers.csv')
        Export-Query -Sql $legacyDeptSql  -OutPath (Join-Path $dataDir 'legacy_departments.csv')
    }
    'M_Acc'        { Export-Query -Sql $mAccSql        -OutPath (Join-Path $dataDir 'm_acc.csv') }
    'M_Style'      { Export-Query -Sql $mStyleSql      -OutPath (Join-Path $dataDir 'm_style.csv') }
    'M_in'         { Export-Query -Sql $mInSql         -OutPath (Join-Path $dataDir 'm_in.csv') }
    'M_out'        { Export-Query -Sql $mOutSql        -OutPath (Join-Path $dataDir 'm_out.csv') }
    'M_Get'        { Export-Query -Sql $mGetSql        -OutPath (Join-Path $dataDir 'm_get.csv') }
    'M_Paid'       { Export-Query -Sql $mPaidSql       -OutPath (Join-Path $dataDir 'm_paid.csv') }
    'M_DPaid'      { Export-Query -Sql $mDpaidSql      -OutPath (Join-Path $dataDir 'm_dpaid.csv') }
    'M_DPaidItem'  { Export-Query -Sql $mDpaidItemSql  -OutPath (Join-Path $dataDir 'm_dpaid_item.csv') }
    'M_OGet'       { Export-Query -Sql $mOgetSql       -OutPath (Join-Path $dataDir 'm_oget.csv') }
    'M_OGetItem'   { Export-Query -Sql $mOgetItemSql   -OutPath (Join-Path $dataDir 'm_oget_item.csv') }
    'M_Bank'       { Export-Query -Sql $mBankSql       -OutPath (Join-Path $dataDir 'm_bank.csv') }
    'M_AllCheck'   { Export-Query -Sql $mAllcheckSql   -OutPath (Join-Path $dataDir 'm_allcheck.csv') }
    'All' {
        Export-Query -Sql $goodsCatSql     -OutPath (Join-Path $dataDir 'goods_categories.csv')
        Export-Query -Sql $goodsDataSql    -OutPath (Join-Path $dataDir 'goods.csv')
        Export-Query -Sql $goodsBomSql     -OutPath (Join-Path $dataDir 'goods_bom.csv')
        Export-Query -Sql $mouldCatSql     -OutPath (Join-Path $dataDir 'mould_categories.csv')
        Export-Query -Sql $mouldDataSql    -OutPath (Join-Path $dataDir 'mould.csv')
        Export-Query -Sql $clientCatSql    -OutPath (Join-Path $dataDir 'client_categories.csv')
        Export-Query -Sql $clientDataSql   -OutPath (Join-Path $dataDir 'client.csv')
        Export-Query -Sql $supplierCatSql  -OutPath (Join-Path $dataDir 'supplier_categories.csv')
        Export-Query -Sql $supplierDataSql -OutPath (Join-Path $dataDir 'supplier.csv')
        Export-Query -Sql $colorDataSql    -OutPath (Join-Path $dataDir 'color.csv')
        Export-Query -Sql $unitDataSql     -OutPath (Join-Path $dataDir 'unit.csv')
        Export-Query -Sql $currencyDataSql -OutPath (Join-Path $dataDir 'currency.csv')
        Export-Query -Sql $warehouseDataSql -OutPath (Join-Path $dataDir 'warehouse.csv')
        Export-Query -Sql $purchaseApplicationSql     -OutPath (Join-Path $dataDir 'purchase_applications.csv')
        Export-Query -Sql $purchaseApplicationItemSql -OutPath (Join-Path $dataDir 'purchase_application_items.csv')
        Export-Query -Sql $purchaseOrderSql     -OutPath (Join-Path $dataDir 'purchase_orders.csv')
        Export-Query -Sql $purchaseOrderItemSql -OutPath (Join-Path $dataDir 'purchase_order_items.csv')
        Export-Query -Sql $purchaseReceiptSql     -OutPath (Join-Path $dataDir 'purchase_receipts.csv')
        Export-Query -Sql $purchaseReceiptItemSql -OutPath (Join-Path $dataDir 'purchase_receipt_items.csv')
        Export-Query -Sql $purchaseReturnSql     -OutPath (Join-Path $dataDir 'purchase_returns.csv')
        Export-Query -Sql $purchaseReturnItemSql -OutPath (Join-Path $dataDir 'purchase_return_items.csv')
        # 采购参考：操作员（制单员/审核员名冻结）+ 老库部门（申请单 StepID → 部门名）
        Export-Query -Sql $legacyOperatorRefSql   -OutPath (Join-Path $dataDir 'legacy_operators_ref.csv')
        Export-Query -Sql $legacyDeptSql          -OutPath (Join-Path $dataDir 'legacy_departments.csv')
        # 人事：B_Worker 全量（试迁测试数据）
        Export-Query -Sql $hrWorkersSql           -OutPath (Join-Path $dataDir 'hr_workers.csv')
        # warehouse-management 8 docs + StockGoods ledger
        Export-Query -Sql $whTransferMain     -OutPath (Join-Path $dataDir 'stock_transfer_m.csv')
        Export-Query -Sql $whTransferItem     -OutPath (Join-Path $dataDir 'stock_transfer_i.csv')
        Export-Query -Sql $whOtherInMain      -OutPath (Join-Path $dataDir 'stock_other_in_m.csv')
        Export-Query -Sql $whOtherInItem      -OutPath (Join-Path $dataDir 'stock_other_in_i.csv')
        Export-Query -Sql $whOtherOutMain     -OutPath (Join-Path $dataDir 'stock_other_out_m.csv')
        Export-Query -Sql $whOtherOutItem     -OutPath (Join-Path $dataDir 'stock_other_out_i.csv')
        Export-Query -Sql $whDrawMain         -OutPath (Join-Path $dataDir 'stock_draw_m.csv')
        Export-Query -Sql $whDrawItem         -OutPath (Join-Path $dataDir 'stock_draw_i.csv')
        Export-Query -Sql $whWDrawMain        -OutPath (Join-Path $dataDir 'stock_wdraw_m.csv')
        Export-Query -Sql $whWDrawItem        -OutPath (Join-Path $dataDir 'stock_wdraw_i.csv')
        Export-Query -Sql $whFinishedInMain   -OutPath (Join-Path $dataDir 'stock_finished_in_m.csv')
        Export-Query -Sql $whFinishedInItem   -OutPath (Join-Path $dataDir 'stock_finished_in_i.csv')
        Export-Query -Sql $whFinishedOutMain  -OutPath (Join-Path $dataDir 'stock_finished_out_m.csv')
        Export-Query -Sql $whFinishedOutItem  -OutPath (Join-Path $dataDir 'stock_finished_out_i.csv')
        Export-Query -Sql $whCheckMain        -OutPath (Join-Path $dataDir 'stock_check_m.csv')
        Export-Query -Sql $whCheckItem        -OutPath (Join-Path $dataDir 'stock_check_i.csv')
        Export-Query -Sql $whStockGoods       -OutPath (Join-Path $dataDir 'stock_goods.csv')
        # 人员：B_Worker 完整（建 employees stub）+ schema 发现（确认子类列）
        Export-Query -Sql $legacyWorkersSql   -OutPath (Join-Path $dataDir 'legacy_workers.csv')
        Export-Query -Sql $bWorkerSchemaSql   -OutPath (Join-Path $dataDir 'b_worker_columns.csv')
        # sales 5 docs + items + BOM cost (11 CSVs)
        Export-Query -Sql $salesQuoteSql         -OutPath (Join-Path $dataDir 'sales_quotes.csv')
        Export-Query -Sql $salesQuoteItemSql     -OutPath (Join-Path $dataDir 'sales_quote_items.csv')
        Export-Query -Sql $salesOrderSql         -OutPath (Join-Path $dataDir 'sales_orders.csv')
        Export-Query -Sql $salesOrderItemSql     -OutPath (Join-Path $dataDir 'sales_order_items.csv')
        Export-Query -Sql $salesOrderCostSql     -OutPath (Join-Path $dataDir 'sales_order_cost_items.csv')
        Export-Query -Sql $salesOutSql           -OutPath (Join-Path $dataDir 'sales_shipments.csv')
        Export-Query -Sql $salesOutItemSql       -OutPath (Join-Path $dataDir 'sales_shipment_items.csv')
        Export-Query -Sql $salesOtherOutSql      -OutPath (Join-Path $dataDir 'sales_other_shipments.csv')
        Export-Query -Sql $salesOtherOutItemSql  -OutPath (Join-Path $dataDir 'sales_other_shipment_items.csv')
        Export-Query -Sql $salesWithdrawSql      -OutPath (Join-Path $dataDir 'sales_returns.csv')
        Export-Query -Sql $salesWithdrawItemSql  -OutPath (Join-Path $dataDir 'sales_return_items.csv')
        # subcontract 8 docs + items + BOM cost (17 CSVs)
        Export-Query -Sql $subAskSql              -OutPath (Join-Path $dataDir 'subcontract_ask_m.csv')
        Export-Query -Sql $subAskItemSql          -OutPath (Join-Path $dataDir 'subcontract_ask_i.csv')
        Export-Query -Sql $subApplicationSql      -OutPath (Join-Path $dataDir 'subcontract_application_m.csv')
        Export-Query -Sql $subApplicationItemSql  -OutPath (Join-Path $dataDir 'subcontract_application_i.csv')
        Export-Query -Sql $subOrderSql            -OutPath (Join-Path $dataDir 'subcontract_order_m.csv')
        Export-Query -Sql $subOrderItemSql        -OutPath (Join-Path $dataDir 'subcontract_order_i.csv')
        Export-Query -Sql $subOrderCostItemSql    -OutPath (Join-Path $dataDir 'subcontract_order_cost_i.csv')
        Export-Query -Sql $subInSql               -OutPath (Join-Path $dataDir 'subcontract_in_m.csv')
        Export-Query -Sql $subInItemSql           -OutPath (Join-Path $dataDir 'subcontract_in_i.csv')
        Export-Query -Sql $subSOutSql             -OutPath (Join-Path $dataDir 'subcontract_sout_m.csv')
        Export-Query -Sql $subSOutItemSql         -OutPath (Join-Path $dataDir 'subcontract_sout_i.csv')
        Export-Query -Sql $subWithdrawSql         -OutPath (Join-Path $dataDir 'subcontract_withdraw_m.csv')
        Export-Query -Sql $subWithdrawItemSql     -OutPath (Join-Path $dataDir 'subcontract_withdraw_i.csv')
        Export-Query -Sql $subSWithdrawSql        -OutPath (Join-Path $dataDir 'subcontract_swithdraw_m.csv')
        Export-Query -Sql $subSWithdrawItemSql    -OutPath (Join-Path $dataDir 'subcontract_swithdraw_i.csv')
        Export-Query -Sql $subSWasteSql           -OutPath (Join-Path $dataDir 'subcontract_swaste_m.csv')
        Export-Query -Sql $subSWasteItemSql       -OutPath (Join-Path $dataDir 'subcontract_swaste_i.csv')
        # 人员参考（委外：收货人/经办人=B_Worker→employees stub；制单员/审核员=Sys_Operator→冻结名）
        Export-Query -Sql $legacyWorkerRefSql     -OutPath (Join-Path $dataDir 'legacy_workers_ref.csv')
        Export-Query -Sql $legacyOperatorRefSql   -OutPath (Join-Path $dataDir 'legacy_operators_ref.csv')
        # production 5 tables (F_Plan / F_PlanItem / F_PlanCostItem / F_DateReport / F_DateReportItem)
        Export-Query -Sql $planSql     -OutPath (Join-Path $dataDir 'production_plans.csv')
        Export-Query -Sql $planItemSql -OutPath (Join-Path $dataDir 'production_plan_items.csv')
        Export-Query -Sql $planCostSql -OutPath (Join-Path $dataDir 'production_plan_costs.csv')
        Export-Query -Sql $drSql       -OutPath (Join-Path $dataDir 'production_daily_reports.csv')
        Export-Query -Sql $driSql      -OutPath (Join-Path $dataDir 'production_daily_report_items.csv')
        # finance 12 money-flow tables (m_bank.csv exported but skipped by migrate_finance.sql)
        Export-Query -Sql $mAccSql        -OutPath (Join-Path $dataDir 'm_acc.csv')
        Export-Query -Sql $mStyleSql      -OutPath (Join-Path $dataDir 'm_style.csv')
        Export-Query -Sql $mInSql         -OutPath (Join-Path $dataDir 'm_in.csv')
        Export-Query -Sql $mOutSql        -OutPath (Join-Path $dataDir 'm_out.csv')
        Export-Query -Sql $mGetSql        -OutPath (Join-Path $dataDir 'm_get.csv')
        Export-Query -Sql $mPaidSql       -OutPath (Join-Path $dataDir 'm_paid.csv')
        Export-Query -Sql $mDpaidSql      -OutPath (Join-Path $dataDir 'm_dpaid.csv')
        Export-Query -Sql $mDpaidItemSql  -OutPath (Join-Path $dataDir 'm_dpaid_item.csv')
        Export-Query -Sql $mOgetSql       -OutPath (Join-Path $dataDir 'm_oget.csv')
        Export-Query -Sql $mOgetItemSql   -OutPath (Join-Path $dataDir 'm_oget_item.csv')
        Export-Query -Sql $mBankSql       -OutPath (Join-Path $dataDir 'm_bank.csv')
        Export-Query -Sql $mAllcheckSql   -OutPath (Join-Path $dataDir 'm_allcheck.csv')
    }
}

# A successful export always writes a machine-readable fingerprint. The
# connection string itself is never persisted because it may contain secrets.
$csBuilder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder($cs)
$repoRoot = (Resolve-Path (Join-Path $here '..\..')).Path
$repositoryCommit = (& git -C $repoRoot rev-parse HEAD 2>$null)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($repositoryCommit)) {
    $repositoryCommit = 'unknown'
}
# sha256sum-compatible sidecar is written first so the JSON manifest can bind
# itself to the exact checksum list. This prevents a valid JSON file from being
# paired with CSV hashes from a different export.
$checksumPath = Join-Path $dataDir 'export_manifest.sha256'
$checksumLines = $script:exportResults | ForEach-Object {
    $_.sha256 + ' *' + $_.file
}
$checksumLines | Set-Content -LiteralPath $checksumPath -Encoding ASCII
$checksumManifestSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $checksumPath).Hash.ToLowerInvariant()
Write-Host ('OK  ' + $checksumPath + '  (migration input gate)')

$manifest = [ordered]@{
    formatVersion = 2
    target = $Target
    exportedAtUtc = [DateTime]::UtcNow.ToString('o')
    sourceServer = $csBuilder.DataSource
    sourceDatabase = $csBuilder.InitialCatalog
    consistency = 'offline-backup-required'
    repositoryCommit = $repositoryCommit.Trim()
    exportScriptSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $PSCommandPath).Hash.ToLowerInvariant()
    checksumManifestSha256 = $checksumManifestSha256
    files = $script:exportResults
}
$manifestPath = Join-Path $dataDir 'export_manifest.json'
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
Write-Host ('OK  ' + $manifestPath + '  (export fingerprint; no credentials)')
