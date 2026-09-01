package com.uten.imp.features.production.quality;

import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.ProductionFinishedInboundReleasePort;
import com.uten.imp.application.port.ProductionFqcRecoveryPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.features.production.quality.ProductionFqcContracts.PassAllBatchRequest;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.Collections;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class ProductionFqcPassAllServiceBehaviorTest {

    @Test
    void committedBatchReplaysItsImmutableDecisionLinksWithoutSideEffects() {
        UUID actorId = UUID.randomUUID();
        UUID batchId = UUID.randomUUID();
        UUID first = UUID.fromString(
                "00000000-0000-0000-0000-000000000001");
        UUID second = UUID.fromString(
                "00000000-0000-0000-0000-000000000002");
        UUID firstEvent = UUID.randomUUID();
        UUID secondEvent = UUID.randomUUID();
        PassAllBatchRequest request = new PassAllBatchRequest(
                List.of(second, first), "fqc-batch-replay-behavior");
        var normalized = ProductionFqcInspectionService
                .normalizePassAllBatch(request);

        Query insert = query(List.of());
        when(insert.executeUpdate()).thenReturn(0);
        Query header = query(Collections.singletonList(new Object[]{
                batchId, normalized.requestHash(), 2
        }));
        Query items = query(List.<Object[]>of(
                new Object[]{first, firstEvent},
                new Object[]{second, secondEvent}));
        Query firstDetail = query(Collections.singletonList(
                viewRow(first, "RB-1")));
        Query secondDetail = query(Collections.singletonList(
                viewRow(second, "RB-2")));
        Fixture fixture = fixture(
                actorId, insert, header, items, firstDetail, secondDetail);

        var result = fixture.service().passAll(request);

        assertThat(result.batchId()).isEqualTo(batchId);
        assertThat(result.replay()).isTrue();
        assertThat(result.items())
                .extracting(item -> item.inspectionId())
                .containsExactly(first, second);
        assertThat(result.items())
                .extracting(item -> item.decisionEventId())
                .containsExactly(firstEvent, secondEvent);
        verifyNoInteractions(
                fixture.finishedInbound(), fixture.recovery(), fixture.outbox());
    }

    @Test
    void sameActorAndKeyWithDifferentSelectionConflictsBeforeBusinessLocks() {
        UUID actorId = UUID.randomUUID();
        UUID batchId = UUID.randomUUID();
        UUID inspectionId = UUID.randomUUID();
        PassAllBatchRequest request = new PassAllBatchRequest(
                List.of(inspectionId), "fqc-batch-conflict-behavior");

        Query insert = query(List.of());
        when(insert.executeUpdate()).thenReturn(0);
        Query header = query(Collections.singletonList(new Object[]{
                batchId, "0".repeat(64), 2
        }));
        Fixture fixture = fixture(actorId, insert, header);

        assertThatThrownBy(() -> fixture.service().passAll(request))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("不同任务集合");
        verifyNoInteractions(
                fixture.finishedInbound(), fixture.recovery(), fixture.outbox());
    }

    private static Fixture fixture(
            UUID actorId,
            Query... queries) {
        EntityManager em = mock(EntityManager.class);
        when(em.createNativeQuery(anyString())).thenReturn(
                queries[0], java.util.Arrays.copyOfRange(
                        queries, 1, queries.length));
        SecurityContextCurrentUser currentUser =
                mock(SecurityContextCurrentUser.class);
        when(currentUser.requireId()).thenReturn(actorId);
        ProductionFqcTaskAccessPolicy taskAccess =
                mock(ProductionFqcTaskAccessPolicy.class);
        ProductionFqcRecoveryPort recovery =
                mock(ProductionFqcRecoveryPort.class);
        ProductionFinishedInboundReleasePort finishedInbound =
                mock(ProductionFinishedInboundReleasePort.class);
        BusinessEventPublisher outbox = mock(BusinessEventPublisher.class);
        ProductionFqcInspectionService service =
                new ProductionFqcInspectionService(
                        em,
                        currentUser,
                        mock(TxSessionVars.class),
                        mock(ProductionDocumentAccessPolicy.class),
                        taskAccess,
                        recovery,
                        finishedInbound,
                        outbox);
        return new Fixture(service, recovery, finishedInbound, outbox);
    }

    private static Query query(List<?> rows) {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), org.mockito.ArgumentMatchers.any()))
                .thenReturn(query);
        when(query.getResultList()).thenReturn(rows);
        return query;
    }

    private static Object[] viewRow(UUID inspectionId, String reportNo) {
        return new Object[]{
                inspectionId,
                UUID.randomUUID(),
                UUID.randomUUID(),
                reportNo,
                UUID.randomUUID(),
                UUID.randomUUID(),
                "PLAN-1",
                UUID.randomUUID(),
                null,
                UUID.randomUUID(),
                UUID.randomUUID(),
                "GOODS-1",
                "测试货品",
                null,
                null,
                UUID.randomUUID(),
                "件",
                BigDecimal.ONE,
                new BigDecimal("10.0000"),
                new BigDecimal("10.0000"),
                BigDecimal.ZERO.setScale(4),
                new BigDecimal("10.0000"),
                "RESOLVED",
                UUID.randomUUID(),
                OffsetDateTime.parse("2026-08-30T00:00:00Z"),
                OffsetDateTime.parse("2026-08-30T00:01:00Z")
        };
    }

    private record Fixture(
            ProductionFqcInspectionService service,
            ProductionFqcRecoveryPort recovery,
            ProductionFinishedInboundReleasePort finishedInbound,
            BusinessEventPublisher outbox) {
    }
}
