package com.uten.imp.features.production.quality;

import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.ProductionFinishedInboundReleasePort;
import com.uten.imp.application.port.ProductionFqcRecoveryPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.features.production.quality.ProductionFqcContracts.DecisionRequest;
import com.uten.imp.security.DocumentAccessPolicy.NativeReadScope;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.math.BigDecimal;
import java.util.Set;

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
                mock(BusinessEventPublisher.class));
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
