package com.uten.imp.features.master.goods;

/** Goods lists and BOM component stock use the same accountable good-stock boundary (ADR-146). */
public final class GoodsStockQuantities {
    private GoodsStockQuantities() { }

    private static final String GOOD_STOCK = """
            FROM stock_balances b
            JOIN warehouses w ON w.id = b.warehouse_id
            WHERE w.is_accountable AND NOT w.is_defective AND NOT w.is_line_side
            """;
    static final String SQL = "SELECT b.goods_id, SUM(b.qty) AS qty "+GOOD_STOCK
            +" AND b.goods_id IN (:ids) GROUP BY b.goods_id";
    /** Correlated form for full-scope header comparisons; caller binds exactly one goods identity. */
    public static final String TOTAL_FOR_ID = "(SELECT COALESCE(SUM(b.qty),0) "+GOOD_STOCK+" AND b.goods_id=?)";
}
