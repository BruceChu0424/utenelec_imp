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

    /** Materialize the physical relationship before recursively classifying its provenance.
     * A native filter on an unrestricted base table can be evaluated before its join key,
     * repeatedly traversing unrelated receipt/order graphs for every supply action. */
    private static String nativeRows(String table, String relationship) {
        return "\n" + """
                LATERAL (
                    WITH selected AS MATERIALIZED (
                        SELECT candidate.* FROM %s candidate WHERE %s
                    )
                    SELECT archive_origin.* FROM selected archive_origin
                    WHERE NULLIF(to_jsonb(archive_origin)->>'legacy_id','') IS NULL
                      AND NULLIF(to_jsonb(archive_origin)->>'legacy_import_run_id','') IS NULL
                      AND NOT fn_imported_business_document('%s',archive_origin.id)
                )
                """.formatted(table, relationship, table);
    }

    private static final String NATIVE_ORDER_ITEMS = nativeRows("purchase_order_items",
            "candidate.id=source.order_item_id AND source.alloc_qty>0 AND source.request_item_id IN ("
                    + REGULAR_ITEM_IDS_SQL + ")");
    private static final String NATIVE_ORDERS = nativeRows("purchase_orders", "candidate.id=item.order_id");
    private static final String NATIVE_RECEIPT_ITEMS = nativeRows("purchase_receipt_items", "candidate.order_item_id=item.id");
    private static final String NATIVE_RECEIPTS = nativeRows("purchase_receipts", "candidate.id=receipt_item.receipt_id");
    private static final String NATIVE_REQUEST_ITEMS = nativeRows("purchase_request_items", "candidate.id IN (" + REGULAR_ITEM_IDS_SQL + ")");
    private static final String NATIVE_REQUESTS = nativeRows("purchase_requests", "candidate.id=action.external_document_id");

    private static final String ORDER_ITEM_STOCKED_BASE_SQL = """
            GREATEST(COALESCE((
                SELECT SUM(CASE WHEN inspection.id IS NULL
                                THEN receipt_item.qty*COALESCE(receipt_item.unit_rate,1)
                            WHEN inspection.status IN ('PARTIAL','RESOLVED')
                                THEN COALESCE(inspection.warehouse_stocked_base_qty,0)
                            ELSE 0 END)
                FROM """ + NATIVE_RECEIPT_ITEMS + """
                receipt_item
                JOIN """ + NATIVE_RECEIPTS + """
                receipt ON receipt.id=receipt_item.receipt_id
                  AND receipt.status=1 AND NOT receipt.is_deleted
                LEFT JOIN procurement_inspection_items inspection ON inspection.receipt_type='PURCHASE'
                  AND inspection.receipt_item_id=receipt_item.id
                WHERE receipt_item.order_item_id=item.id AND NOT receipt_item.is_deleted),0)
              -COALESCE(item.returned_qty,0)*COALESCE(item.unit_rate,1),0)
            """;

    static final String REGULAR_STOCKED_BASE_SQL = ("""
            COALESCE((SELECT SUM(fn_purchase_order_source_share(item.id,source.request_item_id,%s))
                FROM purchase_order_item_sources source
                JOIN """ + NATIVE_ORDER_ITEMS + """
                item ON item.id=source.order_item_id AND NOT item.is_deleted
                JOIN """ + NATIVE_ORDERS + """
                document ON document.id=item.order_id
                  AND document.status=1 AND NOT document.is_deleted
                WHERE source.alloc_qty>0 AND source.request_item_id IN (%s)),0)
            """).formatted(ORDER_ITEM_STOCKED_BASE_SQL,REGULAR_ITEM_IDS_SQL);

    static final String REGULAR_APPROVED_ORDER_EXISTS_SQL = ("""
            EXISTS (SELECT 1 FROM purchase_order_item_sources source
                JOIN """ + NATIVE_ORDER_ITEMS + """
                item ON item.id=source.order_item_id AND NOT item.is_deleted
                JOIN """ + NATIVE_ORDERS + """
                document ON document.id=item.order_id
                  AND document.status=1 AND NOT document.is_deleted
                WHERE source.alloc_qty>0 AND source.request_item_id IN (%s))
            """).formatted(REGULAR_ITEM_IDS_SQL);

    static final String REGULAR_FAILED_INSPECTION_EXISTS_SQL = ("""
            EXISTS (SELECT 1 FROM purchase_order_item_sources source
                JOIN """ + NATIVE_ORDER_ITEMS + """
                item ON item.id=source.order_item_id AND NOT item.is_deleted
                JOIN """ + NATIVE_ORDERS + """
                document ON document.id=item.order_id
                  AND document.status=1 AND NOT document.is_deleted
                JOIN """ + NATIVE_RECEIPT_ITEMS + """
                receipt_item ON receipt_item.order_item_id=item.id AND NOT receipt_item.is_deleted
                JOIN """ + NATIVE_RECEIPTS + """
                receipt ON receipt.id=receipt_item.receipt_id AND receipt.status=1 AND NOT receipt.is_deleted
                JOIN procurement_inspection_items inspection ON inspection.receipt_type='PURCHASE'
                  AND inspection.receipt_item_id=receipt_item.id AND inspection.status='RESOLVED' AND inspection.failed_base_qty>0
                WHERE source.alloc_qty>0 AND source.request_item_id IN (%s))
            """).formatted(REGULAR_ITEM_IDS_SQL);

    /** Preserve in-transit, unfinished IQC and qualified-but-not-stocked source evidence. */
    static final String REGULAR_FUTURE_ORDER_EXISTS_SQL = ("""
            EXISTS (SELECT 1 FROM purchase_order_item_sources source
                JOIN """ + NATIVE_ORDER_ITEMS + """
                item ON item.id=source.order_item_id AND NOT item.is_deleted
                JOIN """ + NATIVE_ORDERS + """
                document ON document.id=item.order_id
                  AND document.status=1 AND NOT document.is_deleted
                WHERE source.alloc_qty>0 AND source.request_item_id IN (%s)
                  AND fn_procurement_order_source_remaining_qty('PURCHASE',item.id,source.request_item_id)>0)
            """).formatted(REGULAR_ITEM_IDS_SQL);

    static final String REGULAR_PENDING_INSPECTION_EXISTS_SQL = ("""
            EXISTS (SELECT 1 FROM purchase_order_item_sources source
                JOIN """ + NATIVE_ORDER_ITEMS + """
                item ON item.id=source.order_item_id AND NOT item.is_deleted
                JOIN """ + NATIVE_RECEIPT_ITEMS + """
                receipt_item ON receipt_item.order_item_id=item.id AND NOT receipt_item.is_deleted
                JOIN """ + NATIVE_RECEIPTS + """
                receipt ON receipt.id=receipt_item.receipt_id AND receipt.status=1 AND NOT receipt.is_deleted
                JOIN procurement_inspection_items inspection ON inspection.receipt_type='PURCHASE'
                  AND inspection.receipt_item_id=receipt_item.id
                  AND (inspection.status NOT IN ('RESOLVED','REVERSED')
                       OR (inspection.status<>'REVERSED' AND inspection.passed_base_qty>inspection.warehouse_stocked_base_qty))
                WHERE source.alloc_qty>0 AND source.request_item_id IN (%s))
            """).formatted(REGULAR_ITEM_IDS_SQL);

    static final String REGULAR_FUTURE_SUPPLY_EXISTS_SQL = ("""
            (EXISTS (SELECT 1 FROM """ + NATIVE_REQUEST_ITEMS + """
                item
                WHERE item.id IN (%s) AND NOT item.is_deleted AND item.qty>COALESCE(item.ordered_qty,0))
             OR %s OR %s)
            """).formatted(REGULAR_ITEM_IDS_SQL,REGULAR_FUTURE_ORDER_EXISTS_SQL,REGULAR_PENDING_INSPECTION_EXISTS_SQL);

    /** Exact ordinary/public purchase failure projection, shared by refresh and real PG regression. */
    static String failedSupplyCancellationSql() {
        return """
                UPDATE preplan_supply_actions action
                SET status='CANCELLED',cancelled_by=:actorId,cancelled_at=now(),
                    cancellation_reason='到货质检存在不合格且原采购需求已无在途，需重新通知补采',updated_at=now()
                WHERE action.analysis_id=:analysisId AND NOT fn_preplan_action_has_future_transfer(action.id)
                  AND NOT fn_preplan_action_has_shared_claims(action.id) AND action.operation_type<>'SHARED_FUTURE_CLAIM'
                  AND action.status IN ('CREATED','IN_PROGRESS','DONE')
                  AND action.external_document_type='PURCHASE_REQUEST'
                  AND (action.safety_replenishment_qty=0 OR action.public_surplus_qty>0)
                  AND EXISTS (SELECT 1 FROM
                """ + NATIVE_REQUESTS + """
                      request WHERE request.id=action.external_document_id
                      AND NOT request.is_deleted AND request.status IN (0,1) AND NOT request.is_stopped AND request.is_closed)
                  AND action.requested_qty+action.public_surplus_qty > (
                """ + REGULAR_STOCKED_BASE_SQL + """
                  ) AND (
                """ + REGULAR_FAILED_INSPECTION_EXISTS_SQL + """
                  ) AND NOT (
                """ + REGULAR_FUTURE_ORDER_EXISTS_SQL + """
                  ) AND NOT (
                """ + REGULAR_PENDING_INSPECTION_EXISTS_SQL + """
                  ) AND (action.safety_replenishment_qty=0 OR EXISTS (
                      SELECT 1 FROM v_preplan_buy_action_slice_progress progress
                      WHERE progress.action_id=action.id AND progress.safety_future_qty=0))
                """;
    }
}
