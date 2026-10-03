package com.uten.imp.audit;

import com.fasterxml.jackson.databind.json.JsonMapper;
import com.fasterxml.jackson.datatype.jsr310.JavaTimeModule;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

import static org.assertj.core.api.Assertions.assertThat;

class AuditLegacyColumnProjectionTest {
    private static final JsonMapper JSON = JsonMapper.builder().addModule(new JavaTimeModule()).build();
    private static final List<String> LEGACY_TABLES = List.of(
            "sales_quote_items", "sales_order_items", "purchase_order_items", "subcontract_order_items");
    private final AuditEventInterpreter interpreter = new AuditEventInterpreter();

    @ParameterizedTest
    @ValueSource(strings = {"sales_quote_items", "sales_order_items", "purchase_order_items", "subcontract_order_items"})
    void fullSnapshotsArePrunedBeforeDetailListAndExportInterpretationWithoutMutatingStoredEvidence(String table)
            throws Exception {
        String before = """
                {"qty":1,"extra_columns":[{"name":"secret-name-before","value":"secret-value-before",
                  "formula":{"constant":"secret-formula-before"}}]}
                """;
        String after = before.replace("before", "after").replace("\"qty\":1", "\"qty\":2");
        AuditLog stored = event(table, before, after);

        AuditLogDetail detail = AuditLogDetail.of(stored, interpreter);
        AuditLogRow row = AuditLogRow.of(stored, interpreter);

        assertThat(JSON.readTree(detail.before())).isEqualTo(JSON.readTree("{\"qty\":1}"));
        assertThat(JSON.readTree(detail.after())).isEqualTo(JSON.readTree("{\"qty\":2}"));
        assertThat(JSON.writeValueAsString(detail)).doesNotContain("secret-", "extra_columns");
        assertThat(JSON.writeValueAsString(row)).doesNotContain("secret-", "extra_columns");
        assertThat(detail.changeSummary()).contains("数量：1 → 2", "当前业务范围与价格权限", "旧快照不代表完整字段版本");
        assertThat(row.getChangeSummary()).contains("数量：1 → 2");
        assertThat(detail.before()).doesNotContain("version", "cells", "scope");
        assertThat(stored.getBefore()).isEqualTo(before);
        assertThat(stored.getAfter()).isEqualTo(after);
    }

    @ParameterizedTest
    @ValueSource(strings = {"sales_quote_items", "sales_order_items", "purchase_order_items", "subcontract_order_items"})
    void removesWholeLegacyBranchesRecursivelyAcrossObjectsArraysAndBothSerializedNames(String table)
            throws Exception {
        String raw = """
                {"id":"item-1","extraColumns":"secret-encoded-payload",
                 "wrapper":{"extra_columns":{"value":"secret-object-value"},"safe":"retained"},
                 "items":[{"extraColumns":[{"value":"secret-array-value"}],"qty":3},
                          [{"extra_columns":null,"safe":true}],null,4]}
                """;
        String expected = """
                {"id":"item-1","wrapper":{"safe":"retained"},
                 "items":[{"qty":3},[{"safe":true}],null,4]}
                """;

        String projected = PlatformFieldAuditProjection.snapshot(table, raw);

        assertThat(JSON.readTree(projected)).isEqualTo(JSON.readTree(expected));
        assertThat(projected).doesNotContain("secret-", "extra_columns", "extraColumns");
        assertThat(PlatformFieldAuditProjection.snapshot(table, projected)).isEqualTo(projected);
    }

    @ParameterizedTest
    @ValueSource(strings = {"sales_quote_items", "sales_order_items", "purchase_order_items", "subcontract_order_items"})
    void metadataMarkerCannotBypassLegacyPruningInInterpreterOrList(String table) throws Exception {
        for (String kind : List.of("business_detail_view", "audit_evidence_view")) {
            String before = "{\"view_metadata_kind\":\"" + kind
                    + "\",\"extra_columns\":[{\"value\":\"secret-before\"}]}";
            String after = before.replace("secret-before", "secret-after");
            AuditLog stored = event(table, before, after);

            AuditLog projected = PlatformFieldAuditProjection.presentation(stored);
            assertThat(projected).isNotSameAs(stored);
            assertThat(projected.getBefore() + projected.getAfter()).doesNotContain("secret-", "extra_columns");
            assertThat(JSON.writeValueAsString(interpreter.interpret(stored))).doesNotContain("secret-", "extra_columns");
            assertThat(JSON.writeValueAsString(AuditLogRow.of(stored, interpreter))).doesNotContain("secret-", "extra_columns");
            AuditLogDetail detail = AuditLogDetail.of(stored, interpreter);
            assertThat(detail.before()).isNull();
            assertThat(detail.after()).isNull();
            assertThat(JSON.writeValueAsString(detail)).doesNotContain("secret-", "extra_columns");
            assertThat(stored.getBefore()).isEqualTo(before);
            assertThat(stored.getAfter()).isEqualTo(after);
        }
    }

    @Test
    void unreadableOrNonObjectLegacySnapshotsFailClosedAndNullSnapshotsStayNull() throws Exception {
        for (String table : LEGACY_TABLES) {
            assertThat(PlatformFieldAuditProjection.snapshot(table, null)).isNull();
            for (String raw : List.of("", "{\"extra_columns\":secret-unreadable}", "null", "42",
                    "\"secret-scalar\"", "[{\"extra_columns\":\"secret-array\"}]")) {
                AuditLog stored = event(table, raw, raw);
                AuditLogDetail detail = AuditLogDetail.of(stored, interpreter);
                assertThat(detail.before()).isNull();
                assertThat(detail.after()).isNull();
                assertThat(JSON.writeValueAsString(detail)).doesNotContain("secret-");
                assertThat(JSON.writeValueAsString(AuditLogRow.of(stored, interpreter))).doesNotContain("secret-");
                assertThat(stored.getBefore()).isEqualTo(raw);
                assertThat(stored.getAfter()).isEqualTo(raw);
            }
        }
    }

    @Test
    void unrelatedEntitiesKeepOriginalSnapshotBytesAndExistingInterpretation() {
        String before = " {\"code\":\"OLD-CODE\",\"extra_columns\":[{\"value\":\"old-value\"}]} ";
        String after = before.replace("OLD-CODE", "NEW-CODE").replace("old-value", "new-value");
        for (String table : List.of("goods", "sales_orders", "purchase_orders", "subcontract_orders", "sales_quotes")) {
            AuditLog stored = event(table, before, after);
            AuditLogDetail detail = AuditLogDetail.of(stored, interpreter);
            assertThat(PlatformFieldAuditProjection.presentation(stored)).isSameAs(stored);
            assertThat(detail.before()).isEqualTo(before);
            assertThat(detail.after()).isEqualTo(after);
            assertThat(detail.changeSummary()).contains("OLD-CODE", "NEW-CODE").doesNotContain("旧扩展字段原值已隐藏");
        }
    }

    @Test
    void pruningKeepsExactNativeDecimalValuesWhileStoredEvidenceStaysUnchanged() throws Exception {
        String raw = """
                {"qty":99999999999999.1234,"unit_price":0.12345678901234567890123456789,
                 "extra_columns":[{"value":"secret-value"}],
                 "items":[{"qty":-0.0000000000000000001234567890123456789,"extraColumns":"secret"}]}
                """;
        var exact = JsonMapper.builder()
                .enable(com.fasterxml.jackson.databind.DeserializationFeature.USE_BIG_DECIMAL_FOR_FLOATS).build();
        var stored = event("sales_order_items", raw, raw);
        var detail = AuditLogDetail.of(stored, interpreter);
        var original = exact.readTree(raw);
        var projected = exact.readTree(detail.before());
        assertThat(projected.get("qty").decimalValue()).isEqualByComparingTo(original.get("qty").decimalValue());
        assertThat(projected.get("unit_price").decimalValue()).isEqualByComparingTo(original.get("unit_price").decimalValue());
        assertThat(projected.get("items").get(0).get("qty").decimalValue())
                .isEqualByComparingTo(original.get("items").get(0).get("qty").decimalValue());
        assertThat(detail.before()).doesNotContain("secret", "extra_columns", "extraColumns");
        assertThat(stored.getBefore()).isEqualTo(raw);
        assertThat(stored.getAfter()).isEqualTo(raw);
    }

    private static AuditLog event(String table, String before, String after) {
        AuditLog log = new AuditLog();
        log.setAction("update");
        log.setTargetType(table);
        log.setBefore(before);
        log.setAfter(after);
        log.setResult("success");
        log.setEventSource("data_change");
        return log;
    }
}
