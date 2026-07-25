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
#
# 当前已实现：货品（分类+主档）、模具（分类+主档）。新增模块时在下方加 case + 对应 .sql。
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
        ;;
esac

echo ""
echo "✔ 全部迁移完成。现在可以启动 server 测试前端了。"
