package com.uten.imp.features.production.analysis;

import com.uten.imp.application.port.ProductionSubcontractRequestPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.Collections;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class SubcontractMakeTaskAutomaticNotificationTest {
    @Test
    void warehouseInboundAutomaticallyNotifiesUnderOriginalAnalysisOwner() {
        Harness h = new Harness(1, UUID.randomUUID());

        h.service.afterFinishedInboundApproved(h.document, h.warehouse);

        verify(h.requests).createProductionDraft(anyString(), eq(h.analysis), any(),
                eq(h.warehouse), anyList(), eq(h.owner), eq(h.owner));
        verifyNoInteractions(h.access);
        verify(h.notices).notifySubcontractMakeNotified(any());
    }

    @Test
    void incompleteLedgerMutationEscapesToRollbackInboundTransaction() {
        Harness h = new Harness(0, UUID.randomUUID());

        assertThatThrownBy(() -> h.service.afterFinishedInboundApproved(h.document, h.warehouse))
                .isInstanceOf(ApiException.class).hasMessageContaining("可通知量已被其他操作使用");

        verifyNoInteractions(h.notices);
    }

    @Test
    void historicalOwnerlessAnalysisDoesNotReassignDemandToWarehouseEmployee() {
        Harness h = new Harness(1, null);

        h.service.afterFinishedInboundApproved(h.document, h.warehouse);

        verifyNoInteractions(h.requests);
        verifyNoInteractions(h.access);
        assertThat(h.producedUpdates).isEqualTo(1);
    }

    private static final class Harness {
        final UUID document = UUID.randomUUID();
        final UUID analysis = UUID.randomUUID();
        final UUID task = UUID.randomUUID();
        final UUID material = UUID.randomUUID();
        final UUID source = UUID.randomUUID();
        final UUID preparation = UUID.randomUUID();
        final UUID goods = UUID.randomUUID();
        final UUID unit = UUID.randomUUID();
        final UUID warehouse = UUID.randomUUID();
        final UUID owner;
        final ProductionSubcontractRequestPort requests = mock(ProductionSubcontractRequestPort.class);
        final ProductionDocumentAccessPolicy access = mock(ProductionDocumentAccessPolicy.class);
        final ChainNoticeService notices = mock(ChainNoticeService.class);
        final SubcontractMakeTaskService service;
        int producedUpdates;

        Harness(int notifiedUpdateResult, UUID owner) {
            this.owner = owner;
            EntityManager em = mock(EntityManager.class);
            when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
                String sql = invocation.getArgument(0);
                Query query = mock(Query.class);
                when(query.setParameter(anyString(), any())).thenReturn(query);
                when(query.getSingleResult()).thenReturn(0L);
                when(query.executeUpdate()).thenAnswer(unused -> {
                    if (sql.contains("SET produced_qty = produced_qty +")) producedUpdates++;
                    return sql.contains("SET notified_qty = notified_qty +") ? notifiedUpdateResult : 1;
                });
                List<?> rows;
                if (sql.contains("SELECT DISTINCT task.analysis_id")) {
                    rows = List.of(analysis);
                } else if (sql.contains("SELECT task.id, stock_item.id")) {
                    rows = Collections.singletonList(new Object[]{task, UUID.randomUUID(), goods, null,
                            BigDecimal.TEN, unit, BigDecimal.ONE, goods, null, unit, BigDecimal.ONE,
                            goods, null, unit, warehouse});
                } else if (sql.contains("AS available_qty")) {
                    rows = Collections.singletonList(new Object[]{task, analysis, material, source,
                            preparation, goods, null, unit, warehouse, BigDecimal.TEN, BigDecimal.TEN,
                            BigDecimal.ZERO, LocalDate.now(), OffsetDateTime.now(), BigDecimal.TEN});
                } else if (sql.contains("SELECT source.action_group_key")) {
                    rows = Collections.singletonList(new Object[]{"a".repeat(64), 1, "b".repeat(64), source});
                } else {
                    rows = List.of();
                }
                when(query.getResultList()).thenReturn(rows);
                return query;
            });
            MaterialAnalysisService analyses = mock(MaterialAnalysisService.class);
            when(analyses.lockHeader(analysis)).thenReturn(new MaterialAnalysisService.AnalysisHeader(
                    analysis, warehouse, "ACTIVE", 0, "a".repeat(64), OffsetDateTime.now(), owner));
            doThrow(new ApiException(ErrorCode.FORBIDDEN, "warehouse cannot edit planning demand"))
                    .when(access).requireWritable(any(), anyString(),
                            any(com.uten.imp.security.OwnerVisibility.OwnerScope.class));
            when(requests.createProductionDraft(anyString(), any(), any(), any(), anyList(), any(), any()))
                    .thenReturn(new ProductionSubcontractRequestPort.DraftResult(UUID.randomUUID(), "TEST-SC",
                            List.of(new ProductionSubcontractRequestPort.DraftLineResult(task,
                                    UUID.randomUUID(), LocalDate.now(), BigDecimal.TEN))));
            SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
            when(current.requireId()).thenReturn(UUID.randomUUID());
            when(current.requireEmployeeId()).thenReturn(UUID.randomUUID());
            service = new SubcontractMakeTaskService(em, analyses, access, requests, notices, current);
        }
    }
}
