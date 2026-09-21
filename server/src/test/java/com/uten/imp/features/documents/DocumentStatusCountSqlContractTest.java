package com.uten.imp.features.documents;

import com.uten.imp.features.documents.DocumentDraftCountQueryService.DraftSource;
import com.uten.imp.features.documents.DocumentStatusCountQueryService.Bucket;
import org.junit.jupiter.api.Test;

import java.lang.reflect.RecordComponent;
import java.util.List;
import java.util.Set;
import java.util.stream.Collectors;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 列表页分段计数({@code GET /api/documents/status-counts})的 SQL 形状契约: 单据类型键与草稿计数
 * 响应字段逐字一致, 每类单据的分桶集合固定, DRAFT 桶与草稿计数同一谓词(列表「草稿」段 = hub 卡草稿徽章),
 * 一条 SQL 且只经具名参数下发过滤值.
 */
class DocumentStatusCountSqlContractTest {

    @Test
    void everyDraftCountFieldIsAlsoAStatusCountKind() {
        Set<String> kinds = DocumentStatusCountQueryService.KINDS.keySet();
        Set<String> fields = java.util.Arrays.stream(DraftCountsResponse.class.getRecordComponents())
                .map(RecordComponent::getName)
                .collect(Collectors.toSet());
        assertThat(kinds).as("前端 DraftDocKind 枚举名 = 草稿计数字段名 = 分段计数 kind").isEqualTo(fields);
        for (String kind : kinds) {
            assertThat(DocumentStatusCountQueryService.KINDS.get(kind))
                    .as("kind %s 必须指向 SOURCES 里的声明", kind)
                    .isIn(DocumentDraftCountQueryService.SOURCES);
        }
    }

    @Test
    void bucketsFollowTheDocumentFamily() {
        assertThat(keys("salesShipment")).containsExactly(
                "DRAFT", "PENDING_FINANCE", "FINANCE_REJECTED", "FINANCE_APPROVED", "SHIPPED", "REVERSED");
        for (String kind : List.of("purchaseOrder", "subcontractOrder")) {
            assertThat(keys(kind)).containsExactly(
                    "DRAFT", "PENDING_FINANCE", "FINANCE_REJECTED", "APPROVED", "REVERSED");
        }
        for (String kind : List.of("salesQuote", "salesReturn", "financeReceipt", "productionPlan",
                "purchaseReceipt", "subcontractWaste", "stockDocument", "stockTransfer")) {
            assertThat(keys(kind)).as(kind).containsExactly("DRAFT", "APPROVED", "REVERSED");
        }
        assertThat(DocumentStatusCountQueryService.FINANCE_REJECTED_KINDS)
                .as("带财务已退回桶的类型集合 = hub 卡「草稿 + 财务已退回」徽章的类型集合")
                .containsExactlyElementsOf(DocumentStatusCountQueryService.KINDS.keySet().stream()
                        .filter(kind -> keys(kind).contains("FINANCE_REJECTED"))
                        .sorted(java.util.Comparator.comparingInt(
                                DocumentStatusCountQueryService.FINANCE_REJECTED_KINDS::indexOf))
                        .toList());
    }

    /** DRAFT 桶就是草稿计数的口径: 同一 extraPredicate, 列表「草稿」段与 hub 卡草稿徽章才会同数. */
    @Test
    void draftBucketReusesTheDraftCountPredicate() {
        for (var entry : DocumentStatusCountQueryService.KINDS.entrySet()) {
            DraftSource source = entry.getValue();
            String expected = "o.status = 0"
                    + (source.extraPredicate() == null ? "" : " AND " + source.extraPredicate());
            Bucket draft = DocumentStatusCountQueryService.bucketsOf(entry.getKey(), source).getFirst();
            assertThat(draft.key()).isEqualTo("DRAFT");
            assertThat(draft.predicate()).as(entry.getKey()).isEqualTo(expected);
        }
    }

    @Test
    void salesShipmentBucketsMirrorTheListStagePredicates() {
        DraftSource source = DocumentDraftCountQueryService.SALES_SHIPMENT;
        List<Bucket> buckets = DocumentStatusCountQueryService.bucketsOf("salesShipment", source);
        assertThat(predicate(buckets, "FINANCE_REJECTED"))
                .isEqualTo("o.status = 0 AND o.shipment_kind <> 'LEGACY' AND o.finance_rejected = true");
        assertThat(predicate(buckets, "FINANCE_APPROVED"))
                .isEqualTo("o.status = 0 AND o.shipment_kind <> 'LEGACY' AND o.rejected = false AND o.finance_audit = 1");
        assertThat(predicate(buckets, "PENDING_FINANCE"))
                .contains("o.finance_audit = 0")
                .contains("o.finance_gate_version < 2 OR (o.sales_confirmed_at IS NOT NULL");
        assertThat(predicate(buckets, "SHIPPED")).isEqualTo("o.status = 1");
        assertThat(predicate(buckets, "REVERSED")).isEqualTo("o.status = -1");
    }

    @Test
    void procurementOrderBucketsSplitByLatestApprovalCase() {
        for (String kind : List.of("purchaseOrder", "subcontractOrder")) {
            String orderType = "purchaseOrder".equals(kind) ? "PURCHASE" : "SUBCONTRACT";
            String latest = DocumentDraftCountQueryService.latestApprovalCaseStatusSql(orderType);
            List<Bucket> buckets = DocumentStatusCountQueryService.bucketsOf(
                    kind, DocumentStatusCountQueryService.KINDS.get(kind));
            assertThat(predicate(buckets, "PENDING_FINANCE")).isEqualTo("o.status = 0 AND " + latest + " = 'PENDING'");
            assertThat(predicate(buckets, "FINANCE_REJECTED")).isEqualTo("o.status = 0 AND " + latest + " = 'REJECTED'");
            assertThat(predicate(buckets, "DRAFT")).isEqualTo("o.status = 0 AND " + latest + " NOT IN ('PENDING', 'REJECTED')");
        }
    }

    @Test
    void countSqlIsASingleStatementWithScopeAndNamedFilters() {
        DraftSource source = DocumentDraftCountQueryService.SALES_SHIPMENT;
        String plain = DocumentStatusCountQueryService.countSql("salesShipment", source, "owner_scope", false, false);
        assertThat(plain)
                .startsWith("SELECT COUNT(*) FILTER (WHERE o.status = 0 AND ")
                .endsWith(" FROM sales_shipments o WHERE o.is_deleted = false AND owner_scope")
                .doesNotContain(";")
                .doesNotContain(":shipmentKind")
                .doesNotContain(":docType");
        assertThat(plain.split("COUNT\\(\\*\\) FILTER")).hasSize(7);
        String sliced = DocumentStatusCountQueryService.countSql("salesShipment", source, "owner_scope", true, false);
        assertThat(sliced).endsWith(" AND owner_scope AND o.shipment_kind = :shipmentKind");
        String stock = DocumentStatusCountQueryService.countSql(
                "stockDocument", DocumentDraftCountQueryService.STOCK_DOCUMENT, "1=1", false, true);
        assertThat(stock).endsWith(" FROM stock_documents o WHERE o.is_deleted = false AND 1=1 AND o.doc_type = :docType");
    }

    private static List<String> keys(String kind) {
        return DocumentStatusCountQueryService.bucketsOf(kind, DocumentStatusCountQueryService.KINDS.get(kind))
                .stream().map(Bucket::key).toList();
    }

    private static String predicate(List<Bucket> buckets, String key) {
        return buckets.stream().filter(bucket -> key.equals(bucket.key())).findFirst().orElseThrow().predicate();
    }
}
