package com.uten.imp.features.production.analysis;

/** The pre-lock discovery and the in-transaction refresh must select the same
 * qualified source scope, including material already handed to an execution task. */
final class MaterialAnalysisWakeupScopeSql {
    private MaterialAnalysisWakeupScopeSql() {}

    /** Arguments are trusted column expressions from the two queries below, never request values. */
    static String ownsQualifiedAt(String analysisId, String materialId, String warehouseId,
                                  String goodsId, String colorId) {
        return """
                (EXISTS (
                    SELECT 1 FROM v_preplan_stock_entitlement_beneficiary_balance owned
                    JOIN stock_reservations source ON source.id=owned.stock_reservation_id
                      AND source.is_deleted=FALSE
                      AND source.warehouse_id=@warehouse
                      AND source.goods_id=@goods
                      AND source.color_id IS NOT DISTINCT FROM @color
                    WHERE owned.beneficiary_analysis_id=@analysis
                      AND owned.beneficiary_analysis_material_id=@material
                      AND owned.effective_qty>0
                      AND fn_preplan_reservation_has_qualified_origin(source.id))
                  OR EXISTS (
                    SELECT 1 FROM preplan_stock_entitlement_events formal
                    JOIN preplan_stock_entitlement_events source_event
                      ON source_event.id=formal.source_entitlement_event_id
                    JOIN stock_reservations target
                      ON target.id=formal.target_stock_reservation_id
                     AND target.is_deleted=FALSE
                     AND target.warehouse_id=@warehouse
                     AND target.goods_id=@goods
                     AND target.color_id IS NOT DISTINCT FROM @color
                     AND target.qty-target.released_qty>0
                    WHERE formal.event_type='FORMALIZE'
                      AND source_event.beneficiary_analysis_id=@analysis
                      AND source_event.beneficiary_analysis_material_id=@material
                      AND fn_preplan_reservation_has_qualified_origin(source_event.stock_reservation_id)
                      AND NOT EXISTS(SELECT 1 FROM preplan_stock_entitlement_events restored
                          WHERE restored.event_type='RESTORE' AND restored.counter_event_id=formal.id)))
                """.replace("@analysis", analysisId).replace("@material", materialId)
                .replace("@warehouse", warehouseId).replace("@goods", goodsId).replace("@color", colorId);
    }
}
