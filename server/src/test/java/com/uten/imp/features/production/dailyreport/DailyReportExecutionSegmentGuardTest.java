package com.uten.imp.features.production.dailyreport;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.features.production.dailyreport.dto.DailyReportItemLine;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.Collections;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.when;

class DailyReportExecutionSegmentGuardTest {

    @Test
    void crossPlanSegmentIsRejectedByExactPlanItemIdentity() {
        Fixture fixture = fixture("IN_PROGRESS", "10", "0");
        DailyReportItemLine line = fixture.line("2");
        line.setPlanItemId(UUID.randomUUID());

        ApiException error = assertThrows(
                ApiException.class,
                () -> fixture.guard.validateDraft(
                        UUID.randomUUID(), List.of(line)));

        assertTrue(error.getMessage().contains("计划行或产品维度不一致"));
    }

    @Test
    void cumulativeReportCannotExceedSegmentPlan() {
        Fixture fixture = fixture("IN_PROGRESS", "10", "8");

        ApiException error = assertThrows(
                ApiException.class,
                () -> fixture.guard.validateDraft(
                        UUID.randomUUID(),
                        List.of(fixture.line("3"))));

        assertTrue(error.getMessage().contains("累计报工超过计划数量"));
    }

    @Test
    void partialReportsCanReachButNotExceedPlan() {
        Fixture fixture = fixture("IN_PROGRESS", "10", "4");

        assertDoesNotThrow(() -> fixture.guard.validateDraft(
                UUID.randomUUID(),
                List.of(fixture.line("6"))));
    }

    @Test
    void dispatchedSegmentCannotBeReportedBeforeFormalStart() {
        Fixture fixture = fixture("DISPATCHED", "10", "0");

        ApiException error = assertThrows(
                ApiException.class,
                () -> fixture.guard.validateDraft(
                        UUID.randomUUID(),
                        List.of(fixture.line("2"))));

        assertTrue(error.getMessage().contains("完成仓库发料并正式开工"));
    }

    @Test
    void inProgressSegmentAcceptsAValidReport() {
        Fixture fixture = fixture("IN_PROGRESS", "10", "0");

        assertDoesNotThrow(() -> fixture.guard.validateDraft(
                UUID.randomUUID(),
                List.of(fixture.line("2"))));
    }

    @Test
    void inaccessiblePlanSegmentCannotBeReportedByUuid() {
        Fixture fixture = fixture("IN_PROGRESS", "10", "0");
        doThrow(new ApiException(ErrorCode.NOT_FOUND, "执行段不存在"))
                .when(fixture.access)
                .requireReadable(
                        fixture.planMakerId,
                        "报工关联的执行段不存在");

        ApiException error = assertThrows(
                ApiException.class,
                () -> fixture.guard.validateDraft(
                        UUID.randomUUID(),
                        List.of(fixture.line("2"))));

        assertTrue(error.getMessage().contains("执行段不存在"));
    }

    private static Fixture fixture(
            String status, String planned, String existing) {
        UUID segmentId = UUID.randomUUID();
        UUID planItemId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        UUID unitId = UUID.randomUUID();
        UUID planMakerId = UUID.randomUUID();
        EntityManager em = mock(EntityManager.class);
        ProductionDocumentAccessPolicy access =
                mock(ProductionDocumentAccessPolicy.class);

        Query lock = query();
        when(lock.getResultList()).thenReturn(Collections.singletonList(new Object[]{
                segmentId,
                planItemId,
                goodsId,
                null,
                unitId,
                new BigDecimal("1"),
                new BigDecimal(planned),
                status,
                "SEG-001",
                "CONFIRMED",
                planMakerId
        }));
        Query cumulative = query();
        when(cumulative.getSingleResult()).thenReturn(new BigDecimal(existing));
        when(em.createNativeQuery(anyString())).thenReturn(lock, cumulative);
        return new Fixture(
                new DailyReportExecutionSegmentGuard(em, access),
                segmentId,
                planItemId,
                goodsId,
                unitId,
                planMakerId,
                access);
    }

    private static Query query() {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), org.mockito.ArgumentMatchers.any()))
                .thenReturn(query);
        return query;
    }

    private record Fixture(
            DailyReportExecutionSegmentGuard guard,
            UUID segmentId,
            UUID planItemId,
            UUID goodsId,
            UUID unitId,
            UUID planMakerId,
            ProductionDocumentAccessPolicy access) {
        DailyReportItemLine line(String qty) {
            DailyReportItemLine line = new DailyReportItemLine();
            line.setExecutionSegmentId(segmentId);
            line.setPlanItemId(planItemId);
            line.setGoodsId(goodsId);
            line.setUnitId(unitId);
            line.setUnitRate(BigDecimal.ONE);
            line.setQty(new BigDecimal(qty));
            return line;
        }
    }
}
