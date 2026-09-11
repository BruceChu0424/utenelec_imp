package com.uten.imp.features.production.quality;

import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.ProductionFinishedInboundReleasePort;
import com.uten.imp.application.port.ProductionFqcRecoveryPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.features.production.quality.ProductionFqcContracts.DecisionRequest;
import com.uten.imp.features.production.quality.ProductionFqcContracts.PassAllBatchRequest;
import com.uten.imp.security.DocumentAccessPolicy.NativeReadScope;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ProductionFqcInspectionServiceTest {

    @Test
    void fullPassWithoutQuantityUsesExactRemainingQuantity() {
        var normalized = ProductionFqcInspectionService.normalizeRequest(
                request("PASS", null, null, null, null, "fqc-pass-0001"));

        var resolved = normalized.resolve(new BigDecimal("7.5000"));

        assertThat(resolved.decision()).isEqualTo("PASS");
        assertThat(resolved.passQty()).isEqualByComparingTo("7.5000");
        assertThat(resolved.failQty()).isZero();
        assertThat(normalized.requestHash()).hasSize(64);
    }

    @Test
    void mixedPartialRequiresBothQuantitiesReasonAndDisposition() {
        var normalized = ProductionFqcInspectionService.normalizeRequest(
                request("PARTIAL", new BigDecimal("6"), new BigDecimal("2"),
                        "rework", "外观不良返工", "fqc-partial-01"));

        var resolved = normalized.resolve(new BigDecimal("10"));

        assertThat(resolved.passQty()).isEqualByComparingTo("6");
        assertThat(resolved.failQty()).isEqualByComparingTo("2");
        assertThat(resolved.dispositionCode()).isEqualTo("REWORK");
        assertThat(resolved.reason()).isEqualTo("外观不良返工");
    }

    @Test
    void failWithoutReasonOrDispositionFailsClosed() {
        assertThatThrownBy(() -> ProductionFqcInspectionService.normalizeRequest(
                request("FAIL", null, null, null, null, "fqc-fail-0001")))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("处置码");

        assertThatThrownBy(() -> ProductionFqcInspectionService.normalizeRequest(
                request("FAIL", null, null, "SCRAP", null, "fqc-fail-0002")))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("差异原因");
    }

    @Test
    void decisionsCannotExceedRemainingAndPrecisionIsExact() {
        var normalized = ProductionFqcInspectionService.normalizeRequest(
                request("PASS", new BigDecimal("5.0000"), null,
                        null, null, "fqc-pass-0002"));

        assertThatThrownBy(() -> normalized.resolve(new BigDecimal("4.9999")))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("超过待检数量");

        assertThatThrownBy(() -> ProductionFqcInspectionService.normalizeQty(
                new BigDecimal("1.00001"), "质检数量"))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("4 位小数");
    }

    @Test
    void canonicalRequestHashMakesEquivalentQuantitiesReplayCompatible() {
        var first = ProductionFqcInspectionService.normalizeRequest(
                request("PASS", new BigDecimal("5.0"), null,
                        null, "  正常放行  ", "fqc-replay-01"));
        var replay = ProductionFqcInspectionService.normalizeRequest(
                request("pass", new BigDecimal("5.0000"), null,
                        null, "正常放行", "fqc-replay-01"));

        assertThat(first.requestHash()).isEqualTo(replay.requestHash());
        assertThat(first.idempotencyKey()).isEqualTo("fqc-replay-01");
    }

    @Test
    void decisionKeysRemainWithinDatabaseBoundary() {
        assertThatThrownBy(() ->
                ProductionFqcInspectionService.normalizeDecisionKey("a".repeat(129)))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("128");
        assertThat(ProductionFqcInspectionService.normalizeKey("release-key-001"))
                .isEqualTo("release-key-001");
    }

    @Test
    void cancelledIsAValidHistoricalStatusFilter() {
        assertThat(
                ProductionFqcInspectionService.normalizeStatusFilter(
                        "cancelled"))
                .isEqualTo("CANCELLED");
    }

    @Test
    void passAllNormalizationRejectsEmptyDuplicateAndOversizedSelections() {
        assertThatThrownBy(() ->
                ProductionFqcInspectionService.normalizePassAllBatch(
                        new PassAllBatchRequest(List.of(), "fqc-batch-empty")))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("1-100");

        UUID duplicate = UUID.randomUUID();
        assertThatThrownBy(() ->
                ProductionFqcInspectionService.normalizePassAllBatch(
                        new PassAllBatchRequest(
                                List.of(duplicate, duplicate),
                                "fqc-batch-duplicate")))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("不能重复");

        List<UUID> tooMany = new ArrayList<>();
        for (int i = 1; i <= 101; i++) {
            tooMany.add(new UUID(0, i));
        }
        assertThatThrownBy(() ->
                ProductionFqcInspectionService.normalizePassAllBatch(
                        new PassAllBatchRequest(
                                tooMany, "fqc-batch-too-many")))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("1-100");
    }

    @Test
    void passAllReverseInputHasOneStableLockOrderAndRequestHash() {
        UUID first = UUID.fromString(
                "00000000-0000-0000-0000-000000000001");
        UUID second = UUID.fromString(
                "f0000000-0000-0000-0000-000000000002");
        var forward = ProductionFqcInspectionService.normalizePassAllBatch(
                new PassAllBatchRequest(
                        List.of(first, second), "fqc-batch-order-01"));
        var reverse = ProductionFqcInspectionService.normalizePassAllBatch(
                new PassAllBatchRequest(
                        List.of(second, first), "fqc-batch-order-01"));

        assertThat(forward.inspectionIds()).containsExactly(first, second);
        assertThat(reverse.inspectionIds()).isEqualTo(forward.inspectionIds());
        assertThat(reverse.requestHash()).isEqualTo(forward.requestHash());
    }

    @Test
    void passAllSameKeyReplaysOnlyTheSameNormalizedSelection() {
        UUID first = UUID.randomUUID();
        UUID second = UUID.randomUUID();
        var request = ProductionFqcInspectionService.normalizePassAllBatch(
                new PassAllBatchRequest(
                        List.of(second, first), "fqc-batch-replay-01"));
        assertThatCode(() ->
                ProductionFqcInspectionService.requirePassAllReplayCompatible(
                        request.requestHash(), 2, request))
                .doesNotThrowAnyException();

        var different = ProductionFqcInspectionService.normalizePassAllBatch(
                new PassAllBatchRequest(
                        List.of(first), "fqc-batch-replay-01"));
        assertThatThrownBy(() ->
                ProductionFqcInspectionService.requirePassAllReplayCompatible(
                        request.requestHash(), 2, different))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("不同任务集合");
    }

    @Test
    void passAllChildKeysAreDeterministicAndWithinDecisionBoundary() {
        UUID batchId = UUID.randomUUID();
        UUID inspectionId = UUID.randomUUID();
        String first = ProductionFqcInspectionService.passAllChildKey(
                batchId, inspectionId);

        assertThat(first)
                .isEqualTo(ProductionFqcInspectionService.passAllChildKey(
                        batchId, inspectionId))
                .hasSizeLessThanOrEqualTo(128);
        assertThat(ProductionFqcInspectionService.normalizeDecisionKey(first))
                .isEqualTo(first);
    }

    @Test
    void passAllServiceKeepsOneAtomicTransactionAndExactPermissions()
            throws Exception {
        var method = ProductionFqcInspectionService.class.getMethod(
                "passAll", PassAllBatchRequest.class);
        assertThat(method.getAnnotation(Transactional.class)).isNotNull();
        assertThat(method.getAnnotation(PreAuthorize.class).value())
                .contains("production_quality_inspection:view")
                .contains("production_quality_inspection:approve");
    }

    @Test
    void activeCountQuerySeparatesQualityPoolPredicateFromAnd() {
        EntityManager em = mock(EntityManager.class);
        Query query = countQuery(em, 3L);
        ProductionDocumentAccessPolicy productionAccess =
                mock(ProductionDocumentAccessPolicy.class);
        ProductionFqcTaskAccessPolicy taskAccess =
                mock(ProductionFqcTaskAccessPolicy.class);
        when(taskAccess.canAccessQualityPool()).thenReturn(true);

        long count = service(em, productionAccess, taskAccess).countActive();

        assertThat(count).isEqualTo(3L);
        String sql = capturedSql(em).replaceAll("\\s+", " ").trim();
        assertThat(sql)
                .contains("WHERE inspection.status IN ('PENDING','PARTIAL') AND 1=1")
                .doesNotContain("AND1=1");
        verify(query, never()).setParameter(anyString(), any());
    }

    @Test
    void activeCountQuerySeparatesRestrictedOwnerPredicateFromAnd() {
        EntityManager em = mock(EntityManager.class);
        countQuery(em, 1L);
        ProductionDocumentAccessPolicy productionAccess =
                mock(ProductionDocumentAccessPolicy.class);
        ProductionFqcTaskAccessPolicy taskAccess =
                mock(ProductionFqcTaskAccessPolicy.class);
        when(taskAccess.canAccessQualityPool()).thenReturn(false);
        when(productionAccess.nativeReadScope(
                eq("report.maker_id"),
                eq("fqcCountOwners"),
                any(String[].class)))
                .thenReturn(new NativeReadScope(
                        "report.maker_id IS NULL", null, Set.of()));

        long count = service(em, productionAccess, taskAccess).countActive();

        assertThat(count).isEqualTo(1L);
        String sql = capturedSql(em).replaceAll("\\s+", " ").trim();
        assertThat(sql)
                .contains("AND report.maker_id IS NULL")
                .doesNotContain("ANDreport.maker_id");
    }

    private static Query countQuery(EntityManager em, long result) {
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.getSingleResult()).thenReturn(result);
        return query;
    }

    private static String capturedSql(EntityManager em) {
        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em).createNativeQuery(sql.capture());
        return sql.getValue();
    }

    private static ProductionFqcInspectionService service(
            EntityManager em,
            ProductionDocumentAccessPolicy productionAccess,
            ProductionFqcTaskAccessPolicy taskAccess) {
        return new ProductionFqcInspectionService(
                em,
                mock(SecurityContextCurrentUser.class),
                mock(TxSessionVars.class),
                productionAccess,
                taskAccess,
                mock(ProductionFqcRecoveryPort.class),
                mock(ProductionFinishedInboundReleasePort.class),
                mock(BusinessEventPublisher.class),
                org.mockito.Mockito.mock(com.uten.imp.features.production.quality.ProductionQualityMutationFootprintService.class, org.mockito.Mockito.RETURNS_DEEP_STUBS),
                org.mockito.Mockito.mock(com.uten.imp.common.docnumber.DocNumberService.class));
    }

    private static DecisionRequest request(
            String decision,
            BigDecimal pass,
            BigDecimal fail,
            String disposition,
            String reason,
            String key) {
        return new DecisionRequest(
                decision, pass, fail, disposition, reason, key);
    }
}
