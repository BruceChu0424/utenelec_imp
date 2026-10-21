package com.uten.imp.features.warehouse.materialbin;

import com.uten.imp.common.util.GoodsSearchPolicy;

/** 申请候选只读 SQL；默认出库仓只由 fn_workshop_bin_default_source 给出(ADR-147)。 */
final class WorkshopMaterialRequestCandidateSql {
    private WorkshopMaterialRequestCandidateSql() {}

    static String stock(boolean filterGoods) {
        return stock(filterGoods, "", "");
    }

    private static String stock(boolean filterGoods, String categoryCte, String categoryFilter) {
        return "WITH RECURSIVE " + categoryCte + """
                eligible AS MATERIALIZED (
                    SELECT goods.id, goods.color_id FROM goods
                    JOIN units unit ON unit.id = goods.unit_id AND NOT unit.is_deleted
                      AND unit.status = '使用'
                    JOIN unit_measurement_profiles profile ON profile.unit_id = goods.unit_id
                      AND profile.measurement_dimension = 'MASS'
                    WHERE goods.issue_method IN ('ORDER', 'PERIODIC') AND NOT goods.is_deleted
                      AND goods.status = '使用'
                """ + (filterGoods ? " AND goods.id IN (:goodsIds)\n" : "") + categoryFilter + """
                ), balances AS MATERIALIZED (
                    SELECT balance.warehouse_id, balance.goods_id, balance.color_id, balance.qty
                    FROM stock_balances balance JOIN eligible ON eligible.id = balance.goods_id
                    WHERE balance.qty <> 0
                ), accounting AS MATERIALIZED (
                    SELECT leaf.warehouse_id FROM (SELECT DISTINCT warehouse_id FROM balances) leaf
                    WHERE fn_warehouse_is_good_stock_leaf(leaf.warehouse_id)
                ), stocked AS MATERIALIZED (
                    SELECT balances.* FROM balances JOIN accounting ON accounting.warehouse_id = balances.warehouse_id
                )
                """;
    }

    static String candidates(boolean filterGoods, String categoryCte, String categoryFilter,
            GoodsSearchPolicy.NativeSearch search, boolean activeSearch) {
        String kind = activeSearch ? "CASE WHEN (" + search.rank() + ")<"
                + GoodsSearchPolicy.RELATED_RANK_OFFSET + " THEN 'PRIMARY' ELSE 'RELATED' END" : "NULL::text";
        return stock(filterGoods, categoryCte, categoryFilter) + """
                , used AS MATERIALIZED (
                    SELECT DISTINCT ledger.goods_id, ledger.color_id FROM v_workshop_material_bin_ledger ledger
                    JOIN eligible ON eligible.id = ledger.goods_id
                    WHERE ledger.bin_warehouse_id = CAST(:bin AS uuid)
                ), candidate_keys AS (
                    SELECT eligible.id AS goods_id, eligible.color_id FROM eligible
                    UNION SELECT stocked.goods_id, stocked.color_id FROM stocked WHERE stocked.qty > 0
                    UNION SELECT used.goods_id, used.color_id FROM used
                ), candidates AS (
                    SELECT candidate.goods_id, candidate.color_id, goods.code, goods.name,
                           color.name AS color_name, unit.name AS unit_name,
                           COALESCE(category.id,CAST(:uncategorized AS uuid)) AS category_id,
                           goods.bulk_package_qty, goods.periodic_cost_basis, goods.min_qty,
                           default_leaf.id AS default_leaf_id, default_leaf.name AS default_leaf_name,
                           %s AS keyword_rank, %s AS search_match_kind,
                           EXISTS (SELECT 1 FROM used WHERE used.goods_id = candidate.goods_id
                                     AND used.color_id IS NOT DISTINCT FROM candidate.color_id) AS used
                    FROM candidate_keys candidate JOIN goods ON goods.id = candidate.goods_id
                    JOIN units unit ON unit.id = goods.unit_id
                    LEFT JOIN colors color ON color.id = candidate.color_id
                    LEFT JOIN material_categories category ON category.id=goods.category_id AND NOT category.is_deleted
                    LEFT JOIN warehouses default_leaf ON default_leaf.id = fn_workshop_bin_default_source(
                        CAST(:bin AS uuid), candidate.goods_id, candidate.color_id)
                    WHERE (candidate.color_id IS NULL OR (color.id IS NOT NULL AND NOT color.is_deleted
                           AND color.status = '使用'))
                      AND (%s)
                )
                """.formatted(search.rank(), kind, search.condition());
    }

    static final String HEADS = """
            SELECT candidate.*,
                   GREATEST(
                       COALESCE((SELECT sum(stocked.qty) FROM stocked
                                 WHERE stocked.goods_id = candidate.goods_id
                                   AND stocked.color_id IS NOT DISTINCT FROM candidate.color_id), 0)
                       - COALESCE((SELECT sum(reservation.qty - reservation.consumed_qty - reservation.released_qty)
                                   FROM stock_reservations reservation
                                   WHERE NOT reservation.is_deleted AND reservation.status = 0
                                     AND reservation.goods_id = candidate.goods_id
                                     AND reservation.color_id IS NOT DISTINCT FROM candidate.color_id
                                     AND (reservation.warehouse_id IS NULL
                                          OR fn_warehouse_is_good_stock_leaf(reservation.warehouse_id))), 0)
                       - GREATEST(COALESCE(candidate.min_qty::numeric, 0), 0), 0) AS available
            FROM candidates candidate
            ORDER BY candidate.keyword_rank, candidate.used DESC, candidate.code, candidate.goods_id,
                     candidate.color_name NULLS FIRST, candidate.color_id NULLS FIRST
            LIMIT :limit OFFSET :offset
            """;

    static final String LEAVES = """
            SELECT stocked.goods_id, stocked.color_id, stocked.warehouse_id, warehouse.name AS warehouse_name,
                   GREATEST(stocked.qty
                       - COALESCE((SELECT sum(reservation.qty - reservation.consumed_qty - reservation.released_qty)
                                   FROM stock_reservations reservation
                                   WHERE NOT reservation.is_deleted AND reservation.status = 0
                                     AND reservation.goods_id = stocked.goods_id
                                     AND reservation.color_id IS NOT DISTINCT FROM stocked.color_id
                                     AND (reservation.warehouse_id IS NULL
                                          OR reservation.warehouse_id = stocked.warehouse_id)), 0), 0) AS available
            FROM stocked JOIN warehouses warehouse ON warehouse.id = stocked.warehouse_id
            WHERE stocked.qty > 0
            ORDER BY stocked.goods_id, stocked.color_id, warehouse.name, stocked.warehouse_id
            """;
}
