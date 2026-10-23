package com.uten.imp.features.master.goods;

/** Goods lists and BOM component stock use the same accountable good-stock boundary (ADR-146). */
final class GoodsStockQuantities {
    private GoodsStockQuantities() { }

    static final String SQL = """
            SELECT b.goods_id, SUM(b.qty) AS qty
            FROM stock_balances b
            JOIN warehouses w ON w.id = b.warehouse_id
            WHERE w.is_accountable AND NOT w.is_defective AND NOT w.is_line_side
              AND b.goods_id IN (:ids)
            GROUP BY b.goods_id
            """;
}
