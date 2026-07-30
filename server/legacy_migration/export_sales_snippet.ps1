# =====================================================================
# Sales-module export snippet (merge into export_legacy.ps1)
# =====================================================================
# Exports 11 S_* legacy tables (5 doc mains + 5 item tables + 1 BOM
# cost-items table) to data/sales_*.csv for migrate_sales.sql \copy.
#
# ASCII-only (Windows PowerShell 5.1 / CP936 safe). Per-table SQL is a
# single-line single-quoted string; column aliases match migrate_sales.sql
# staging column order WORD-FOR-WORD (do not reorder). Multi-value source
# columns (InNo/PlanNo/OutNo/SWDrawNo/POrderNo/...) are NOT merged here --
# they are kept as individual staging columns and CONCAT_WS'd in the
# migrate SQL so the raw values stay debuggable in CSV.
#
# This file is a SNIPPET. To activate, do the three merges below in
# export_legacy.ps1 (see also docs/data-migration/20 section 7.1).
# =====================================================================

# ---------------------------------------------------------------------
# MERGE 1 - add to param [ValidateSet(...)] at top of export_legacy.ps1:
# ---------------------------------------------------------------------
#   'SalesQuote', 'SalesOrder', 'SalesShipment', 'SalesOtherShipment',
#   'SalesReturn', 'SalesDocs',
# (SalesDocs = all 11 CSVs in one run; the five per-doc targets export
#  just that doc's main + items, useful for partial re-runs.)

# ---------------------------------------------------------------------
# MERGE 2 - SQL variables (paste after the warehouse section, before the
# switch block). Column order MUST match migrate_sales.sql staging.
# ---------------------------------------------------------------------

# S_Quote (0 rows in legacy; structure-only export keeps \copy idempotent).
$salesQuoteSql      = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, ClientID AS client_legacy, MakeID AS maker_legacy, ApproverID AS approver_legacy, [Stop] AS stop_bit, Remark AS remark, Total AS total_original, Status AS status, Status2 AS status2 FROM S_Quote ORDER BY ID'
$salesQuoteItemSql  = 'SELECT ID AS legacy_id, BillID AS bill_legacy, GoodsID AS goods_legacy, ColorID AS color_legacy, UnitID AS unit_legacy, URate AS unit_rate, BQTY AS qty, Price AS price, SPrice AS sprice, Summary AS remark FROM S_QuoteItem ORDER BY ID'

# S_Order / S_OrderItem / S_OrderCostItem.
# Note: S_Order.SStyle -> ship_addr (design doc: SStyle = shipping place, varchar(5000)).
#       S_Order.BillStyle skipped (template name, not in V51 schema).
#       [Level] / [Stop] bracketed as T-SQL reserved.
$salesOrderSql      = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, ClientID AS client_legacy, SendDate AS deliver_date, LinkPhone AS link_phone, SignAddr AS sign_addr, ContractNo AS contract_no, SellerID AS seller_legacy, PStyle AS p_style, MakeID AS maker_legacy, ApproverID AS approver_legacy, Remark AS remark, Total AS total_original, Status AS status, Fulfill AS fulfill_bit, [Stop] AS stop_bit, SStyle AS ship_addr, Deposit AS deposit, CurID AS cur_legacy, TRate AS tax_rate, CRate AS exchange_rate, Cancel AS cancel_bit, ClientNo AS client_no FROM S_Order ORDER BY ID'
$salesOrderItemSql  = 'SELECT ID AS legacy_id, BillID AS bill_legacy, GoodsID AS goods_legacy, ColorID AS color_legacy, QTY AS qty, Price AS price, Total AS amount_original, RQTY AS shipped_qty, WQTY AS returned_qty, FlagQTY AS flag_qty, Discount AS discount, TTotal AS tax_amount, UnitID AS unit_legacy, URate AS unit_rate, Weight AS weight, NULL AS client_no, CNumber AS client_model, InNo AS in_no, PlanNo AS plan_no, OutNo AS out_no, SWDrawNo AS swdraw_no, Summary AS remark, IQTY AS inbound_qty, KQTY2 AS circumference, SPrice AS material_price, WPrice AS die_cast_price, JPrice AS machining_price FROM S_OrderItem ORDER BY ID'
$salesOrderCostSql  = 'SELECT ID AS legacy_id, BillID AS bill_legacy, ParentID AS parent_legacy, [Level] AS level, Class AS class_code, GoodsID AS goods_legacy, ColorID AS color_legacy, MGoodsID AS alt_goods_legacy, MColorID AS alt_color_legacy, QTY AS qty, Price AS price, Total AS amount_original, OrderQTY AS order_qty, INQTY AS received_qty, PDrawQTY AS draw_qty, PWDrawQTY AS purge_qty, OWDrawQTY AS other_draw_qty, VendID AS supplier_legacy, LStatus AS l_status, POrderNo AS porder_no, PDrawNo AS pdraw_no, PInNo AS pin_no, PWDrawNo AS pwdraw_no, OWDrawNo AS owdraw_no, Summary AS remark FROM S_OrderCostItem ORDER BY ID'

# S_Out / S_OutItem (main volume: 12124 main / 90948 items).
# Note: KQTY -> parcel_qty, Boxs -> carton_count, STotal -> cost_amount,
#       WQTY/SWTotal -> returned_qty/returned_amount (history written back).
$salesOutSql        = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, ClientID AS client_legacy, StockID AS warehouse_legacy, LinkPhone AS link_phone, PCount AS p_count, SenderID AS sender_legacy, ShipAddr AS ship_addr, PStyle AS p_style, MakeID AS maker_legacy, ApproverID AS approver_legacy, Remark AS remark, Total AS total_original, Status AS status, PrintTable AS print_count, Last_Date AS last_date, TRate AS tax_rate, CurID AS cur_legacy, CRate AS exchange_rate, SellerID AS seller_legacy, Cancel AS cancel_bit FROM S_Out ORDER BY ID'
$salesOutItemSql    = 'SELECT ID AS legacy_id, BillID AS bill_legacy, GoodsID AS goods_legacy, ColorID AS color_legacy, QTY AS qty, Price AS price, Total AS amount_original, OrderID AS order_item_legacy, STotal AS cost_amount, WQTY AS returned_qty, SWDrawNo AS swdraw_no, OrderNo AS order_no, UnitID AS unit_legacy, URate AS unit_rate, SWTotal AS returned_amount, Discount AS discount, TTotal AS tax_amount, Boxs AS carton_count, KQTY AS parcel_qty, Weight AS weight, ClientNo AS client_no, CNumber AS client_model, Summary AS remark, KQTY2 AS circumference, SPrice AS material_price, WPrice AS die_cast_price, JPrice AS machining_price FROM S_OutItem ORDER BY ID'

# S_OtherOut / S_OtherOutItem (same column shape as S_Out / S_OutItem).
$salesOtherOutSql   = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, ClientID AS client_legacy, StockID AS warehouse_legacy, LinkPhone AS link_phone, PCount AS p_count, SenderID AS sender_legacy, ShipAddr AS ship_addr, PStyle AS p_style, MakeID AS maker_legacy, ApproverID AS approver_legacy, Remark AS remark, Total AS total_original, Status AS status, PrintTable AS print_count, Last_Date AS last_date, TRate AS tax_rate, CurID AS cur_legacy, CRate AS exchange_rate, SellerID AS seller_legacy, Cancel AS cancel_bit FROM S_OtherOut ORDER BY ID'
$salesOtherOutItemSql = 'SELECT ID AS legacy_id, BillID AS bill_legacy, GoodsID AS goods_legacy, ColorID AS color_legacy, QTY AS qty, Price AS price, Total AS amount_original, OrderID AS order_item_legacy, STotal AS cost_amount, WQTY AS returned_qty, SWDrawNo AS swdraw_no, OrderNo AS order_no, UnitID AS unit_legacy, URate AS unit_rate, SWTotal AS returned_amount, Discount AS discount, TTotal AS tax_amount, Boxs AS carton_count, KQTY AS parcel_qty, Weight AS weight, ClientNo AS client_no, CNumber AS client_model, Summary AS remark, KQTY2 AS circumference, SPrice AS material_price, WPrice AS die_cast_price, JPrice AS machining_price FROM S_OtherOutItem ORDER BY ID'

# S_Withdraw / S_WithdrawItem (no TRate / SendDate / ShipAddr / SenderID).
# Item-only columns: OutNo + SOrderNo (source text); OutID + OrderID (real FKs);
#                    qlfa -> solution, zrdw -> responsible.
$salesWithdrawSql   = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, ClientID AS client_legacy, StockID AS warehouse_legacy, PStyle AS p_style, MakeID AS maker_legacy, ApproverID AS approver_legacy, Remark AS remark, Total AS total_original, Status AS status, Last_Date AS last_date, CurID AS cur_legacy, CRate AS exchange_rate, SellerID AS seller_legacy, Cancel AS cancel_bit FROM S_Withdraw ORDER BY ID'
$salesWithdrawItemSql = 'SELECT ID AS legacy_id, BillID AS bill_legacy, GoodsID AS goods_legacy, ColorID AS color_legacy, QTY AS qty, Price AS price, Total AS amount_original, OutNo AS out_no, OutID AS out_item_legacy, OrderID AS order_item_legacy, SOrderNo AS sorder_no, UnitID AS unit_legacy, URate AS unit_rate, Weight AS weight, KQTY AS parcel_qty, Boxs AS carton_count, Discount AS discount, STotal AS cost_amount, CNumber AS client_model, qlfa AS solution, zrdw AS responsible, Summary AS remark FROM S_WithdrawItem ORDER BY ID'

# ---------------------------------------------------------------------
# MERGE 3 - switch cases (paste into the existing switch ($Target) block,
# before the 'All' case). Filenames match migrate_sales.sql \copy paths.
# ---------------------------------------------------------------------

switch ($Target) {
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
}

# ---------------------------------------------------------------------
# MERGE 4 (optional) - paste into the 'All' case in export_legacy.ps1,
# right before the warehouse-docs section closes:
# ---------------------------------------------------------------------
#    Export-Query -Sql $salesQuoteSql         -OutPath (Join-Path $dataDir 'sales_quotes.csv')
#    Export-Query -Sql $salesQuoteItemSql     -OutPath (Join-Path $dataDir 'sales_quote_items.csv')
#    Export-Query -Sql $salesOrderSql         -OutPath (Join-Path $dataDir 'sales_orders.csv')
#    Export-Query -Sql $salesOrderItemSql     -OutPath (Join-Path $dataDir 'sales_order_items.csv')
#    Export-Query -Sql $salesOrderCostSql     -OutPath (Join-Path $dataDir 'sales_order_cost_items.csv')
#    Export-Query -Sql $salesOutSql           -OutPath (Join-Path $dataDir 'sales_shipments.csv')
#    Export-Query -Sql $salesOutItemSql       -OutPath (Join-Path $dataDir 'sales_shipment_items.csv')
#    Export-Query -Sql $salesOtherOutSql      -OutPath (Join-Path $dataDir 'sales_other_shipments.csv')
#    Export-Query -Sql $salesOtherOutItemSql  -OutPath (Join-Path $dataDir 'sales_other_shipment_items.csv')
#    Export-Query -Sql $salesWithdrawSql      -OutPath (Join-Path $dataDir 'sales_returns.csv')
#    Export-Query -Sql $salesWithdrawItemSql  -OutPath (Join-Path $dataDir 'sales_return_items.csv')
