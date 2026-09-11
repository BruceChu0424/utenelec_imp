package com.uten.imp.features.production.dailyreport;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.features.production.dailyreport.dto.DailyReportItemLine;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.security.SecurityContextCurrentUser;
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
import static org.mockito.Mockito.verify;
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
                        UUID.randomUUID(), fixture.workshopId, List.of(line)));

        assertTrue(error.getMessage().contains("计划行或产品维度不一致"));
    }

    @Test
    void cumulativeReportCannotExceedSegmentPlan() {
        Fixture fixture = fixture("IN_PROGRESS", "10", "8");

        ApiException error = assertThrows(
                ApiException.class,
                () -> fixture.guard.validateDraft(
                        UUID.randomUUID(),
                        fixture.workshopId,
                        List.of(fixture.line("3"))));

        assertTrue(error.getMessage().contains("累计报工超过计划数量"));
    }

    @Test
    void partialReportsCanReachButNotExceedPlan() {
        Fixture fixture = fixture("IN_PROGRESS", "10", "4");

        assertDoesNotThrow(() -> fixture.guard.validateDraft(
                UUID.randomUUID(),
                fixture.workshopId,
                List.of(fixture.line("6"))));
    }

    @Test
    void unstartedSegmentsCannotUseReportingToStartEvenWithNoMaterialRequirement() {
        for (String status : List.of("READY", "DISPATCHED")) {
            Fixture fixture = fixture(status, "10", "0");
            ApiException error = assertThrows(ApiException.class,
                    () -> fixture.guard.validateDraft(UUID.randomUUID(),
                            fixture.workshopId, List.of(fixture.line("2"))));
            assertTrue(error.getMessage().contains("开工后才能报工"));
        }
    }

    @Test
    void demandedReadySegmentCannotReportBeforeExplicitStart() {
        Fixture fixture = fixture(
                "READY", "10", "0", "DEMANDED", "ALLOCATED");

        ApiException error = assertThrows(
                ApiException.class,
                () -> fixture.guard.validateDraft(
                        UUID.randomUUID(),
                        fixture.workshopId,
                        List.of(fixture.line("2"))));

        assertTrue(error.getMessage().contains("开工后才能报工"));
    }

    @Test
    void inProgressSegmentAcceptsAValidReport() {
        Fixture fixture = fixture("IN_PROGRESS", "10", "0");

        assertDoesNotThrow(() -> fixture.guard.validateDraft(
                UUID.randomUUID(),
                fixture.workshopId,
                List.of(fixture.line("2"))));
    }

    @Test
    void exactWorkshopAssignmentDoesNotRequirePlanMakerVisibility() {
        Fixture fixture = fixture("IN_PROGRESS", "10", "0");
        doThrow(new ApiException(ErrorCode.NOT_FOUND, "执行段不存在"))
                .when(fixture.access)
                .requireReadable(
                        fixture.planMakerId,
                        "报工关联的执行段不存在");

        assertDoesNotThrow(() -> fixture.guard.validateDraft(
                UUID.randomUUID(),
                fixture.workshopId,
                List.of(fixture.line("2"))));
    }

    @Test
    void missingWorkshopTaskPermissionCannotReportByKnownUuid() {
        Fixture fixture = fixture("IN_PROGRESS", "10", "0");
        when(fixture.access.hasAuthority("production_execution:view"))
                .thenReturn(false);

        ApiException error = assertThrows(
                ApiException.class,
                () -> fixture.guard.validateDraft(
                        UUID.randomUUID(),
                        fixture.workshopId,
                        List.of(fixture.line("2"))));

        assertTrue(error.getMessage().contains("车间生产任务查看权限"));
    }

    @Test
    void inactiveResponsibleCannotBypassWorkshopEligibility() {
        Fixture fixture = fixture(
                "IN_PROGRESS", "10", "0", "ZERO_MATERIAL", null, false);

        ApiException error = assertThrows(
                ApiException.class,
                () -> fixture.guard.validateDraft(
                        UUID.randomUUID(),
                        fixture.workshopId,
                        List.of(fixture.line("2"))));

        assertTrue(error.getMessage().contains("本人所属、兼职、负责或管理车间"));
    }

    @Test
    void oneReportCannotMixAnotherWorkshopHeader() {
        Fixture fixture = fixture("IN_PROGRESS", "10", "0");

        ApiException error = assertThrows(
                ApiException.class,
                () -> fixture.guard.validateDraft(
                        UUID.randomUUID(),
                        UUID.randomUUID(),
                        List.of(fixture.line("2"))));

        assertTrue(error.getMessage().contains("车间必须与所选执行工单车间一致"));
    }

    private static Fixture fixture(
            String status, String planned, String existing) {
        return fixture(
                status, planned, existing, "ZERO_MATERIAL", null);
    }

    private static Fixture fixture(
            String status,
            String planned,
            String existing,
            String materialMode,
            String demandStatus) {
        return fixture(
                status, planned, existing, materialMode, demandStatus, true);
    }

    private static Fixture fixture(
            String status,
            String planned,
            String existing,
            String materialMode,
            String demandStatus,
            boolean workshopEligible) {
        UUID segmentId = UUID.randomUUID();
        UUID planItemId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        UUID unitId = UUID.randomUUID();
        UUID planMakerId = UUID.randomUUID();
        UUID workshopId = UUID.randomUUID();
        UUID responsibleEmployeeId = UUID.randomUUID();
        EntityManager em = mock(EntityManager.class);
        ProductionDocumentAccessPolicy access =
                mock(ProductionDocumentAccessPolicy.class);
        SecurityContextCurrentUser currentUser =
                mock(SecurityContextCurrentUser.class);
        ChainNoticeService notices = mock(ChainNoticeService.class);
        when(access.hasAuthority("production_execution:view")).thenReturn(true);
        when(currentUser.requireEmployeeId()).thenReturn(responsibleEmployeeId);
        when(currentUser.requireId()).thenReturn(UUID.randomUUID());

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
                planMakerId,
                workshopId,
                responsibleEmployeeId,
                materialMode,
                7L
        }));
        Query allocation = query();
        when(allocation.getResultList()).thenReturn(List.of());
        Query cumulative = query();
        when(cumulative.getSingleResult()).thenReturn(new BigDecimal(existing));
        if ("IN_PROGRESS".equals(status)) {
            when(em.createNativeQuery(anyString()))
                    .thenReturn(lock, allocation, cumulative);
        } else {
            Query demands = query();
            when(demands.getResultList()).thenReturn(
                    demandStatus == null
                            ? List.of()
                            : Collections.singletonList(new Object[]{
                                    UUID.randomUUID(), demandStatus
                            }));
            Query configOne = scalarQuery("");
            Query configTwo = scalarQuery("");
            Query update = query();
            when(update.executeUpdate()).thenReturn(1);
            Query event = query();
            when(event.executeUpdate()).thenReturn(1);
            Query clearOne = scalarQuery("");
            Query clearTwo = scalarQuery("");
            if ("ZERO_MATERIAL".equals(materialMode)) {
                when(em.createNativeQuery(anyString())).thenReturn(
                        lock,
                        configOne, configTwo, update, event,
                        clearOne, clearTwo, allocation, cumulative);
            } else {
                when(em.createNativeQuery(anyString())).thenReturn(
                        lock, demands,
                        configOne, configTwo, update, event,
                        clearOne, clearTwo, allocation, cumulative);
            }
        }
        // 车间归属判定已抽到 ProductionWorkshopMembership（2026-09-11，与执行段写侧同一份
        // 口径：主职 ∪ 兼职 ∪ 车间子树负责人 ∪ 段负责人本人且在职）。守卫自己不再发那条
        // 递归 CTE 查询，故这里按 fixture 的 workshopEligible 桩住成员判定。
        var workshopMembership = org.mockito.Mockito.mock(
                com.uten.imp.features.production.ProductionWorkshopMembership.class);
        org.mockito.Mockito.when(workshopMembership.isWorkshopMember(
                org.mockito.ArgumentMatchers.any(),
                org.mockito.ArgumentMatchers.any(),
                org.mockito.ArgumentMatchers.any())).thenReturn(workshopEligible);
        return new Fixture(
                new DailyReportExecutionSegmentGuard(
                        em, access, currentUser, workshopMembership),
                segmentId,
                planItemId,
                goodsId,
                unitId,
                planMakerId,
                workshopId,
                access,
                notices);
    }

    private static Query query() {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), org.mockito.ArgumentMatchers.any()))
                .thenReturn(query);
        return query;
    }

    private static Query scalarQuery(Object value) {
        Query query = query();
        when(query.getSingleResult()).thenReturn(value);
        return query;
    }

    private record Fixture(
            DailyReportExecutionSegmentGuard guard,
            UUID segmentId,
            UUID planItemId,
            UUID goodsId,
            UUID unitId,
            UUID planMakerId,
            UUID workshopId,
            ProductionDocumentAccessPolicy access,
            ChainNoticeService notices) {
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
