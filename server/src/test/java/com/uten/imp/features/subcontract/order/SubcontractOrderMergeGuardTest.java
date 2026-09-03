package com.uten.imp.features.subcontract.order;

import com.uten.imp.application.port.ProductionSubcontractSupplyTransitionPort;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.integrity.LinkedDocumentIntegrityService;
import com.uten.imp.common.integrity.ProductionSupplySourceGuard;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.finance.procurement.ProcurementApprovalProjectionQuery;
import com.uten.imp.features.subcontract.order.dto.OrderItemLine;
import com.uten.imp.features.subcontract.order.dto.OrderSaveRequest;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentMatchers;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.argThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * V463 前置谱系守卫：多来源合并行包含「先做后审（V458 前置自制已完成、
 * 申请行挂 make 任务批次）」来源时，必须在**保存**就拒绝并给出可操作指引，
 * 而不是等到财务批准（createPlanOnApproval→preparedLineage）或准备启动
 * （sourceLineage）在深处 409。
 */
class SubcontractOrderMergeGuardTest {

    private record Wiring(
            SubcontractOrderService service,
            UUID itemA,
            UUID itemB,
            Query batchQuery,
            UUID goodsId) {}

    private static Wiring wire() {
        UUID itemA = UUID.randomUUID();
        UUID itemB = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        EntityManager em = mock(EntityManager.class);
        SubcontractOrderRepository orderRepo = mock(SubcontractOrderRepository.class);
        SubcontractOrderItemRepository itemRepo =
                mock(SubcontractOrderItemRepository.class);

        Query settlementQuery = mock(Query.class);
        when(em.createNativeQuery(argThat(sql ->
                sql != null && sql.contains("FROM settlement_methods method"))))
                .thenReturn(settlementQuery);
        when(settlementQuery.setParameter(anyString(), any()))
                .thenReturn(settlementQuery);
        when(settlementQuery.setMaxResults(ArgumentMatchers.anyInt()))
                .thenReturn(settlementQuery);
        when(settlementQuery.getResultList()).thenReturn(List.<Object[]>of(
                new Object[]{UUID.randomUUID(), 1, "CASH", "现金", null}));

        // V463 剩余量查询（2 列）：两来源各剩 10。
        Query remainingQuery = mock(Query.class);
        when(em.createNativeQuery(argThat(sql ->
                sql != null && sql.contains("remaining_qty")
                        && sql.contains("FROM subcontract_application_items"))))
                .thenReturn(remainingQuery);
        when(remainingQuery.setParameter(anyString(), any()))
                .thenReturn(remainingQuery);
        when(remainingQuery.getResultList()).thenReturn(List.<Object[]>of(
                new Object[]{itemA, new BigDecimal("10")},
                new Object[]{itemB, new BigDecimal("10")}));

        // 前置自制批次谱系查询：默认无批次，用例按需重挂。
        Query batchQuery = mock(Query.class);
        when(em.createNativeQuery(argThat(sql ->
                sql != null
                        && sql.contains("preplan_subcontract_make_task_batches"))))
                .thenReturn(batchQuery);
        when(batchQuery.setParameter(anyString(), any())).thenReturn(batchQuery);
        when(batchQuery.getResultList()).thenReturn(List.of());

        // 申请快照（4 列）/主档快照/详情头来源解析/sources 落库 INSERT。
        Query snapshotQuery = mock(Query.class);
        when(em.createNativeQuery(argThat(sql ->
                sql != null && sql.contains("FROM subcontract_application_items")
                        && !sql.contains("remaining_qty")
                        && !sql.contains("preplan_subcontract_make_task_batches")
                        && !sql.contains("SELECT DISTINCT sa.id"))))
                .thenReturn(snapshotQuery);
        when(snapshotQuery.setParameter(anyString(), any()))
                .thenReturn(snapshotQuery);
        when(snapshotQuery.getResultList()).thenReturn(List.<Object[]>of(
                new Object[]{itemA, goodsId, "G-OLD", "历史货品"}));
        Query masterQuery = mock(Query.class);
        when(em.createNativeQuery(argThat(sql ->
                sql != null && sql.contains("FROM goods"))))
                .thenReturn(masterQuery);
        when(masterQuery.setParameter(anyString(), any())).thenReturn(masterQuery);
        when(masterQuery.getResultList()).thenReturn(List.of());
        Query sourceQuery = mock(Query.class);
        when(em.createNativeQuery(argThat(sql ->
                sql != null && sql.contains("SELECT DISTINCT sa.id"))))
                .thenReturn(sourceQuery);
        when(sourceQuery.setParameter(anyString(), any())).thenReturn(sourceQuery);
        when(sourceQuery.getResultList()).thenReturn(List.of());
        Query sourceInsert = mock(Query.class);
        when(em.createNativeQuery(argThat(sql ->
                sql != null
                        && sql.contains("INSERT INTO subcontract_order_item_sources"))))
                .thenReturn(sourceInsert);
        when(sourceInsert.setParameter(anyString(), any()))
                .thenReturn(sourceInsert);
        when(sourceInsert.executeUpdate()).thenReturn(1);

        SecurityContextCurrentUser currentUser =
                mock(SecurityContextCurrentUser.class);
        when(currentUser.requireEmployeeId()).thenReturn(UUID.randomUUID());
        when(currentUser.requireId()).thenReturn(UUID.randomUUID());
        com.uten.imp.features.subcontract.SubcontractDocumentAccessPolicy accessPolicy =
                mock(com.uten.imp.features.subcontract.SubcontractDocumentAccessPolicy.class);
        when(accessPolicy.hasAuthority("subcontract_order:decompose")).thenReturn(true);

        SubcontractOrderService service = new SubcontractOrderService(
                orderRepo,
                itemRepo,
                mock(SubcontractOrderCostItemRepository.class),
                mock(LinkedDocumentIntegrityService.class),
                mock(TxSessionVars.class),
                em,
                currentUser,
                mock(EmployeeNameResolver.class),
                mock(DocNumberService.class),
                mock(ProductionSubcontractSupplyTransitionPort.class),
                mock(ProductionSupplySourceGuard.class),
                mock(ProcurementApprovalProjectionQuery.class),
                mock(com.uten.imp.application.port.ProcurementArrivalControlPort.class),
                accessPolicy,
                mock(com.uten.imp.features.subcontract.plan.SubcontractMaterialPlanService.class),
                mock(com.uten.imp.application.port.MasterReferenceValidationPort.class));
        return new Wiring(service, itemA, itemB, batchQuery, goodsId);
    }

    private static OrderSaveRequest mergedRequest(Wiring wiring) {
        OrderItemLine line = new OrderItemLine();
        line.setLineNo(1);
        line.setGoodsId(wiring.goodsId());
        line.setUnitId(UUID.randomUUID());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal("20"));
        line.setPrice(BigDecimal.ONE);
        line.setAmountOriginal(new BigDecimal("20"));
        line.setAmountLocal(new BigDecimal("20"));
        line.setSupplierId(UUID.randomUUID());
        line.setSettlementMethodId(UUID.randomUUID());
        line.setCurrencyId(UUID.randomUUID());
        line.setExchangeRate(BigDecimal.ONE);
        line.setTaxRate(BigDecimal.ZERO);
        line.setApplicationItemId(wiring.itemA());
        line.setApplicationItemIds(List.of(wiring.itemA(), wiring.itemB()));
        OrderSaveRequest req = new OrderSaveRequest();
        req.setBillDate(LocalDate.of(2026, 9, 3));
        req.setSupplierId(line.getSupplierId());
        req.setSettlementMethodId(line.getSettlementMethodId());
        req.setCurrencyId(line.getCurrencyId());
        req.setExchangeRate(line.getExchangeRate());
        req.setTaxRate(line.getTaxRate());
        req.setItems(List.of(line));
        return req;
    }

    @Test
    void mergeIncludingMakeTaskSourceIsRejectedAtSaveWithActionableMessage() {
        Wiring wiring = wire();
        when(wiring.batchQuery().getResultList()).thenReturn(List.<Object[]>of(
                new Object[]{wiring.itemA(), "SUB-APP-777"}));
        var error = assertThrows(ApiException.class,
                () -> wiring.service().create(mergedRequest(wiring)));
        assertTrue(error.getMessage().contains("前置自制"),
                "拒绝原因指向前置自制谱系：" + error.getMessage());
        assertTrue(error.getMessage().contains("分开生成订货单"),
                "给出可操作指引：" + error.getMessage());
    }

    @Test
    void mergeWithoutMakeTaskLineagePasses() {
        Wiring wiring = wire();
        assertDoesNotThrow(() -> wiring.service().create(mergedRequest(wiring)));
    }
}
