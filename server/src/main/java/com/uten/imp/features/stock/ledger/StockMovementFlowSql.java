package com.uten.imp.features.stock.ledger;

import java.util.stream.Collectors;

/** Shared net receipt/issue classification: reversals stay on their original side. */
public final class StockMovementFlowSql {
    private StockMovementFlowSql() {}

    public static String naturalIn(String alias) {
        String codes = StockMovementTypeCatalog.naturalInCodes().stream()
                .map(String::valueOf).collect(Collectors.joining(","));
        return naturalIn(alias, codes);
    }

    static String naturalIn(String alias, String codes) {
        return "(" + alias + ".movement_type IN (" + codes + ") OR (" + alias
                + ".movement_type = 23 AND " + alias + ".direction = 1))";
    }

    /** The predicate uses aliases peer and peer_warehouse and contains only server-owned SQL. */
    public static String internalTransfer(String alias, String peerScope) {
        return internalTransfer(alias, peerScope, alias + ".goods_id");
    }

    static String internalTransfer(String alias, String peerScope, String goodsExpression) {
        return "(" + alias + ".movement_type IN (7, 8) AND EXISTS (SELECT 1 FROM stock_movements peer"
                + " JOIN warehouses peer_warehouse ON peer_warehouse.id=peer.warehouse_id"
                + " WHERE peer.goods_id=" + goodsExpression
                + " AND peer.color_id IS NOT DISTINCT FROM " + alias + ".color_id"
                + " AND peer.source_doc_type=" + alias + ".source_doc_type"
                + " AND peer.source_doc_id=" + alias + ".source_doc_id"
                + " AND peer.source_item_id=" + alias + ".source_item_id"
                + " AND peer.movement_type = 15 - " + alias + ".movement_type"
                + " AND peer.direction = -" + alias + ".direction AND (" + peerScope + ")))";
    }
}
