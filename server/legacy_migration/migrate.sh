#!/usr/bin/env bash
# =====================================================================
# 老库数据引导迁移（不启动 server）
# =====================================================================
# 这些 SQL 会重建目标模块数据，只能用于尚未切流模块的首次导入/演练。
# 已切流模块必须走增量迁移，不得再次运行本脚本。
#
# 用法：
#   # 无参数/未知参数只显示帮助并失败，不会执行任何迁移
#   bash server/legacy_migration/migrate.sh --goods      # 只迁货品分类
#   bash server/legacy_migration/migrate.sh --goods-bom  # 只迁货品组装信息（BOM → V79 goods_bom_items）
#   bash server/legacy_migration/migrate.sh --mould      # 只迁模具分类
#   bash server/legacy_migration/migrate.sh --mould-data # 只迁模具主档
#   bash server/legacy_migration/migrate.sh --purchase   # 只迁采购四单据
#   bash server/legacy_migration/migrate.sh --stock-docs # 只迁仓库管理 9 单据 + 台账余额
#   bash server/legacy_migration/migrate.sh --sales      # 只迁销售五单据（报价/订货+BOM/出货/其它出货/退货）
#   bash server/legacy_migration/migrate.sh --subcontract # 只迁委外八单据（询价/申请/订单+BOM/入库/发料/退料/次品退/废料）
#   bash server/legacy_migration/migrate.sh --production # 只迁生产（F_Plan/F_PlanItem/F_PlanCostItem/F_DateReport，依赖 --sales 先迁）
#   bash server/legacy_migration/migrate.sh --finance    # 只迁钱流（账户/付款方式 + AR/AP + 收支/对账）
#   bash server/legacy_migration/migrate.sh --hr-workers # 只迁人事老库（B_Worker 全量试迁，含加密敏感信息）
#   bash server/legacy_migration/migrate.sh --goods-owner # 只迁货品归属（外贸按人授权，V85）
#   bash server/legacy_migration/migrate.sh --client-owner # 只迁客户归属（业务员按人授权，V86）
#   UTEN_CONFIRM_DESTRUCTIVE_MIGRATION=RESET_uten_imp \
#     bash server/legacy_migration/migrate.sh --bootstrap-all
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
TARGET=""
CONFIRMED=0
# docker 可执行文件自动探测（Windows git bash 常不在 PATH，可用 DOCKER 环境变量覆盖）
DOCKER="${DOCKER:-$(command -v docker || command -v docker.exe || echo '/c/Program Files/Docker/Docker/resources/bin/docker.exe')}"
LOCK_DIR="/tmp/uten-legacy-migration.lock"
REMOTE_TMP_FILES=()
LOCAL_KEY_FILE=""
RUN_ID=""
RUN_STATUS="FAILED"

usage () {
    cat <<EOF
用法：
  bash server/legacy_migration/migrate.sh <目标> --confirm-destructive

目标：
  --goods | --goods-data | --goods-bom
  --mould | --mould-data
  --client | --client-data | --client-owner
  --supplier | --supplier-data
  --color-data | --unit-data | --currency-data | --warehouse-data
  --purchase | --stock-docs | --sales | --sales-owner
  --subcontract | --production | --finance | --hr-workers
  --goods-owner
  --bootstrap-all（兼容别名：--all、-a）

安全确认（二选一）：
  1. 第二个参数传 --confirm-destructive
  2. 环境变量 UTEN_CONFIRM_DESTRUCTIVE_MIGRATION=RESET_${PG_DB}

注意：这些迁移会 TRUNCATE/重建目标模块，只能用于首次导入或迁移演练。
EOF
}

for arg in "$@"; do
    case "$arg" in
        --help|-h)
            usage
            exit 0
            ;;
        --confirm-destructive)
            CONFIRMED=1
            ;;
        --goods|-g|--goods-data|--goods-owner|--goods-bom|\
        --mould|-m|--mould-data|--client|--client-data|--client-owner|\
        --supplier|--supplier-data|--color-data|--unit-data|--currency-data|\
        --warehouse-data|--purchase|--stock-docs|--sales|--sales-owner|\
        --subcontract|--production|--finance|--hr-workers|\
        --bootstrap-all|--all|-a)
            if [ -n "$TARGET" ]; then
                echo "✗ 一次只能执行一个迁移目标：$TARGET、$arg" >&2
                usage >&2
                exit 64
            fi
            TARGET="$arg"
            ;;
        *)
            echo "✗ 未知参数：$arg；已拒绝执行，未修改数据库。" >&2
            usage >&2
            exit 64
            ;;
    esac
done

if [ -z "$TARGET" ]; then
    echo "✗ 必须显式指定迁移目标；已拒绝执行，未修改数据库。" >&2
    usage >&2
    exit 64
fi

EXPECTED_CONFIRMATION="RESET_${PG_DB}"
if [ "$CONFIRMED" -ne 1 ] && \
   [ "${UTEN_CONFIRM_DESTRUCTIVE_MIGRATION:-}" != "$EXPECTED_CONFIRMATION" ]; then
    echo "✗ 该操作会重建目标模块数据，缺少破坏性操作确认；未修改数据库。" >&2
    echo "  请传 --confirm-destructive，或设置 UTEN_CONFIRM_DESTRUCTIVE_MIGRATION=$EXPECTED_CONFIRMATION" >&2
    exit 65
fi

finish_run () {
    local exit_code=$?
    set +e

    if [ -n "$LOCAL_KEY_FILE" ]; then
        rm -f "$LOCAL_KEY_FILE"
    fi
    if [ "${#REMOTE_TMP_FILES[@]}" -gt 0 ]; then
        "$DOCKER" exec "$CONTAINER" rm -f "${REMOTE_TMP_FILES[@]}" >/dev/null 2>&1
    fi
    "$DOCKER" exec "$CONTAINER" rm -f /tmp/_uten_keys.sql >/dev/null 2>&1

    if [ -n "$RUN_ID" ]; then
        if [ "$exit_code" -eq 0 ]; then
            RUN_STATUS="SUCCESS"
        fi
        "$DOCKER" exec -i "$CONTAINER" psql -U "$PG_USER" -d "$PG_DB" \
            -v ON_ERROR_STOP=1 \
            -c "UPDATE legacy_migration_runs
                SET status = '$RUN_STATUS',
                    finished_at = CURRENT_TIMESTAMP,
                    exit_code = $exit_code
                WHERE run_id = '$RUN_ID'::uuid" >/dev/null 2>&1
    fi

    "$DOCKER" exec "$CONTAINER" rmdir "$LOCK_DIR" >/dev/null 2>&1
    exit "$exit_code"
}
trap finish_run EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

preflight () {
    echo "→ 预检 Docker、数据库、迁移版本与并发锁..."
    "$DOCKER" version >/dev/null
    [ "$("$DOCKER" inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" = "true" ] || {
        echo "✗ PostgreSQL 容器未运行：$CONTAINER" >&2
        exit 69
    }
    "$DOCKER" exec "$CONTAINER" psql -U "$PG_USER" -d "$PG_DB" \
        -v ON_ERROR_STOP=1 -Atqc "SELECT 1" >/dev/null
    [ "$("$DOCKER" exec "$CONTAINER" psql -U "$PG_USER" -d "$PG_DB" \
        -Atqc "SELECT to_regclass('public.legacy_migration_runs') IS NOT NULL")" = "t" ] || {
        echo "✗ 数据库未应用迁移运行审计表，请先启动 server 完成最新 Flyway。" >&2
        exit 69
    }
    "$DOCKER" exec "$CONTAINER" mkdir "$LOCK_DIR" 2>/dev/null || {
        echo "✗ 已有迁移正在运行（锁：$LOCK_DIR）；已拒绝并发执行。" >&2
        exit 75
    }
    RUN_ID=$("$DOCKER" exec "$CONTAINER" psql -U "$PG_USER" -d "$PG_DB" \
        -v ON_ERROR_STOP=1 -Atqc \
        "INSERT INTO legacy_migration_runs(target, status)
         VALUES ('$TARGET', 'RUNNING')
         RETURNING run_id")
}

run_sql () {  # $1 = sql 文件名（HERE 下）
    "$DOCKER" exec -i "$CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=1 < "$HERE/$1"
}

copy_csv () {  # $1 = csv 文件名（HERE/data 下）；自动去 CRLF（Windows 导出兼容）
    if [ ! -s "$HERE/data/$1" ]; then
        echo "✗ CSV 不存在或为空：$HERE/data/$1" >&2
        exit 66
    fi
    "$DOCKER" cp "$HERE/data/$1" "$CONTAINER:/tmp/$1"
    REMOTE_TMP_FILES+=("/tmp/$1")
    "$DOCKER" exec "$CONTAINER" sh -c "tr -d '\r' < /tmp/$1 > /tmp/$1.lf && mv /tmp/$1.lf /tmp/$1" 2>/dev/null || true
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

# 货品组装信息（BOM）：B_BomItem → goods_bom_items（V79）。
# 依赖：--goods-data 先迁（goods.legacy_id 映射父/组件）；孤儿行（父或组件货品不存在）跳过。
migrate_goods_bom () {
    echo "→ [货品组装BOM] 复制 CSV..."
    copy_csv goods_bom.csv
    echo "→ [货品组装BOM] 执行迁移 SQL..."
    run_sql migrate_goods_bom.sql
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
    echo "→ [采购四单据] 复制 CSV（11 个：8 单据 + 人员/部门参考）..."
    for f in purchase_applications purchase_application_items \
             purchase_orders purchase_order_items \
             purchase_receipts purchase_receipt_items \
             purchase_returns purchase_return_items \
             legacy_workers_ref legacy_operators_ref legacy_departments; do
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
    echo "→ [钱流模块] 复制 CSV（12 个：11 M_ + 人员参考 legacy_workers）..."
    for f in m_acc m_style m_in m_out m_get m_paid \
             m_dpaid m_dpaid_item m_oget m_oget_item m_allcheck \
             legacy_workers; do
        copy_csv "$f.csv"
    done
    echo "→ [钱流模块] 执行迁移 SQL（含 B_Worker→employees stub + 刷 finance_ar_ap_mv）..."
    run_sql migrate_finance.sql
}

# 人事老库（B_Worker 72 人全量试迁）：employees 主档 + Emp_Style 职位建档 +
#   身份证/手机 pgcrypto+HMAC 敏感信息。只动 LEGACY-W-* stub，HR 真员工不覆盖；幂等重跑。
# 密钥注入：从 server/.env 读 UTEN_PGP_MASTER_KEY/UTEN_HMAC_KEY 生成临时 \set 文件送入容器，
#   用完本地/容器两侧即删（不落库、不进日志、不进 git）。
migrate_hr_workers () {
    echo "→ [人事老库] 复制 CSV（1 个：hr_workers）..."
    copy_csv hr_workers.csv
    echo "→ [人事老库] 注入加密密钥（临时文件，用后删除）..."
    local envf="$HERE/../.env" keyf="$HERE/.uten_keys.tmp.sql"
    local pgp_key pgp_ver hmac_key
    if [ ! -f "$envf" ]; then
        echo "✗ 找不到 server/.env，无法注入人事加密密钥" >&2
        exit 66
    fi
    LOCAL_KEY_FILE="$keyf"
    pgp_key=$(grep '^UTEN_PGP_MASTER_KEY=' "$envf" | cut -d= -f2-)
    pgp_ver=$(grep '^UTEN_PGP_KEY_VERSION=' "$envf" | cut -d= -f2-)
    hmac_key=$(grep '^UTEN_HMAC_KEY=' "$envf" | cut -d= -f2-)
    if [ -z "$pgp_key" ] || [ -z "$hmac_key" ]; then
        echo "✗ server/.env 缺少 UTEN_PGP_MASTER_KEY 或 UTEN_HMAC_KEY"; exit 1
    fi
    pgp_ver="${pgp_ver:-v1}"
    {
        printf "\\set pgp_key '%s'\n"  "${pgp_key//\'/\'\'}"
        printf "\\set pgp_ver '%s'\n"  "${pgp_ver//\'/\'\'}"
        printf "\\set hmac_key '%s'\n" "${hmac_key//\'/\'\'}"
    } > "$keyf"
    "$DOCKER" cp "$keyf" "$CONTAINER:/tmp/_uten_keys.sql"
    REMOTE_TMP_FILES+=("/tmp/_uten_keys.sql")
    rm -f "$keyf"
    LOCAL_KEY_FILE=""
    echo "→ [人事老库] 执行迁移 SQL（部门映射 + 职位建档 + 员工/敏感信息 upsert）..."
    run_sql migrate_hr_workers.sql
    "$DOCKER" exec "$CONTAINER" rm -f /tmp/_uten_keys.sql
}

# 货品归属（外贸按人授权）：老库外贸子树 → goods.owner_employee_id（无 CSV，纯 UPDATE）。
# 依赖：goods/material_categories 已迁 + employees 有 legacy_id + V85 已应用。幂等（先清零再灌）。
migrate_goods_owner () {
    echo "→ [货品归属] 执行归属迁移 SQL（外贸子树 → owner_employee_id）..."
    run_sql migrate_goods_owner.sql
}

# 客户归属（业务员按人授权）：clients.emp_id → owner_employee_id（无 CSV，纯 UPDATE）。
# 依赖：clients 已迁 + employees 有 legacy_id + V86 已应用。幂等（先清零再灌）。
migrate_client_owner () {
    echo "→ [客户归属] 执行归属迁移 SQL（emp_id → owner_employee_id）..."
    run_sql migrate_client_owner.sql
}

# 销售单据归属（业务员按人授权）：seller_legacy_id → owner_employee_id（无 CSV，纯 UPDATE）。
# 依赖：销售单据已迁 + employees 有 legacy_id + V91 已应用。幂等（先清零再灌）。
migrate_sales_owner () {
    echo "→ [销售归属] 执行归属迁移 SQL（seller_legacy_id → owner_employee_id）..."
    run_sql migrate_sales_owner.sql
}

preflight

case "$TARGET" in
    --goods|-g) migrate_goods ;;
    --goods-data) migrate_goods_data ;;
    --goods-owner) migrate_goods_owner ;;
    --client-owner) migrate_client_owner ;;
    --sales-owner) migrate_sales_owner ;;
    --goods-bom) migrate_goods_bom ;;
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
    --hr-workers) migrate_hr_workers ;;
    --bootstrap-all|--all|-a)
        migrate_goods
        migrate_goods_data
        migrate_goods_bom
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
        migrate_hr_workers
        migrate_goods_owner
        migrate_client_owner
        migrate_sales_owner
        ;;
esac

echo "→ 更新 PostgreSQL 统计信息..."
"$DOCKER" exec "$CONTAINER" psql -U "$PG_USER" -d "$PG_DB" \
    -v ON_ERROR_STOP=1 -c "ANALYZE" >/dev/null

echo ""
echo "✔ 迁移完成（运行号：$RUN_ID）。请执行对账清单后再切流。"
