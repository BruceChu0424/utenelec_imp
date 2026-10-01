package com.uten.imp.features.warehouse.materialbin;

/** 申请候选只读 SQL；不改变共享的 PERIODIC 发料/退料候选契约。 */
final class WorkshopMaterialRequestCandidateSql {
    private WorkshopMaterialRequestCandidateSql() {}

    static String stock(boolean filterGoods) {
        return """
                WITH eligible AS MATERIALIZED (
                    SELECT goods.id, goods.color_id FROM goods
                    JOIN units unit ON unit.id = goods.unit_id AND NOT unit.is_deleted
                      AND unit.status = '使用'
                    JOIN unit_measurement_profiles profile ON profile.unit_id = goods.unit_id
                      AND profile.measurement_dimension = 'MASS'
                    WHERE goods.issue_method IN ('ORDER', 'PERIODIC') AND NOT goods.is_deleted
                      AND goods.status = '使用'
                """ + (filterGoods ? " AND goods.id IN (:goodsIds)\n" : "") + """
                ), balances AS MATERIALIZED (
                    SELECT balance.warehouse_id, balance.goods_id, balance.color_id, balance.qty
                    FROM stock_balances balance JOIN eligible ON eligible.id = balance.goods_id
                    WHERE balance.qty <> 0
                ), accounting AS MATERIALIZED (
                    SELECT leaf.warehouse_id FROM (SELECT DISTINCT warehouse_id FROM balances) leaf
                    WHERE fn_warehouse_is_active_accounting_leaf(leaf.warehouse_id)
                ), stocked AS MATERIALIZED (
                    SELECT balances.* FROM balances JOIN accounting ON accounting.warehouse_id = balances.warehouse_id
                )
                """;
    }

    static String candidates(boolean filterGoods) {
        return stock(filterGoods) + """
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
                           goods.bulk_package_qty, goods.periodic_cost_basis, goods.min_qty,
                           owning.id AS owning_warehouse_id, owning.name AS owning_name,
                           EXISTS (SELECT 1 FROM used WHERE used.goods_id = candidate.goods_id
                                     AND used.color_id IS NOT DISTINCT FROM candidate.color_id) AS used
                    FROM candidate_keys candidate JOIN goods ON goods.id = candidate.goods_id
                    JOIN units unit ON unit.id = goods.unit_id
                    LEFT JOIN colors color ON color.id = candidate.color_id
                    LEFT JOIN warehouses owning ON owning.id = goods.owning_warehouse_id
                      AND fn_warehouse_is_active_accounting_leaf(owning.id)
                    WHERE (candidate.color_id IS NULL OR (color.id IS NOT NULL AND NOT color.is_deleted
                           AND color.status = '使用'))
                      AND (CAST(:keyword AS text) IS NULL OR
                           strpos(lower(concat_ws(' ', goods.code, goods.name, color.name)), lower(:keyword)) > 0)
                )
                """;
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
                                          OR fn_warehouse_is_active_accounting_leaf(reservation.warehouse_id))), 0)
                       - GREATEST(COALESCE(candidate.min_qty::numeric, 0), 0), 0) AS available
            FROM candidates candidate
            ORDER BY candidate.used DESC, candidate.code, candidate.goods_id,
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
