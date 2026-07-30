# =====================================================================
# Subcontract (E_*) export snippet -- paste into export_legacy.ps1
# =====================================================================
# Exports the 8 subcontract document tables (E_Ask / E_Application / E_Order
# / E_In / E_SOut / E_WithDraw / E_SWithDraw / E_SWaste) plus their item
# tables and the BOM cost sub-table (E_OrderCostItem) -> 17 CSVs total, one
# row per table.
#
# Source: legacy DB YTDQ_2023 (LocalDB), E_* tables (outsourcing module).
# Output: data/subcontract_*.csv (UTF-8, pipe-delimited, RFC4180-quoted).
# Consumed by: migrate_subcontract.sql (\copy FROM '/tmp/subcontract_*.csv').
#
# IMPORTANT (Windows PowerShell 5.1): keep this file ASCII-only. PS 5.1 reads
# a no-BOM .ps1 as the system ANSI codepage (CP936 here); non-ASCII bytes in
# comments/strings can swallow quotes and silently break parsing. If you add
# Chinese, save the file as UTF-8 *with BOM*.
#
# Integration into export_legacy.ps1 (3 edits):
#   1. Add 'SubcontractData' to the [ValidateSet(...)] at the top param().
#   2. Paste all $subXxxSql variables below alongside the existing $xxxSql.
#   3. Paste the 'SubcontractData' branch into the switch ($Target) { ... }.
#   4. (Optional) Add the 17 Export-Query lines into the 'All' branch.
#
# Single-quote escaping: PS single-quoted strings use '' for an embedded
# single-quote. SQL Server CONCAT_WS + NULLIF(col, '') collapses the legacy
# multi-value varchar columns (BomItemID / EOrderNo / SOrderNo / PlanNo /
# EInNo / ESONo / ESWNo / *DrawNo / InNo / OrderNo / OutNo / SendNo / etc.)
# into a single source_doc_no text column.
#
# Reserved-word bracketing: [Status] / [Stop] / [Cancel] / [Level] / [Class]
# are T-SQL keywords; bracket them where they appear as column names.
#
# Row counts (expected, from biz_all_tables_rowcount.txt):
#   E_Ask 0 / E_AskItem 0
#   E_Application 0 / E_ApplicationItem 0
#   E_Order 2 / E_OrderItem 5 / E_OrderCostItem 67
#   E_In 10732 / E_InItem 39093
#   E_SOut 10627 / E_SOutItem 49889
#   E_WithDraw 442 / E_WithDrawItem 1649
#   E_SWithDraw 65 / E_SWithDrawItem 112
#   E_SWaste 3 / E_SWasteItem 3
# =====================================================================

# ---- SQL as single-line single-quoted strings (no here-strings, no '' literals
#      other than the doubled-quote escape). Column order MUST match the
#      staging tables in migrate_subcontract.sql. ----

# 1. E_Ask (0 rows; structure only; no Fulfill column in this table)
$subAskSql     = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, VendID AS supplier_legacy_id, MakeID AS maker_legacy, ApproverID AS approver_legacy, [Status] AS status, Total AS total_original, [Stop] AS stop_bit, Cancel AS cancel_bit, Remark AS remark FROM E_Ask ORDER BY ID'
$subAskItemSql = 'SELECT ID AS legacy_id, BillID AS bill_legacy_id, GoodsID AS goods_legacy_id, ColorID AS color_legacy_id, UnitID AS unit_legacy_id, URate AS unit_rate, Price AS price, Summary AS summary FROM E_AskItem ORDER BY ID'

# 2. E_Application (0 rows; structure only)
$subApplicationSql     = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, VendID AS supplier_legacy_id, SenderID AS sender_legacy, MakeID AS maker_legacy, ApproverID AS approver_legacy, Last_Date AS last_date, CurID AS currency_legacy_id, CRate AS exchange_rate, TRate AS tax_rate, [Status] AS status, Total AS total_original, Cancel AS cancel_bit, Remark AS remark FROM E_Application ORDER BY ID'
$subApplicationItemSql = 'SELECT ID AS legacy_id, BillID AS bill_legacy_id, GoodsID AS goods_legacy_id, ColorID AS color_legacy_id, QTY AS qty, Price AS price, Total AS amount_original, OrderID AS order_item_legacy_id, UnitID AS unit_legacy_id, URate AS unit_rate, CQTY AS check_qty, Weight AS weight, NULLIF(CONCAT_WS('' | '', NULLIF(SOrderNo, ''''), NULLIF(PlanNo, ''''), NULLIF(BomItemID, ''''), NULLIF(OrderNo, '''')), '''') AS source_doc_no FROM E_ApplicationItem ORDER BY ID'

# 3. E_Order (2 rows) + E_OrderItem (5) + E_OrderCostItem (67)
$subOrderSql         = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, VendID AS supplier_legacy_id, SendDate AS deliver_date, SendID AS send_legacy, MakeID AS maker_legacy, ApproverID AS approver_legacy, Fulfill AS fulfill_bit, [Stop] AS stop_bit, CurID AS currency_legacy_id, CRate AS exchange_rate, TRate AS tax_rate, Total AS total_original, [Status] AS status, Cancel AS cancel_bit, Remark AS remark FROM E_Order ORDER BY ID'
$subOrderItemSql     = 'SELECT ID AS legacy_id, BillID AS bill_legacy_id, GoodsID AS goods_legacy_id, ColorID AS color_legacy_id, UnitID AS unit_legacy_id, URate AS unit_rate, QTY AS qty, Price AS price, Total AS amount_original, IQTY AS received_qty, OQTY AS issued_qty, WQTY AS returned_qty, Weight AS weight, NULLIF(CONCAT_WS('' | '', NULLIF(ESONo, ''''), NULLIF(ESWNo, ''''), NULLIF(EInNo, ''''), NULLIF(SWDrawNo, ''''), NULLIF(SOrderNo, ''''), NULLIF(PlanNo, ''''), NULLIF(BomItemID, '''')), '''') AS source_doc_no FROM E_OrderItem ORDER BY ID'
$subOrderCostItemSql = 'SELECT ID AS legacy_id, BillID AS bill_legacy_id, GoodsID AS goods_legacy_id, ColorID AS color_legacy_id, QTY AS qty, MGoodsID AS m_goods_legacy_id, MColorID AS m_color_legacy_id, ParentID AS parent_legacy_id, DQTY AS unit_qty, SQTY AS issued_qty, WQTY AS returned_qty, [Class] AS line_class, [Level] AS bom_level, NULLIF(CONCAT_WS('' | '', NULLIF(SendNo, ''''), NULLIF(WDrawNo, '''')), '''') AS source_doc_no FROM E_OrderCostItem ORDER BY ID'

# 4. E_In (10732 rows; largest main table)
$subInSql     = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, VendID AS supplier_legacy_id, StockID AS warehouse_legacy_id, SenderID AS sender_legacy, MakeID AS maker_legacy, ApproverID AS approver_legacy, Last_Date AS last_date, CurID AS currency_legacy_id, CRate AS exchange_rate, TRate AS tax_rate, Total AS total_original, [Status] AS status, Cancel AS cancel_bit, Remark AS remark FROM E_In ORDER BY ID'
$subInItemSql = 'SELECT ID AS legacy_id, BillID AS bill_legacy_id, GoodsID AS goods_legacy_id, ColorID AS color_legacy_id, QTY AS qty, Price AS price, Total AS amount_original, OrderID AS order_item_legacy_id, UnitID AS unit_legacy_id, URate AS unit_rate, STotal AS amount_local, CQTY AS check_qty, OrderQTY AS order_qty, WQTY AS returned_qty, Weight AS weight, NULLIF(CONCAT_WS('' | '', NULLIF(EWDrawNo, ''''), NULLIF(OrderNo, ''''), NULLIF(SOrderNo, ''''), NULLIF(PlanNo, ''''), NULLIF(BomItemID, '''')), '''') AS source_doc_no FROM E_InItem ORDER BY ID'

# 5. E_SOut (10627 rows; no currency/Total/Price -- materials issued at cost)
$subSOutSql     = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, VendID AS supplier_legacy_id, StockID AS warehouse_legacy_id, WorkID AS worker_legacy, MakeID AS maker_legacy, ApproverID AS approver_legacy, SendDate AS deliver_date, [Status] AS status, Cancel AS cancel_bit, Remark AS remark FROM E_SOut ORDER BY ID'
$subSOutItemSql = 'SELECT ID AS legacy_id, BillID AS bill_legacy_id, GoodsID AS goods_legacy_id, ColorID AS color_legacy_id, UnitID AS unit_legacy_id, URate AS unit_rate, QTY AS qty, STQTY AS stqty, EOrderID AS order_item_legacy_id, STotal AS amount_local, WQTY AS returned_qty, MGoodsID AS parent_goods_legacy_id, MColorID AS parent_color_legacy_id, Weight AS weight, NULLIF(CONCAT_WS('' | '', NULLIF(BomItemID, ''''), NULLIF(EOrderNo, ''''), NULLIF(WDrawNo, '''')), '''') AS source_doc_no FROM E_SOutItem ORDER BY ID'

# 6. E_WithDraw (442 rows; no TRate column)
$subWithdrawSql     = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, VendID AS supplier_legacy_id, StockID AS warehouse_legacy_id, MakeID AS maker_legacy, ApproverID AS approver_legacy, Last_Date AS last_date, CurID AS currency_legacy_id, CRate AS exchange_rate, Total AS total_original, [Status] AS status, Cancel AS cancel_bit, Remark AS remark FROM E_WithDraw ORDER BY ID'
$subWithdrawItemSql = 'SELECT ID AS legacy_id, BillID AS bill_legacy_id, GoodsID AS goods_legacy_id, ColorID AS color_legacy_id, QTY AS qty, Price AS price, Total AS amount_original, InID AS receipt_item_legacy_id, OrderID AS order_item_legacy_id, UnitID AS unit_legacy_id, URate AS unit_rate, STotal AS amount_local, Weight AS weight, NULLIF(CONCAT_WS('' | '', NULLIF(InNo, ''''), NULLIF(OrderNo, ''''), NULLIF(SOrderNo, ''''), NULLIF(PlanNo, ''''), NULLIF(BomItemID, '''')), '''') AS source_doc_no FROM E_WithDrawItem ORDER BY ID'

# 7. E_SWithDraw (65 rows; no currency/Total)
$subSWithdrawSql     = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, VendID AS supplier_legacy_id, StockID AS warehouse_legacy_id, WorkID AS worker_legacy, MakeID AS maker_legacy, ApproverID AS approver_legacy, BStyle AS b_style, [Status] AS status, Cancel AS cancel_bit, Remark AS remark FROM E_SWithDraw ORDER BY ID'
$subSWithdrawItemSql = 'SELECT ID AS legacy_id, BillID AS bill_legacy_id, GoodsID AS goods_legacy_id, ColorID AS color_legacy_id, UnitID AS unit_legacy_id, URate AS unit_rate, QTY AS qty, EOutID AS material_issue_item_legacy_id, EOrderID AS order_item_legacy_id, STotal AS amount_local, MGoodsID AS parent_goods_legacy_id, MColorID AS parent_color_legacy_id, Weight AS weight, NULLIF(CONCAT_WS('' | '', NULLIF(EOutNo, ''''), NULLIF(EOrderNo, ''''), NULLIF(BomItemID, ''''), NULLIF(SWasteNo, '''')), '''') AS source_doc_no FROM E_SWithDrawItem ORDER BY ID'

# 8. E_SWaste (3 rows; with waste_rate/cause/Weight)
$subSWasteSql     = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, VendID AS supplier_legacy_id, StockID AS warehouse_legacy_id, WorkerID AS worker_legacy, MakeID AS maker_legacy, ApproverID AS approver_legacy, Weight AS total_weight, [Status] AS status, Cancel AS cancel_bit, Remark AS remark FROM E_SWaste ORDER BY ID'
$subSWasteItemSql = 'SELECT ID AS legacy_id, BillID AS bill_legacy_id, GoodsID AS goods_legacy_id, ColorID AS color_legacy_id, UnitID AS unit_legacy_id, URate AS unit_rate, QTY AS qty, FQTY AS ending_qty, OQTY AS standard_qty, WRate AS waste_rate, Cause AS cause, OutID AS material_issue_item_legacy_id, STotal AS amount_local, Weight AS weight, NULLIF(CONCAT_WS('' | '', NULLIF(OutNo, ''''), NULLIF(WDrawNo, ''''), NULLIF(EOrderNo, '''')), '''') AS source_doc_no FROM E_SWasteItem ORDER BY ID'

switch ($Target) {
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
    }
}
