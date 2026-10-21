package com.uten.imp.features.production.analysis;

/** Read-only procurement lifecycle facts correlated to the supply action alias {@code action}. */
final class PurchaseActionLifecycleProjection {
    private PurchaseActionLifecycleProjection() { }

    /** Private and public can share one physical request item; UNION counts it exactly once. */
    static final String REGULAR_ITEM_IDS_SQL = """
            SELECT allocation.external_item_id FROM preplan_supply_action_allocations allocation
            WHERE allocation.action_id=action.id AND allocation.external_item_id IS NOT NULL
            UNION SELECT action.public_surplus_external_item_id
            WHERE action.public_surplus_external_item_id IS NOT NULL
            """;

    private static final String ORDER_ITEM_STOCKED_BASE_SQL = """
            GREATEST(COALESCE((
                SELECT SUM(CASE WHEN inspection.id IS NULL
                                THEN receipt_item.qty*COALESCE(receipt_item.unit_rate,1)
                            WHEN inspection.status IN ('PARTIAL','RESOLVED')
                                THEN COALESCE(inspection.warehouse_stocked_base_qty,0)
                            ELSE 0 END)
                FROM purchase_receipt_items receipt_item
                JOIN purchase_receipts receipt ON receipt.id=receipt_item.receipt_id
                  AND receipt.status=1 AND NOT receipt.is_deleted
                LEFT JOIN procurement_inspection_items inspection ON inspection.receipt_type='PURCHASE'
                  AND inspection.receipt_item_id=receipt_item.id
                WHERE receipt_item.order_item_id=item.id AND NOT receipt_item.is_deleted),0)
              -COALESCE(item.returned_qty,0)*COALESCE(item.unit_rate,1),0)
            """;

    static final String REGULAR_STOCKED_BASE_SQL = """
            COALESCE((SELECT SUM(fn_purchase_order_source_share(item.id,source.request_item_id,%s))
                FROM purchase_order_item_sources source
                JOIN purchase_order_items item ON item.id=source.order_item_id AND NOT item.is_deleted
                JOIN purchase_orders document ON document.id=item.order_id
                  AND document.status=1 AND NOT document.is_deleted
                WHERE source.alloc_qty>0 AND source.request_item_id IN (%s)),0)
            """.formatted(ORDER_ITEM_STOCKED_BASE_SQL,REGULAR_ITEM_IDS_SQL);

    static final String REGULAR_APPROVED_ORDER_EXISTS_SQL = """
            EXISTS (SELECT 1 FROM purchase_order_item_sources source
                JOIN purchase_order_items item ON item.id=source.order_item_id AND NOT item.is_deleted
                JOIN purchase_orders document ON document.id=item.order_id
                  AND document.status=1 AND NOT document.is_deleted
                WHERE source.alloc_qty>0 AND source.request_item_id IN (%s))
            """.formatted(REGULAR_ITEM_IDS_SQL);

    static final String REGULAR_FAILED_INSPECTION_EXISTS_SQL = """
            EXISTS (SELECT 1 FROM purchase_order_item_sources source
                JOIN purchase_order_items item ON item.id=source.order_item_id AND NOT item.is_deleted
                JOIN purchase_orders document ON document.id=item.order_id
                  AND document.status=1 AND NOT document.is_deleted
                JOIN purchase_receipt_items receipt_item ON receipt_item.order_item_id=item.id AND NOT receipt_item.is_deleted
                JOIN purchase_receipts receipt ON receipt.id=receipt_item.receipt_id AND receipt.status=1 AND NOT receipt.is_deleted
                JOIN procurement_inspection_items inspection ON inspection.receipt_type='PURCHASE'
                  AND inspection.receipt_item_id=receipt_item.id AND inspection.status='RESOLVED' AND inspection.failed_base_qty>0
                WHERE source.alloc_qty>0 AND source.request_item_id IN (%s))
            """.formatted(REGULAR_ITEM_IDS_SQL);

    /** Preserve in-transit, unfinished IQC and qualified-but-not-stocked source evidence. */
    static final String REGULAR_FUTURE_ORDER_EXISTS_SQL = """
            EXISTS (SELECT 1 FROM purchase_order_item_sources source
                JOIN purchase_order_items item ON item.id=source.order_item_id AND NOT item.is_deleted
                JOIN purchase_orders document ON document.id=item.order_id
                  AND document.status=1 AND NOT document.is_deleted
                WHERE source.alloc_qty>0 AND source.request_item_id IN (%s)
                  AND fn_procurement_order_source_remaining_qty('PURCHASE',item.id,source.request_item_id)>0)
            """.formatted(REGULAR_ITEM_IDS_SQL);

    static final String REGULAR_PENDING_INSPECTION_EXISTS_SQL = """
            EXISTS (SELECT 1 FROM purchase_order_item_sources source
                JOIN purchase_order_items item ON item.id=source.order_item_id AND NOT item.is_deleted
                JOIN purchase_receipt_items receipt_item ON receipt_item.order_item_id=item.id AND NOT receipt_item.is_deleted
                JOIN purchase_receipts receipt ON receipt.id=receipt_item.receipt_id AND receipt.status=1 AND NOT receipt.is_deleted
                JOIN procurement_inspection_items inspection ON inspection.receipt_type='PURCHASE'
                  AND inspection.receipt_item_id=receipt_item.id
                  AND (inspection.status NOT IN ('RESOLVED','REVERSED')
                       OR (inspection.status<>'REVERSED' AND inspection.passed_base_qty>inspection.warehouse_stocked_base_qty))
                WHERE source.alloc_qty>0 AND source.request_item_id IN (%s))
            """.formatted(REGULAR_ITEM_IDS_SQL);

    static final String REGULAR_FUTURE_SUPPLY_EXISTS_SQL = """
            (EXISTS (SELECT 1 FROM purchase_request_items item
                WHERE item.id IN (%s) AND NOT item.is_deleted AND item.qty>COALESCE(item.ordered_qty,0))
             OR %s OR %s)
            """.formatted(REGULAR_ITEM_IDS_SQL,REGULAR_FUTURE_ORDER_EXISTS_SQL,REGULAR_PENDING_INSPECTION_EXISTS_SQL);
}
