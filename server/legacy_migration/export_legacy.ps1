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
    [Parameter(Position = 0)] [ValidateSet('MouldCategory', 'MouldData', 'GoodsCategory', 'ClientCategory', 'ClientData', 'SupplierCategory', 'SupplierData', 'ColorData', 'UnitData', 'CurrencyData', 'WarehouseData', 'PurchaseApplication', 'PurchaseOrder', 'PurchaseReceipt', 'PurchaseReturn', 'WarehouseDocs', 'All')]
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

# Currency master: B_Currency (3 rows: CNY/USD/HKD). 5 cols match migrate_currency.sql currency_stage.
$currencyDataSql = 'SELECT ID AS legacy_id, Number AS code, CurName AS name, ExRate AS exchange_rate, Status AS status FROM B_Currency ORDER BY ID'

# Warehouse master: B_Storage (6 rows: finished/raw/goods...). Cols match migrate_warehouse.sql warehouse_stage.
$warehouseDataSql = 'SELECT ID AS legacy_id, Number AS code, Storage_Name AS name, Location AS location, Remark AS remark, IsCal AS is_accountable, ISNULL(WorkID,0) AS workshop_legacy_id, Status AS status FROM B_Storage ORDER BY ID'

# ---- Purchase documents (master + items). Cols match migrate_purchase_*.sql staging. ----
$purchaseApplicationSql     = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, Applier AS applicant_legacy, MakeID AS maker_legacy, ApproverID AS approver_legacy, Remark AS remark, Total AS total_original, Status AS status, Fulfill AS fulfill_bit, Stop AS stop_bit, Cancel AS cancel_bit, StepID AS step_id, BStyle AS b_style, AppDate AS app_date, StockID AS warehouse_legacy_id FROM P_Application ORDER BY ID'
$purchaseApplicationItemSql = 'SELECT ID AS legacy_id, BillID AS bill_legacy_id, GoodsID AS goods_legacy_id, ColorID AS color_legacy_id, QTY AS qty, Price AS price, Total AS amount_original, RQTY AS ordered_qty, UnitID AS unit_legacy_id, URate AS unit_rate, Weight AS weight, SOrderNo AS source_doc_no FROM P_ApplicationItem ORDER BY ID'
$purchaseOrderSql           = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, SendDate AS deliver_date, Purchaser AS purchaser_legacy, MakeID AS maker_legacy, ApproverID AS approver_legacy, Remark AS remark, Total AS total_original, Status AS status, Fulfill AS fulfill_bit, Stop AS stop_bit, VendID AS supplier_legacy_id, TRate AS tax_rate, CurID AS currency_legacy_id, CRate AS exchange_rate, Cancel AS cancel_bit FROM P_Order ORDER BY ID'
$purchaseOrderItemSql       = 'SELECT ID AS legacy_id, BillID AS bill_legacy_id, GoodsID AS goods_legacy_id, ColorID AS color_legacy_id, QTY AS qty, Price AS price, Total AS amount_original, RQTY AS received_qty, WQTY AS returned_qty, ApplyID AS request_item_legacy_id, UnitID AS unit_legacy_id, URate AS unit_rate, SendDate AS deliver_date, Weight AS weight, SOrderNo AS source_doc_no FROM P_OrderItem ORDER BY ID'
$purchaseReceiptSql         = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, VendID AS supplier_legacy_id, StockID AS warehouse_legacy_id, SenderID AS sender_legacy, Receiver AS receiver_legacy, MakeID AS maker_legacy, ApproverID AS approver_legacy, Remark AS remark, Total AS total_original, Status AS status, TRate AS tax_rate, CurID AS currency_legacy_id, CRate AS exchange_rate, Cancel AS cancel_bit, Last_Date AS last_date FROM P_In ORDER BY ID'
$purchaseReceiptItemSql     = 'SELECT ID AS legacy_id, BillID AS bill_legacy_id, GoodsID AS goods_legacy_id, ColorID AS color_legacy_id, QTY AS qty, Price AS price, Total AS amount_original, OrderID AS order_item_legacy_id, UnitID AS unit_legacy_id, URate AS unit_rate, WQTY AS returned_qty, BPQTY AS gift_qty, Weight AS weight, SOrderNo AS source_doc_no FROM P_InItem ORDER BY ID'
$purchaseReturnSql          = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, VendID AS supplier_legacy_id, StockID AS warehouse_legacy_id, MakeID AS maker_legacy, ApproverID AS approver_legacy, Remark AS remark, Total AS total_original, Status AS status, CurID AS currency_legacy_id, CRate AS exchange_rate, Cancel AS cancel_bit, Last_Date AS last_date FROM P_Withdraw ORDER BY ID'
$purchaseReturnItemSql      = 'SELECT ID AS legacy_id, BillID AS bill_legacy_id, GoodsID AS goods_legacy_id, ColorID AS color_legacy_id, QTY AS qty, Price AS price, Total AS amount_original, InID AS receipt_item_legacy_id, OrderID AS order_item_legacy_id, UnitID AS unit_legacy_id, URate AS unit_rate, Weight AS weight, SOrderNo AS source_doc_no FROM P_WithdrawItem ORDER BY ID'

# ---- Warehouse-management docs (O_* unified -> stock_documents). ----
# 8 doc main/item tables aliased to ONE staging shape (see migrate_stock_docs.sql
# doc_stage/item_stage). Absent cols filled with 0/NULL. So each doc in the migrate
# SQL is just \copy + INSERT with a different doc_type literal (reusable).
# Column order MUST match migrate_stock_docs.sql doc_stage/item_stage exactly:
# main: legacy_id,bill_no,bill_date,stock_legacy_id,to_stock_legacy_id,client_legacy_id,supplier_legacy_id,worker_legacy,maker_legacy,approver_legacy,plan_no,bill_type,remark,total_original,status,cancel_bit
# item: legacy_id,bill_legacy_id,goods_legacy_id,color_legacy_id,qty,price,amount,unit_legacy_id,unit_rate,weight,surplus_qty,count_qty,place_legacy_id,upstream_legacy_id,source_doc_no,summary

# TRANSFER warehouse transfer (O_Transfer: OStockID out / IStockID in)
$whTransferMain = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, OStockID AS stock_legacy_id, IStockID AS to_stock_legacy_id, 0 AS client_legacy_id, 0 AS supplier_legacy_id, WorkerID AS worker_legacy, MakeID AS maker_legacy, ApproverID AS approver_legacy, NULL AS plan_no, NULL AS bill_type, Remark AS remark, NULL AS total_original, Status AS status, Cancel AS cancel_bit FROM O_Transfer ORDER BY ID'
$whTransferItem = 'SELECT ID AS legacy_id, BillID AS bill_legacy_id, GoodsID AS goods_legacy_id, ColorID AS color_legacy_id, QTY AS qty, NULL AS price, STotal AS amount, UnitID AS unit_legacy_id, URate AS unit_rate, Weight AS weight, NULL AS surplus_qty, NULL AS count_qty, StorgePlace AS place_legacy_id, 0 AS upstream_legacy_id, NULL AS source_doc_no, Summary AS summary FROM O_TransferItem ORDER BY ID'

# OTHER_IN other inbound (O_OtherIn: BillType subtype)
$whOtherInMain = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, StockID AS stock_legacy_id, 0 AS to_stock_legacy_id, 0 AS client_legacy_id, 0 AS supplier_legacy_id, WorkerID AS worker_legacy, MakeID AS maker_legacy, ApproverID AS approver_legacy, NULL AS plan_no, BillType AS bill_type, Remark AS remark, NULL AS total_original, Status AS status, Cancel AS cancel_bit FROM O_OtherIn ORDER BY ID'
$whOtherInItem = 'SELECT ID AS legacy_id, BillID AS bill_legacy_id, GoodsID AS goods_legacy_id, ColorID AS color_legacy_id, QTY AS qty, NULL AS price, STotal AS amount, UnitID AS unit_legacy_id, URate AS unit_rate, Weight AS weight, NULL AS surplus_qty, NULL AS count_qty, StorgePlace AS place_legacy_id, 0 AS upstream_legacy_id, NULL AS source_doc_no, Summary AS summary FROM O_OtherInItem ORDER BY ID'

# OTHER_OUT other outbound (O_OtherOut)
$whOtherOutMain = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, StockID AS stock_legacy_id, 0 AS to_stock_legacy_id, 0 AS client_legacy_id, 0 AS supplier_legacy_id, WorkerID AS worker_legacy, MakeID AS maker_legacy, ApproverID AS approver_legacy, NULL AS plan_no, NULL AS bill_type, Remark AS remark, NULL AS total_original, Status AS status, Cancel AS cancel_bit FROM O_OtherOut ORDER BY ID'
$whOtherOutItem = 'SELECT ID AS legacy_id, BillID AS bill_legacy_id, GoodsID AS goods_legacy_id, ColorID AS color_legacy_id, QTY AS qty, NULL AS price, STotal AS amount, UnitID AS unit_legacy_id, URate AS unit_rate, Weight AS weight, NULL AS surplus_qty, NULL AS count_qty, StorgePlace AS place_legacy_id, 0 AS upstream_legacy_id, NULL AS source_doc_no, Summary AS summary FROM O_OtherOutItem ORDER BY ID'

# DRAW production material requisition (O_PDraw: ClientID)
$whDrawMain = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, StockID AS stock_legacy_id, 0 AS to_stock_legacy_id, ClientID AS client_legacy_id, 0 AS supplier_legacy_id, 0 AS worker_legacy, MakeID AS maker_legacy, ApproverID AS approver_legacy, NULL AS plan_no, NULL AS bill_type, Remark AS remark, NULL AS total_original, Status AS status, Cancel AS cancel_bit FROM O_PDraw ORDER BY ID'
$whDrawItem = 'SELECT ID AS legacy_id, BillID AS bill_legacy_id, GoodsID AS goods_legacy_id, ColorID AS color_legacy_id, QTY AS qty, NULL AS price, STotal AS amount, UnitID AS unit_legacy_id, URate AS unit_rate, Weight AS weight, NULL AS surplus_qty, NULL AS count_qty, StorgePlace AS place_legacy_id, 0 AS upstream_legacy_id, SOrderNo AS source_doc_no, Summary AS summary FROM O_PDrawItem ORDER BY ID'

# WDRAW production material return (O_WDraw; item PDrawID -> upstream DRAW item)
$whWDrawMain = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, StockID AS stock_legacy_id, 0 AS to_stock_legacy_id, 0 AS client_legacy_id, 0 AS supplier_legacy_id, 0 AS worker_legacy, MakeID AS maker_legacy, ApproverID AS approver_legacy, NULL AS plan_no, NULL AS bill_type, Remark AS remark, NULL AS total_original, Status AS status, Cancel AS cancel_bit FROM O_WDraw ORDER BY ID'
$whWDrawItem = 'SELECT ID AS legacy_id, BillID AS bill_legacy_id, GoodsID AS goods_legacy_id, ColorID AS color_legacy_id, QTY AS qty, NULL AS price, STotal AS amount, UnitID AS unit_legacy_id, URate AS unit_rate, Weight AS weight, NULL AS surplus_qty, NULL AS count_qty, StorgePlace AS place_legacy_id, PDrawID AS upstream_legacy_id, PDrawNo AS source_doc_no, Summary AS summary FROM O_WDrawItem ORDER BY ID'

# FINISHED_IN finished-goods inbound (O_In: VendID supplier; item Price/Total, OrderNo)
$whFinishedInMain = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, StockID AS stock_legacy_id, 0 AS to_stock_legacy_id, 0 AS client_legacy_id, VendID AS supplier_legacy_id, WorkerID AS worker_legacy, MakeID AS maker_legacy, ApproverID AS approver_legacy, NULL AS plan_no, NULL AS bill_type, Remark AS remark, NULL AS total_original, Status AS status, Cancel AS cancel_bit FROM O_In ORDER BY ID'
$whFinishedInItem = 'SELECT ID AS legacy_id, BillID AS bill_legacy_id, GoodsID AS goods_legacy_id, ColorID AS color_legacy_id, QTY AS qty, Price AS price, Total AS amount, UnitID AS unit_legacy_id, URate AS unit_rate, Weight AS weight, NULL AS surplus_qty, NULL AS count_qty, 0 AS place_legacy_id, 0 AS upstream_legacy_id, OrderNo AS source_doc_no, Summary AS summary FROM O_InItem ORDER BY ID'

# FINISHED_OUT finished-goods outbound (O_Out: ClientID, Total; item Price/Total, OutNo)
$whFinishedOutMain = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, StockID AS stock_legacy_id, 0 AS to_stock_legacy_id, ClientID AS client_legacy_id, 0 AS supplier_legacy_id, WorkerID AS worker_legacy, MakeID AS maker_legacy, ApproverID AS approver_legacy, NULL AS plan_no, NULL AS bill_type, Remark AS remark, Total AS total_original, Status AS status, Cancel AS cancel_bit FROM O_Out ORDER BY ID'
$whFinishedOutItem = 'SELECT ID AS legacy_id, BillID AS bill_legacy_id, GoodsID AS goods_legacy_id, ColorID AS color_legacy_id, QTY AS qty, Price AS price, Total AS amount, UnitID AS unit_legacy_id, URate AS unit_rate, Weight AS weight, NULL AS surplus_qty, NULL AS count_qty, 0 AS place_legacy_id, 0 AS upstream_legacy_id, OutNo AS source_doc_no, Summary AS summary FROM O_OutItem ORDER BY ID'

# CHECK stocktaking (O_Check; item NowQTY actual / SurplusQTY diff / Reason)
$whCheckMain = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, StockID AS stock_legacy_id, 0 AS to_stock_legacy_id, 0 AS client_legacy_id, 0 AS supplier_legacy_id, 0 AS worker_legacy, MakeID AS maker_legacy, ApproverID AS approver_legacy, NULL AS plan_no, NULL AS bill_type, Remark AS remark, NULL AS total_original, Status AS status, Cancel AS cancel_bit FROM O_Check ORDER BY ID'
$whCheckItem = 'SELECT ID AS legacy_id, BillID AS bill_legacy_id, GoodsID AS goods_legacy_id, ColorID AS color_legacy_id, QTY AS qty, NULL AS price, STotal AS amount, UnitID AS unit_legacy_id, URate AS unit_rate, Weight AS weight, SurplusQTY AS surplus_qty, NowQTY AS count_qty, StorgePlace AS place_legacy_id, 0 AS upstream_legacy_id, NULL AS source_doc_no, Reason AS summary FROM O_CheckItem ORDER BY ID'

# StockGoods ledger (rebuild stock_balances opening; sg_stage: stock_legacy,goods_legacy,color_legacy,year,qty,total)
$whStockGoods = 'SELECT StockID AS stock_legacy, GoodsID AS goods_legacy, ColorID AS color_legacy, Year AS year, QTY AS qty, Total AS total FROM StockGoods ORDER BY StockID, GoodsID, ColorID, Year'

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
    'CurrencyData'    { Export-Query -Sql $currencyDataSql -OutPath (Join-Path $dataDir 'currency.csv') }
    'WarehouseData'   { Export-Query -Sql $warehouseDataSql -OutPath (Join-Path $dataDir 'warehouse.csv') }
    'PurchaseApplication' {
        Export-Query -Sql $purchaseApplicationSql     -OutPath (Join-Path $dataDir 'purchase_applications.csv')
        Export-Query -Sql $purchaseApplicationItemSql -OutPath (Join-Path $dataDir 'purchase_application_items.csv')
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
    }
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
    }
}
