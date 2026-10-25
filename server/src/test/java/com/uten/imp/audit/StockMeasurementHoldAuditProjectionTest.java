package com.uten.imp.audit;

import java.util.UUID;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class StockMeasurementHoldAuditProjectionTest {
    private static final String TABLE="stock_measurement_holds";
    private static final String SHA="a".repeat(64);
    private final AuditEventInterpreter interpreter=new AuditEventInterpreter();

    @Test void detailAndListNeverRevealOriginalCommercialFieldsOrPrivateReviewText() {
        AuditLog original=log("update");
        original.setBefore("{\"released_at\":null,\"captured_amount_local\":987654.32,\"captured_qty\":99,\"captured_weight\":88}");
        original.setAfter("{\"released_at\":\"2026-10-25T10:00:00Z\",\"evidence_sha256\":\""+SHA
                +"\",\"captured_amount_local\":123456.78,\"captured_qty\":100,\"captured_weight\":90,"
                +"\"evidence_reference\":\"private://13800138000/COST_SECRET\",\"resolution_note\":\"PRIVATE_REVIEW_TEXT\","
                +"\"goods_name\":\"PRIVATE_NAME\",\"_redacted_changes\":[\"resolution_note\",\"evidence_reference\",\"PRIVATE_KEY\"]}");
        var event=interpreter.interpret(original);
        var detail=AuditLogDetail.of(original,interpreter);
        assertEquals("库存原计量核验凭据",event.objectLabel());
        assertTrue(event.changeSummary().contains("原计量核验完成时间"));
        String visible=detail.before()+detail.after()+detail.summary()+detail.changeSummary()+event.summary();
        for(String secret:new String[]{"987654","123456","captured_qty","captured_weight","PRIVATE_REVIEW_TEXT",
                "PRIVATE_NAME","PRIVATE_KEY","13800138000","COST_SECRET"})assertFalse(visible.contains(secret),secret);
        assertTrue(detail.after().contains(SHA));
        assertTrue(detail.after().contains("_redacted_changes"));
        assertEquals("low",detail.riskLevel());
        assertEquals("data_change",detail.eventCategory());
        assertTrue(original.getAfter().contains("COST_SECRET"),"read projection must not mutate stored audit evidence");
    }

    @Test void malformedCommercialValuesCannotHideInsideAllowedIdentityFields() {
        String safe=StockMeasurementHoldAuditProjection.snapshot(TABLE,
                "{\"goods_id\":\"COST_SECRET\",\"released_at\":\"PHONE_SECRET\",\"evidence_sha256\":\"not-a-digest\","
                        +"\"captured_at\":{},\"reason\":\"PRIVATE_REVIEW_TEXT\"}");
        assertEquals("{}",safe);
        assertNull(StockMeasurementHoldAuditProjection.snapshot(TABLE,"[\"private\"]"));
        assertNull(StockMeasurementHoldAuditProjection.snapshot(TABLE,"invalid"));
    }

    @Test void newCaptureShowsPendingFactsWithoutInventingAReviewerOrChangingStoredRisk() {
        var value=log("insert");
        value.setAfter("{\"id\":\""+UUID.randomUUID()+"\",\"reason\":\"LEGACY_QUANTITY_BASIS_UNPROVEN\","
                +"\"captured_at\":\"2026-10-25T10:00:00Z\",\"released_at\":null,\"verified_by\":null,\"evidence_sha256\":null}");
        var detail=AuditLogDetail.of(value,interpreter);
        assertTrue(detail.after().contains("\"verified_by\":null"));
        assertTrue(detail.after().contains("\"released_at\":null"));
        assertFalse(detail.summary().contains("审核通过"));
        assertEquals("low",detail.riskLevel());
        assertEquals("data_change",detail.eventCategory());
    }

    @Test void unrelatedAndUnknownTypesKeepTheirExistingBehavior() {
        AuditLog unknown=log("update");unknown.setTargetType("stock_measurement_holds_unknown");
        unknown.setAfter("{\"not_our_scope\":true}");
        assertSame(unknown,StockMeasurementHoldAuditProjection.presentation(unknown));
        assertFalse(StockMeasurementHoldAuditProjection.applies(unknown.getTargetType()));
        assertEquals(unknown.getAfter(),StockMeasurementHoldAuditProjection.snapshot(unknown.getTargetType(),unknown.getAfter()));
    }

    private static AuditLog log(String action) {
        var value=new AuditLog();value.setAction(action);value.setTargetType(TABLE);value.setTargetId(UUID.randomUUID().toString());
        value.setEventSource("database");value.setEventCategory("data_change");value.setRiskLevel("low");value.setResult("success");return value;
    }
}
