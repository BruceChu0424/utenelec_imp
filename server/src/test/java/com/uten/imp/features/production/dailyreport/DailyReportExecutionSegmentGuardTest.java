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
    void publicSurplusCanContinueAfterSalesAllocationIsFullyReported() {
        Fixture fixture = fixture("IN_PROGRESS", "2000", "1000");
        fixture.salesAllocation("1000");
        when(fixture.internalCumulative.getSingleResult()).thenReturn(BigDecimal.ZERO);

        assertDoesNotThrow(() -> fixture.guard.validateDraft(UUID.randomUUID(), fixture.workshopId,
                List.of(fixture.line("1000"))));
    }

    @Test
    void publicReportingCannotUseTheUnreportedSalesQuota() {
        Fixture fixture = fixture("IN_PROGRESS", "2000", "700");
        fixture.salesAllocation("1000");
        when(fixture.internalCumulative.getSingleResult()).thenReturn(new BigDecimal("700"));

        assertDoesNotThrow(() -> fixture.guard.validateDraft(UUID.randomUUID(), fixture.workshopId,
                List.of(fixture.line("300"))));
        ApiException error = assertThrows(ApiException.class, () -> fixture.guard.validateDraft(
                UUID.randomUUID(), fixture.workshopId, List.of(fixture.line("300.0001"))));
        assertTrue(error.getMessage().contains("公共备货累计报工"));
    }

    @Test
    void publicRowsWithinOneDraftShareOneQuota() {
        Fixture fixture = fixture("IN_PROGRESS", "2000", "0");
        fixture.salesAllocation("1000");
        assertThrows(ApiException.class, () -> fixture.guard.validateDraft(UUID.randomUUID(),
                fixture.workshopId, List.of(fixture.line("600"), fixture.line("401"))));
    }

    @Test
    void fullySalesAllocatedTaskCannotDropItsSalesIdentity() {
        Fixture fixture = fixture("IN_PROGRESS", "1000", "0");
        fixture.salesAllocation("1000");
        ApiException error = assertThrows(ApiException.class, () -> fixture.guard.validateDraft(
                UUID.randomUUID(), fixture.workshopId, List.of(fixture.line("1"))));
        assertTrue(error.getMessage().contains("没有公共备货数量"));
    }

    @Test
    void publicSourceCannotCarryOnlyOneHalfOfTheSalesIdentity() {
        Fixture fixture = fixture("IN_PROGRESS", "2000", "0");
        UUID[] sales = fixture.salesAllocation("1000");
        var missingAllocation = fixture.line("1");
        missingAllocation.setSalesOrderItemId(sales[1]);
        var missingOrder = fixture.line("1");
        missingOrder.setExecutionSegmentSalesAllocationId(sales[0]);
        for (var line : List.of(missingAllocation, missingOrder)) {
            assertThrows(ApiException.class, () -> fixture.guard.validateDraft(UUID.randomUUID(),
                    fixture.workshopId, List.of(line)));
        }
    }

    @Test
    void oneReportCanContainSalesAndPublicRowsWithinTheirIndependentQuotas() {
        Fixture fixture=fixture("IN_PROGRESS","2000","0");
        UUID[] source=fixture.salesAllocation("1000");
        DailyReportItemLine sales=fixture.line("1000");
        sales.setExecutionSegmentSalesAllocationId(source[0]);
        sales.setSalesOrderItemId(source[1]);
        assertDoesNotThrow(() -> fixture.guard.validateDraft(UUID.randomUUID(),fixture.workshopId,
                List.of(sales,fixture.line("600"))));
        sales.setQty(new BigDecimal("1000.0001"));
        assertThrows(ApiException.class,() -> fixture.guard.validateDraft(UUID.randomUUID(),fixture.workshopId,
                List.of(sales,fixture.line("1"))));
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
    void terminalPlanCannotSaveANewOrdinaryReportButCanReverseItsOriginalReport() {
        Fixture fixture=fixture("IN_PROGRESS","10","0");
        Object[] snapshot=(Object[])fixture.lock.getResultList().getFirst();
        snapshot[17]=false;
        ApiException error=assertThrows(ApiException.class,() -> fixture.guard.validateDraft(
                UUID.randomUUID(),fixture.workshopId,List.of(fixture.line("1"))));
        assertTrue(error.getMessage().contains("生产计划当前未生效"));
        var item=new ProductionDailyReportItem(); item.setId(UUID.randomUUID());
        item.setExecutionSegmentId(fixture.segmentId); item.setPlanItemId(fixture.planItemId);
        item.setGoodsId(fixture.goodsId); item.setUnitId(fixture.unitId); item.setUnitRate(BigDecimal.ONE);
        item.setQty(BigDecimal.ONE);
        assertDoesNotThrow(() -> fixture.guard.reverse(List.of(item)));
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

    @Test
    void continuousWarehouseSupplyCanReportOnlyItsActualCumulativeCapacity() {
        Fixture fixture = fixture("IN_PROGRESS", "1000", "40", "DEMANDED", "PARTIAL", true, true, "100");
        assertDoesNotThrow(() -> fixture.guard.validateDraft(UUID.randomUUID(), fixture.workshopId,
                List.of(fixture.line("60"))));
        ApiException error = assertThrows(ApiException.class, () -> fixture.guard.validateDraft(
                UUID.randomUUID(), fixture.workshopId, List.of(fixture.line("60.0001"))));
        assertTrue(error.getMessage().contains("最多可报 100"));
    }

    @Test
    void continuousSupplyWithUnknownCapacityCannotReport() {
        Fixture fixture = fixture("IN_PROGRESS", "1000", "0", "DEMANDED", "PARTIAL", true, true, null);
        assertThrows(ApiException.class, () -> fixture.guard.validateDraft(UUID.randomUUID(),
                fixture.workshopId,List.of(fixture.line("1"))));
    }

    @Test
    void mismatchedMaterialCustodyRejectsOrdinaryAndRecoveryReports() {
        Fixture fixture=fixture("IN_PROGRESS","10","0","ZERO_MATERIAL",null,true,false,null,false);
        var ordinary=fixture.line("2");
        var recovery=fixture.line("2"); recovery.setFqcRecoveryAuthorizationId(UUID.randomUUID());
        for(var line:List.of(ordinary,recovery)) {
            ApiException error=assertThrows(ApiException.class,()->fixture.guard.validateDraft(
                    UUID.randomUUID(),fixture.workshopId,List.of(line)));
            assertTrue(error.getMessage().contains("原领料或直送料"));
        }
    }

    @Test
    void mismatchedMaterialCustodyStillAllowsTheOriginalReportToReverse() {
        Fixture fixture=fixture("IN_PROGRESS","10","0","ZERO_MATERIAL",null,true,false,null,false);
        var item=new ProductionDailyReportItem(); item.setId(UUID.randomUUID());
        item.setExecutionSegmentId(fixture.segmentId); item.setPlanItemId(fixture.planItemId);
        item.setGoodsId(fixture.goodsId); item.setUnitId(fixture.unitId); item.setUnitRate(BigDecimal.ONE);
        item.setQty(new BigDecimal("2"));
        assertDoesNotThrow(()->fixture.guard.reverse(List.of(item)));
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
        return fixture(status,planned,existing,materialMode,demandStatus,workshopEligible,false,null);
    }

    private static Fixture fixture(String status, String planned, String existing, String materialMode,
                                   String demandStatus, boolean workshopEligible, boolean continuous, String capacity) {
        return fixture(status,planned,existing,materialMode,demandStatus,workshopEligible,continuous,capacity,true);
    }

    private static Fixture fixture(String status, String planned, String existing, String materialMode,
                                   String demandStatus, boolean workshopEligible, boolean continuous, String capacity,
                                   boolean custodyValid) {
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
                7L, null,
                // Route flag is preserved; every started ordinary report uses net material capacity.
                continuous, true
        }));
        Query allocation = query();
        when(allocation.getResultList()).thenReturn(List.of());
        Query cumulative = query();
        when(cumulative.getSingleResult()).thenReturn(new BigDecimal(existing));
        Query internalCumulative = scalarQuery(new BigDecimal(existing));
        Query demands=query();
        when(demands.getResultList()).thenReturn(demandStatus==null ? List.of() : Collections.singletonList(
                new Object[]{UUID.randomUUID(),demandStatus,false}));
        Query capacityQuery=scalarQuery(capacity==null?null:new BigDecimal(capacity));
        Query custodyQuery=scalarQuery(custodyValid);
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql=invocation.getArgument(0);
            if(sql.contains("fn_execution_material_custody_valid"))return custodyQuery;
            if(sql.contains("fn_execution_material_output_capacity"))return capacityQuery;
            if(sql.contains("FROM production_material_demands"))return demands;
            if(sql.contains("FROM execution_segment_sales_allocations"))return allocation;
            if(sql.contains("SUM(item.qty)")
                    && sql.contains("item.execution_segment_sales_allocation_id IS NULL")) return internalCumulative;
            if(sql.contains("SUM(item.qty)"))return cumulative;
            return lock;
        });
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
                notices, allocation, internalCumulative, lock);
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
            ChainNoticeService notices,
            Query allocation,
            Query internalCumulative,
            Query lock) {
        UUID[] salesAllocation(String qty) {
            UUID allocationId = UUID.randomUUID();
            UUID orderItemId = UUID.randomUUID();
            when(allocation.getResultList()).thenReturn(Collections.singletonList(
                    new Object[]{allocationId, orderItemId, new BigDecimal(qty)}));
            return new UUID[]{allocationId, orderItemId};
        }
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
