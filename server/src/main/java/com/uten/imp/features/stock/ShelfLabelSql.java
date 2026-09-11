package com.uten.imp.features.stock;

/**
 * 货架目视化清单原生 SQL（rows / racks / layout 三条查询共用同一 {@code shelf} 子集）。
 *
 * <p>抽成静态纯函数是为了让 {@code ShelfLabelQueryPostgresTest} 用真实 PostgreSQL
 * 跑与服务完全相同的 SQL 文本（命名参数 {@code :warehouseId/:rack/:kw}）。
 *
 * <p>口径：
 * <ul>
 *   <li>货品：未软删；{@code includeDisabled=false} 时排除 status='禁用'；</li>
 *   <li>库位号：选仓时 {@code COALESCE(本仓树偏好.place, goods.stock_place)}（偏好按
 *       last_selected_at 取最新一条，与产成品登记读取口径一致），未选仓只读主档；BTRIM 后为空的不列；</li>
 *   <li>即时库存：未选仓 = 全部核算仓（warehouses.is_accountable）余额汇总；选仓 = 该仓及子仓
 *       （V476 parent_id 递归）余额汇总；无余额行为 0；</li>
 *   <li>parsed：库位号符合 {@link ShelfPlaceParser#SQL_PATTERN} 且层/位段不超过
 *       {@link ShelfPlaceParser#MAX_DIGITS} 位；排序 = 已分层在前 → 库行 → 层 → 位 → 库位号 → 编码；</li>
 *   <li>rack 过滤只对已分层行生效（残值不参与库行筛选）。</li>
 * </ul>
 */
final class ShelfLabelSql {

    static final int ROW_LIMIT = 5000;

    private ShelfLabelSql() {
    }

    /** 仓库子树 CTE（V476 parent_id 递归）+ 本仓树偏好 + 本仓树余额。 */
    private static final String WAREHOUSE_CTE = """
            WITH RECURSIVE wh AS (
                SELECT id FROM warehouses WHERE id = :warehouseId AND is_deleted = false
                UNION ALL
                SELECT w.id FROM warehouses w JOIN wh ON w.parent_id = wh.id
                WHERE w.is_deleted = false
            ),
            pref AS (
                SELECT DISTINCT ON (p.goods_id) p.goods_id, p.place
                  FROM warehouse_goods_place_preferences p
                  JOIN wh ON wh.id = p.warehouse_id
                 ORDER BY p.goods_id, p.last_selected_at DESC
            ),
            sb AS (
                SELECT b.goods_id, SUM(b.qty) AS qty
                  FROM stock_balances b
                  JOIN wh ON wh.id = b.warehouse_id
                 GROUP BY b.goods_id
            ),
            """;

    /** 未选仓：全部核算仓余额汇总（与即时库存「全部」口径一致）。 */
    private static final String GLOBAL_CTE = """
            WITH sb AS (
                SELECT b.goods_id, SUM(b.qty) AS qty
                  FROM stock_balances b
                  JOIN warehouses w ON w.id = b.warehouse_id AND w.is_accountable
                 GROUP BY b.goods_id
            ),
            """;

    /**
     * 公共子集 {@code shelf}：已维护库位号的货品 + 三段解析标记。
     *
     * @param warehouse       是否按仓查询（偏好优先 + 仓树余额）
     * @param includeDisabled 是否包含禁用货品
     */
    private static String shelfCte(boolean warehouse, boolean includeDisabled) {
        String placeExpr = warehouse
                ? "COALESCE(NULLIF(BTRIM(pref.place), ''), NULLIF(BTRIM(g.stock_place), ''))"
                : "NULLIF(BTRIM(g.stock_place), '')";
        String prefJoin = warehouse ? "LEFT JOIN pref ON pref.goods_id = g.id\n" : "";
        String disabledWhere = includeDisabled ? "" : "  AND COALESCE(g.status, '') <> '禁用'\n";
        return (warehouse ? WAREHOUSE_CTE : GLOBAL_CTE)
                + "base AS (\n"
                + "    SELECT g.id AS goods_id,\n"
                + "           " + placeExpr + " AS place,\n"
                + "           g.code, g.series, g.name,\n"
                + "           COALESCE(c.name, '') AS color_name,\n"
                + "           COALESCE(u.name, '') AS unit_name,\n"
                + "           COALESCE(sb.qty, 0) AS qty,\n"
                + "           (COALESCE(g.status, '') = '禁用') AS disabled\n"
                + "      FROM goods g\n"
                + prefJoin
                + "      LEFT JOIN sb ON sb.goods_id = g.id\n"
                + "      LEFT JOIN colors c ON c.id = g.color_id\n"
                + "      LEFT JOIN units u\n"
                + "        ON (u.id = g.unit_id\n"
                + "            OR (g.unit_id IS NULL AND u.legacy_id = NULLIF(g.unit_legacy_id, 0)))\n"
                + "     WHERE g.is_deleted = false\n"
                + disabledWhere
                + "),\n"
                + "shelf AS (\n"
                + "    SELECT base.*,\n"
                + "           (base.place ~ '" + ShelfPlaceParser.SQL_PATTERN + "'\n"
                + "            AND length(split_part(base.place, '-', 2)) <= " + ShelfPlaceParser.MAX_DIGITS + "\n"
                + "            AND length(split_part(base.place, '-', 3)) <= " + ShelfPlaceParser.MAX_DIGITS + ") AS parsed\n"
                + "      FROM base\n"
                + "     WHERE base.place IS NOT NULL\n"
                + ")\n";
    }

    /**
     * 行查询：列序 = goods_id, place, code, series, name, color_name, unit_name, qty, disabled, parsed。
     * 命名参数：{@code :warehouseId}（warehouse=true）、{@code :rack}（hasRack）、{@code :kw}（hasKw）。
     */
    static String rows(boolean warehouse, boolean includeDisabled, boolean hasRack, boolean hasKw) {
        StringBuilder sql = new StringBuilder(shelfCte(warehouse, includeDisabled));
        sql.append("SELECT r.goods_id, r.place, r.code, r.series, r.name,\n")
           .append("       r.color_name, r.unit_name, r.qty, r.disabled, r.parsed\n")
           .append("  FROM shelf r\n")
           .append(" WHERE 1 = 1\n");
        if (hasRack) {
            sql.append("   AND r.parsed AND split_part(r.place, '-', 1) = :rack\n");
        }
        if (hasKw) {
            sql.append("   AND (r.name ILIKE :kw OR r.code ILIKE :kw\n")
               .append("        OR r.series ILIKE :kw OR r.place ILIKE :kw)\n");
        }
        sql.append(" ORDER BY r.parsed DESC,\n")
           .append("          split_part(r.place, '-', 1),\n")
           .append("          CASE WHEN r.parsed THEN split_part(r.place, '-', 2)::int END,\n")
           .append("          CASE WHEN r.parsed THEN split_part(r.place, '-', 3)::int END,\n")
           .append("          r.place, r.code\n")
           .append(" LIMIT ").append(ROW_LIMIT).append('\n');
        return sql.toString();
    }

    /** 已分层库行去重排序（残值不进下拉）。 */
    static String racks(boolean warehouse, boolean includeDisabled) {
        return shelfCte(warehouse, includeDisabled)
                + "SELECT DISTINCT split_part(r.place, '-', 1) AS rack\n"
                + "  FROM shelf r\n"
                + " WHERE r.parsed\n"
                + " ORDER BY rack\n";
    }

    /**
     * 货架图布局：每个已分层库行的最大层/位与行数；末尾追加一条 rack='' 的未分层桶
     * （仅残值数 > 0 时出现）。列序 = rack, max_level, max_slot, cnt。
     */
    static String layout(boolean warehouse, boolean includeDisabled) {
        return shelfCte(warehouse, includeDisabled)
                + "SELECT t.rack, t.max_level, t.max_slot, t.cnt\n"
                + "  FROM (\n"
                + "    SELECT split_part(r.place, '-', 1) AS rack,\n"
                + "           MAX(split_part(r.place, '-', 2)::int) AS max_level,\n"
                + "           MAX(split_part(r.place, '-', 3)::int) AS max_slot,\n"
                + "           COUNT(*) AS cnt\n"
                + "      FROM shelf r\n"
                + "     WHERE r.parsed\n"
                + "     GROUP BY split_part(r.place, '-', 1)\n"
                + "    UNION ALL\n"
                + "    SELECT '' AS rack, CAST(NULL AS int) AS max_level, CAST(NULL AS int) AS max_slot,\n"
                + "           COUNT(*) AS cnt\n"
                + "      FROM shelf r\n"
                + "     WHERE NOT r.parsed\n"
                + "    HAVING COUNT(*) > 0\n"
                + "  ) t\n"
                + " ORDER BY (t.rack = ''), t.rack\n";
    }
}
