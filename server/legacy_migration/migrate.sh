#!/usr/bin/env bash
# =====================================================================
# 老库数据一键迁移（不启动 server）
# =====================================================================
# 跑这个脚本就把老库数据迁进新库 PostgreSQL，跑完再开 server 测前端。
#
# 用法：
#   bash server/legacy_migration/migrate.sh              # 迁全部已实现模块
#   bash server/legacy_migration/migrate.sh --goods      # 只迁货品分类
#   bash server/legacy_migration/migrate.sh --mould      # 只迁模具分类
#   bash server/legacy_migration/migrate.sh --mould-data # 只迁模具主档
#   bash server/legacy_migration/migrate.sh --purchase   # 只迁采购四单据
#   bash server/legacy_migration/migrate.sh --stock-docs # 只迁仓库管理 9 单据 + 台账余额
#   bash server/legacy_migration/migrate.sh --sales      # 只迁销售五单据（报价/订货+BOM/出货/其它出货/退货）
#   bash server/legacy_migration/migrate.sh --subcontract # 只迁委外八单据（询价/申请/订单+BOM/入库/发料/退料/次品退/废料）
#   bash server/legacy_migration/migrate.sh --production # 只迁生产（F_Plan/F_PlanItem/F_PlanCostItem/F_DateReport，依赖 --sales 先迁）
#   bash server/legacy_migration/migrate.sh --finance    # 只迁钱流（账户/付款方式 + AR/AP + 收支/对账）
#
# 当前已实现：货品/模具/客户/供应商（分类+主档）、颜色/单位/币种/仓库主档、采购四单据、
#   仓库管理 9 单据（统一 stock_documents + 台账余额 + 流水）、销售五单据（含 BOM 成本子表）、
#   委外八单据（含 BOM 成本子表）、生产（F_Plan 系列 + 日报）、钱流（账户/付款方式 + AR/AP 总账 +
#   收支/对账）。依赖顺序：主档 -> 采购 -> 仓库 -> 销售 -> 委外 -> 生产 -> 钱流
#   （production 依赖 sales_order_items 已迁，跨模块 FK 映射 sales_order_item_id）。
#   新增模块时在下方加 case + 对应 .sql。
#
# 依赖：docker（PG 容器在跑）。CSV 是老库快照（更新老库数据后重新导出 CSV 即可）。
# =====================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CONTAINER="${PG_CONTAINER:-uten-imp-postgres}"
PG_USER="${PG_USER:-uten}"
PG_DB="${PG_DB:-uten_imp}"
TARGET="${1:---all}"

run_sql () {  # $1 = sql 文件名（HERE 下）
    docker exec -i "$CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=1 < "$HERE/$1"
}

copy_csv () {  # $1 = csv 文件名（HERE/data 下）；自动去 CRLF（Windows 导出兼容）
    docker cp "$HERE/data/$1" "$CONTAINER:/tmp/$1"
    docker exec "$CONTAINER" sh -c "tr -d '\r' < /tmp/$1 > /tmp/$1.lf && mv /tmp/$1.lf /tmp/$1" 2>/dev/null || true
}

migrate_goods () {
    echo "→ [货品分类] 复制 CSV..."
    copy_csv goods_categories.csv
    echo "→ [货品分类] 执行迁移 SQL..."
    run_sql migrate_goods.sql
}

migrate_goods_data () {
    echo "→ [货品主档] 复制 CSV..."
    copy_csv goods.csv
    echo "→ [货品主档] 执行迁移 SQL..."
    run_sql migrate_goods_data.sql
}

migrate_mould () {
    echo "→ [模具分类] 复制 CSV..."
    copy_csv mould_categories.csv
    echo "→ [模具分类] 执行迁移 SQL..."
    run_sql migrate_mould.sql
}

migrate_mould_data () {
    echo "→ [模具主档] 复制 CSV..."
    copy_csv mould.csv
    echo "→ [模具主档] 执行迁移 SQL..."
    run_sql migrate_mould_data.sql
}

migrate_client () {
    echo "→ [客户分类] 复制 CSV..."
    copy_csv client_categories.csv
    echo "→ [客户分类] 执行迁移 SQL..."
    run_sql migrate_client.sql
}

migrate_client_data () {
    echo "→ [客户主档] 复制 CSV..."
    copy_csv client.csv
    echo "→ [客户主档] 执行迁移 SQL..."
    run_sql migrate_client_data.sql
}

migrate_supplier () {
    echo "→ [供应商分类] 复制 CSV..."
    copy_csv supplier_categories.csv
    echo "→ [供应商分类] 执行迁移 SQL..."
    run_sql migrate_supplier.sql
}

migrate_supplier_data () {
    echo "→ [供应商主档] 复制 CSV..."
    copy_csv supplier.csv
    echo "→ [供应商主档] 执行迁移 SQL..."
    run_sql migrate_supplier_data.sql
}

migrate_color_data () {
    echo "→ [颜色主档] 复制 CSV..."
    copy_csv color.csv
    echo "→ [颜色主档] 执行迁移 SQL..."
    run_sql migrate_color.sql
}

migrate_unit_data () {
    echo "→ [基本单位主档] 复制 CSV..."
    copy_csv unit.csv
    echo "→ [基本单位主档] 执行迁移 SQL..."
    run_sql migrate_unit.sql
}

migrate_currency_data () {
    echo "→ [币种主档] 复制 CSV..."
    copy_csv currency.csv
    echo "→ [币种主档] 执行迁移 SQL..."
    run_sql migrate_currency.sql
}

migrate_warehouse_data () {
    echo "→ [仓库主档] 复制 CSV..."
    copy_csv warehouse.csv
    echo "→ [仓库主档] 执行迁移 SQL..."
    run_sql migrate_warehouse.sql
}

migrate_purchase () {
    echo "→ [采购四单据] 复制 CSV（8 个）..."
    for f in purchase_applications purchase_application_items \
             purchase_orders purchase_order_items \
             purchase_receipts purchase_receipt_items \
             purchase_returns purchase_return_items; do
        copy_csv "$f.csv"
    done
    echo "→ [采购四单据] 执行迁移 SQL..."
    run_sql migrate_purchase.sql
}

# 仓库管理 9 单据（统一 stock_documents）+ StockGoods 台账余额 + 仓库流水回填。
# 依赖：主档（goods/colors/units/suppliers/clients/warehouses）+ 采购已迁（采购单据可选，
#   本脚本独立清/建 stock_documents + stock_balances，与采购表无外键耦合）。
migrate_stock_docs () {
    echo "→ [仓库单据] 复制 CSV（17 个：8 单据主/明 + StockGoods + 人员参考）..."
    for f in stock_transfer_m stock_transfer_i \
             stock_other_in_m stock_other_in_i \
             stock_other_out_m stock_other_out_i \
             stock_draw_m stock_draw_i \
             stock_wdraw_m stock_wdraw_i \
             stock_finished_in_m stock_finished_in_i \
             stock_finished_out_m stock_finished_out_i \
             stock_check_m stock_check_i \
             stock_goods \
             legacy_workers; do
        copy_csv "$f.csv"
    done
    echo "→ [仓库单据] 执行迁移 SQL（统一表 + 余额 + 流水 + 人员补录）..."
    run_sql migrate_stock_docs.sql
}

# 销售五单据：报价 / 订货(+BOM 成本) / 出货 / 其它出货 / 退货（11 张表，含明细 + BOM 子表）。
# 依赖：主档（goods/colors/units/warehouses/currencies/clients）已迁。
# 幂等：开头一次性 TRUNCATE 11 张销售表（按被引用关系一起清），重跑安全。
migrate_sales () {
    echo "→ [销售五单据] 复制 CSV（11 个）..."
    for f in sales_quotes sales_quote_items \
             sales_orders sales_order_items sales_order_cost_items \
             sales_shipments sales_shipment_items \
             sales_other_shipments sales_other_shipment_items \
             sales_returns sales_return_items; do
        copy_csv "$f.csv"
    done
    echo "→ [销售五单据] 执行迁移 SQL..."
    run_sql migrate_sales.sql
}

# 委外（outsourcing）八单据：询价 / 申请 / 订单(+BOM) / 入库 / 发料 / 退料 / 次品退 / 废料
#   （17 张表 = 8 main + 8 item + 1 BOM cost）。
# 依赖：主档已迁；与采购/仓库无 FK 耦合（仅 stock_movements 类型命名空间共享）。
migrate_subcontract () {
    echo "→ [委外八单据] 复制 CSV（17 个）..."
    for f in subcontract_ask_m subcontract_ask_i \
             subcontract_application_m subcontract_application_i \
             subcontract_order_m subcontract_order_i subcontract_order_cost_i \
             subcontract_in_m subcontract_in_i \
             subcontract_sout_m subcontract_sout_i \
             subcontract_withdraw_m subcontract_withdraw_i \
             subcontract_swithdraw_m subcontract_swithdraw_i \
             subcontract_swaste_m subcontract_swaste_i; do
        copy_csv "$f.csv"
    done
    echo "→ [委外八单据] 执行迁移 SQL..."
    run_sql migrate_subcontract.sql
}

# 生产模块：F_Plan / F_PlanItem / F_PlanCostItem / F_DateReport / F_DateReportItem。
# 依赖：主档 + V51 sales_order_items / sales_order_cost_items（销售必须先迁，
#   跨模块 FK 映射 sales_order_item_id；F_PlanItem.S_OrderID 经 legacy_id 子查询映射）。
# production_plan_costs 按年度分区（13 个 + DEFAULT 兜底）；TRUNCATE 父表自动级联所有子分区。
migrate_production () {
    echo "→ [生产模块] 复制 CSV（5 个）..."
    for f in production_plans production_plan_items production_plan_costs \
             production_daily_reports production_daily_report_items; do
        copy_csv "$f.csv"
    done
    echo "→ [生产模块] 执行迁移 SQL..."
    run_sql migrate_production.sql
}

# 钱流模块：账户（accounts）+ 付款方式（payment_styles）+ AR/AP 总账（ar_ap_ledger，
#   M_in/M_out 双向）+ 收支单据（finance_receipts/payments/expenses/other_incomes）
#   + 对账（finance_reconciliations）。M_Bank legacy 0 行，结构在 V57 已建，本期不迁。
# 依赖：主档（clients/suppliers/currencies）已迁；与销售/采购/委外独立（按 BillNo 前缀溯源）。
migrate_finance () {
    echo "→ [钱流模块] 复制 CSV（11 个）..."
    for f in m_acc m_style m_in m_out m_get m_paid \
             m_dpaid m_dpaid_item m_oget m_oget_item m_allcheck; do
        copy_csv "$f.csv"
    done
    echo "→ [钱流模块] 执行迁移 SQL..."
    run_sql migrate_finance.sql
}

case "$TARGET" in
    --goods|-g) migrate_goods ;;
    --goods-data) migrate_goods_data ;;
    --mould|-m) migrate_mould ;;
    --mould-data) migrate_mould_data ;;
    --client) migrate_client ;;
    --client-data) migrate_client_data ;;
    --supplier) migrate_supplier ;;
    --supplier-data) migrate_supplier_data ;;
    --color-data) migrate_color_data ;;
    --unit-data) migrate_unit_data ;;
    --currency-data) migrate_currency_data ;;
    --warehouse-data) migrate_warehouse_data ;;
    --purchase) migrate_purchase ;;
    --stock-docs) migrate_stock_docs ;;
    --sales) migrate_sales ;;
    --subcontract) migrate_subcontract ;;
    --production) migrate_production ;;
    --finance) migrate_finance ;;
    --all|-a|*)
        migrate_goods
        migrate_goods_data
        migrate_mould
        migrate_mould_data
        migrate_client
        migrate_client_data
        migrate_supplier
        migrate_supplier_data
        migrate_color_data
        migrate_unit_data
        migrate_currency_data
        migrate_warehouse_data
        migrate_purchase
        migrate_stock_docs
        migrate_sales
        migrate_subcontract
        migrate_production
        migrate_finance
        ;;
esac

echo ""
echo "✔ 全部迁移完成。现在可以启动 server 测试前端了。"
