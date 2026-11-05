package com.uten.imp.features.finance.procurement;

import com.uten.imp.application.port.ProductionSubcontractSupplyTransitionPort;
import com.uten.imp.application.port.ProductionSupplyTransitionPort;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.integrity.LinkedDocumentIntegrityService;
import com.uten.imp.common.integrity.ProductionSupplySourceGuard;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.FinanceApproval;
import com.uten.imp.features.purchase.common.PurchaseLineUnitPolicy;
import com.uten.imp.features.purchase.order.PurchaseOrder;
import com.uten.imp.features.purchase.order.PurchaseOrderItem;
import com.uten.imp.features.purchase.order.PurchaseOrderItemRepository;
import com.uten.imp.features.purchase.order.PurchaseOrderRepository;
import com.uten.imp.features.purchase.order.PurchaseOrderService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import com.uten.imp.support.ImportedDocumentFixture;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.argThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ProcurementRejectedOrderEditTest {

    @Test
    void rejectedProductionLinkedPurchaseOrderCanBeEditedAndResubmitted() throws Exception {
        UUID orderId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        UUID unitId = UUID.randomUUID();
        PurchaseOrder order = new PurchaseOrder();
        order.setId(orderId);
        order.setBillNo("PO-REJECTED");
        order.setBillDate(LocalDate.of(2026, 8, 2));
        order.setStatus((short) 0);

        PurchaseOrderRepository orderRepo = mock(PurchaseOrderRepository.class);
        PurchaseOrderItemRepository itemRepo = mock(PurchaseOrderItemRepository.class);
        EntityManager em = mock(EntityManager.class);
        UUID requestItemId = UUID.randomUUID();
        PurchaseOrderItem existing = new PurchaseOrderItem();
        existing.setId(UUID.randomUUID());
        existing.setOrderId(orderId);
        existing.setLineNo(1);
        existing.setGoodsId(goodsId);
        existing.setUnitId(unitId);
        existing.setUnitRate(BigDecimal.ONE);
        existing.setQty(BigDecimal.TEN);
        existing.setPrice(new BigDecimal("2"));
        existing.setAmountOriginal(new BigDecimal("20"));
        existing.setRequestItemId(requestItemId);
        existing.setGoodsCodeSnapshot("G-OLD");
        existing.setGoodsNameSnapshot("历史货品");
        existing.setGoodsSnapshotSource("REQUEST_ITEM_AT_SAVE");
        when(itemRepo.findByOrderIdOrderByLineNoAsc(orderId)).thenReturn(List.of(existing));
        when(em.find(PurchaseOrderItem.class, existing.getId())).thenReturn(existing);
        Query lockedQuantity = lockedQuantity(em, "purchase_order_items", orderId,
                existing.getId(), goodsId, unitId, requestItemId, null);
        Query deleteReplaced = mock(Query.class);
        when(em.createNativeQuery("DELETE FROM purchase_order_items WHERE order_id=:parent AND id NOT IN(:kept)"))
                .thenReturn(deleteReplaced);
        when(deleteReplaced.setParameter(anyString(), any())).thenReturn(deleteReplaced);
        stubPurchaseSnapshots(em, requestItemId, goodsId);
        ProductionSupplySourceGuard sourceGuard = mock(ProductionSupplySourceGuard.class);
        PurchaseLineUnitPolicy unitPolicy = mock(PurchaseLineUnitPolicy.class);
        ProcurementApprovalProjectionQuery projection =
                mock(ProcurementApprovalProjectionQuery.class);
        when(em.find(PurchaseOrder.class, orderId, LockModeType.PESSIMISTIC_WRITE))
                .thenReturn(order);
        when(sourceGuard.isPurchaseOrderLinked(orderId)).thenReturn(true);
        // 结账方式随请求携带（2026-09 起 @NotNull 改 service 运行时校验）→
        // applyHeader 走 UUID resolver 查 settlement_methods，按同款范式 stub 一行有效映射。
        UUID settlementMethodId = UUID.randomUUID();
        Query settlementQuery = mock(Query.class);
        when(em.createNativeQuery(argThat(sql ->
                sql != null && sql.contains("FROM settlement_methods method"))))
                .thenReturn(settlementQuery);
        when(settlementQuery.setParameter(anyString(), any())).thenReturn(settlementQuery);
        when(settlementQuery.setMaxResults(org.mockito.ArgumentMatchers.anyInt()))
                .thenReturn(settlementQuery);
        when(settlementQuery.getResultList()).thenReturn(List.<Object[]>of(
                new Object[]{settlementMethodId, 1, "CASH", "现金", null}));
        when(unitPolicy.normalizeAndValidate(
                goodsId, unitId, BigDecimal.ONE, 1))
                .thenReturn(new PurchaseLineUnitPolicy.ResolvedUnit(
                        unitId, BigDecimal.ONE));
        when(projection.latestForOrder("PURCHASE", orderId, (short) 0))
                .thenReturn(rejectedApproval());

        PurchaseOrderService service = new PurchaseOrderService(
                orderRepo,
                itemRepo,
                mock(LinkedDocumentIntegrityService.class),
                mock(ProductionSupplyTransitionPort.class),
                mock(TxSessionVars.class),
                mock(SecurityContextCurrentUser.class),
                mock(EmployeeNameResolver.class),
                em,
                mock(DocNumberService.class),
                sourceGuard,
                unitPolicy,
                projection,
                mock(com.uten.imp.features.finance.procurement.ProcurementApprovalReconfirmationService.class),
                // 2026-09-05 cancel() 撤回财务弹卡用；本测试不触达，传 mock 即可。
                mock(com.uten.imp.features.notice.ChainNoticeService.class),
                mock(com.uten.imp.application.port.ProcurementArrivalControlPort.class),
                mock(com.uten.imp.features.purchase.PurchaseDocumentAccessPolicy.class),
                mock(com.uten.imp.application.port.MasterReferenceValidationPort.class),
                        org.mockito.Mockito.mock(com.uten.imp.application.port.ProcurementReviewCancellationPort.class),
                        org.mockito.Mockito.mock(com.uten.imp.application.port.ProcurementOrderSourceRevisionPort.class),
                        org.mockito.Mockito.mock(com.uten.imp.common.concurrency.ProcurementMutationLocks.class, org.mockito.Mockito.RETURNS_DEEP_STUBS),
                        org.mockito.Mockito.mock(com.uten.imp.features.purchase.common.ProcurementMasterDefaultsSyncService.class),
                org.mockito.Mockito.mock(com.uten.imp.features.purchase.common.ProcurementReferencePricePolicyService.class));

        var origins = ImportedDocumentFixture.forService(service);
        origins.document("purchase_orders", order);
        origins.document("purchase_order_items", existing);
        com.uten.imp.features.purchase.order.dto.OrderSaveRequest request =
                new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();
        request.setBillDate(LocalDate.of(2026, 8, 3));
        // 编辑单据必须携带结账方式（2026-09 起 @NotNull 改为 service 运行时校验）。
        request.setSettlementMethodId(settlementMethodId);
        request.setItems(List.of(purchaseLine(goodsId, unitId, requestItemId)));

        var detail = service.update(orderId, request);

        assertTrue(detail.isProductionLinked());
        assertTrue(detail.isCanEdit());
        assertTrue(detail.isCanDelete());
        assertNull(detail.getRestrictionReason());
        assertEquals("REJECTED", detail.getFinanceApproval().status());
        assertEquals(
                List.of("SUBMIT_FINANCE"),
                detail.getFinanceApproval().allowedActions());
        ArgumentCaptor<com.uten.imp.features.purchase.order.PurchaseOrderItem> savedItem =
                ArgumentCaptor.forClass(
                        com.uten.imp.features.purchase.order.PurchaseOrderItem.class);
        verify(itemRepo).save(savedItem.capture());
        assertEquals("G-OLD", savedItem.getValue().getGoodsCodeSnapshot());
        assertEquals("REQUEST_ITEM_AT_SAVE", savedItem.getValue().getGoodsSnapshotSource());
        assertSame(existing, savedItem.getValue());
        assertEquals(BigDecimal.ONE, savedItem.getValue().getPrice());
        assertEquals(0, BigDecimal.TEN.compareTo(savedItem.getValue().getAmountOriginal()));
        verify(lockedQuantity).setParameter("parent", orderId);
        verify(lockedQuantity).getResultList();
        verify(deleteReplaced).setParameter("parent", orderId);
        verify(deleteReplaced).setParameter("kept", List.of(existing.getId()));
        verify(deleteReplaced).executeUpdate();
        verify(projection).requireMutable("PURCHASE", orderId);
        verify(sourceGuard, never()).requirePurchaseOrderMutable(orderId);
    }

    @Test
    void rejectedProductionLinkedSubcontractOrderCanBeEditedAndResubmitted() throws Exception {
        UUID orderId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        UUID unitId = UUID.randomUUID();
        com.uten.imp.features.subcontract.order.SubcontractOrder order =
                new com.uten.imp.features.subcontract.order.SubcontractOrder();
        order.setId(orderId);
        order.setBillNo("SO-REJECTED");
        order.setBillDate(LocalDate.of(2026, 8, 2));
        order.setStatus((short) 0);

        var orderRepo = mock(
                com.uten.imp.features.subcontract.order.SubcontractOrderRepository.class);
        var itemRepo = mock(
                com.uten.imp.features.subcontract.order.SubcontractOrderItemRepository.class);
        EntityManager em = mock(EntityManager.class);
        UUID applicationItemId = UUID.randomUUID();
        var existing = new com.uten.imp.features.subcontract.order.SubcontractOrderItem();
        existing.setId(UUID.randomUUID());
        existing.setOrderId(orderId);
        existing.setLineNo(1);
        existing.setGoodsId(goodsId);
        existing.setUnitId(unitId);
        existing.setUnitRate(BigDecimal.ONE);
        existing.setQty(BigDecimal.TEN);
        existing.setPrice(new BigDecimal("2"));
        existing.setAmountOriginal(new BigDecimal("20"));
        existing.setApplicationItemId(applicationItemId);
        existing.setGoodsCodeSnapshot("G-OLD");
        existing.setGoodsNameSnapshot("历史货品");
        existing.setGoodsSnapshotSource("APPLICATION_ITEM_AT_SAVE");
        when(itemRepo.findByOrderIdOrderByLineNoAsc(orderId)).thenReturn(List.of(existing));
        when(em.find(com.uten.imp.features.subcontract.order.SubcontractOrderItem.class,
                existing.getId())).thenReturn(existing);
        var referenceHeader = new LinkedHashMap<String, Object>();
        referenceHeader.put("supplier_id", order.getSupplierId());
        referenceHeader.put("currency_id", order.getCurrencyId());
        referenceHeader.put("exchange_rate", order.getExchangeRate());
        referenceHeader.put("tax_rate", order.getTaxRate());
        referenceHeader.put("settlement_method_id", order.getSettlementMethodId());
        Query lockedQuantity = lockedQuantity(em, "subcontract_order_items", orderId,
                existing.getId(), goodsId, unitId, applicationItemId, referenceHeader);
        stubSubcontractSnapshots(em, applicationItemId, goodsId);
        Query existingSourcesQuery = mock(Query.class);
        when(em.createNativeQuery(argThat(sql ->
                sql != null && sql.contains("SELECT item.application_item_id")
                        && sql.contains("FROM subcontract_order_items item")
                        && sql.contains("FROM subcontract_order_item_sources source"))))
                .thenReturn(existingSourcesQuery);
        when(existingSourcesQuery.setParameter("order", orderId))
                .thenReturn(existingSourcesQuery);
        when(existingSourcesQuery.getResultList()).thenReturn(List.of(applicationItemId));
        UUID settlementMethodId = UUID.randomUUID();
        Query settlementQuery = mock(Query.class);
        when(em.createNativeQuery(argThat(sql ->
                sql != null && sql.contains("FROM settlement_methods method"))))
                .thenReturn(settlementQuery);
        when(settlementQuery.setParameter(anyString(), any())).thenReturn(settlementQuery);
        when(settlementQuery.setMaxResults(org.mockito.ArgumentMatchers.anyInt()))
                .thenReturn(settlementQuery);
        when(settlementQuery.getResultList()).thenReturn(List.<Object[]>of(
                new Object[]{settlementMethodId, 1, "CASH", "现金", null}));
        ProductionSupplySourceGuard sourceGuard = mock(ProductionSupplySourceGuard.class);
        ProcurementApprovalProjectionQuery projection =
                mock(ProcurementApprovalProjectionQuery.class);
        when(em.find(
                com.uten.imp.features.subcontract.order.SubcontractOrder.class,
                orderId,
                LockModeType.PESSIMISTIC_WRITE))
                .thenReturn(order);
        when(sourceGuard.isSubcontractOrderLinked(orderId)).thenReturn(true);
        when(projection.latestForOrder("SUBCONTRACT", orderId, (short) 0))
                .thenReturn(rejectedApproval());

        var service = new com.uten.imp.features.subcontract.order.SubcontractOrderService(
                orderRepo,
                itemRepo,
                mock(com.uten.imp.features.subcontract.order.SubcontractOrderCostItemRepository.class),
                mock(LinkedDocumentIntegrityService.class),
                mock(TxSessionVars.class),
                em,
                mock(SecurityContextCurrentUser.class),
                mock(EmployeeNameResolver.class),
                mock(DocNumberService.class),
                mock(ProductionSubcontractSupplyTransitionPort.class),
                sourceGuard,
                projection,
                mock(com.uten.imp.application.port.ProcurementArrivalControlPort.class),
                mock(com.uten.imp.features.subcontract.SubcontractDocumentAccessPolicy.class),
                mock(com.uten.imp.features.subcontract.plan.SubcontractMaterialPlanService.class),
                mock(com.uten.imp.features.finance.procurement.ProcurementApprovalReconfirmationService.class),
                mock(com.uten.imp.application.port.MasterReferenceValidationPort.class),
                mock(com.uten.imp.application.port.ProcurementReviewCancellationPort.class),
                        org.mockito.Mockito.mock(com.uten.imp.application.port.ProcurementOrderSourceRevisionPort.class),
                        org.mockito.Mockito.mock(com.uten.imp.common.concurrency.ProcurementMutationLocks.class, org.mockito.Mockito.RETURNS_DEEP_STUBS),
                        org.mockito.Mockito.mock(com.uten.imp.features.purchase.common.ProcurementMasterDefaultsSyncService.class),
                org.mockito.Mockito.mock(com.uten.imp.features.purchase.common.ProcurementReferencePricePolicyService.class));

        var origins = ImportedDocumentFixture.forService(service);
        origins.document("subcontract_orders", order);
        origins.document("subcontract_order_items", existing);
        var request =
                new com.uten.imp.features.subcontract.order.dto.OrderSaveRequest();
        request.setBillDate(LocalDate.of(2026, 8, 3));
        request.setSettlementMethodId(settlementMethodId);
        request.setItems(List.of(subcontractLine(goodsId, unitId, applicationItemId)));

        var detail = service.update(orderId, request);

        assertTrue(detail.isProductionLinked());
        assertTrue(detail.isCanEdit());
        assertTrue(detail.isCanDelete());
        assertNull(detail.getRestrictionReason());
        assertEquals("REJECTED", detail.getFinanceApproval().status());
        assertEquals(
                List.of("SUBMIT_FINANCE"),
                detail.getFinanceApproval().allowedActions());
        ArgumentCaptor<com.uten.imp.features.subcontract.order.SubcontractOrderItem>
                savedItem = ArgumentCaptor.forClass(
                        com.uten.imp.features.subcontract.order.SubcontractOrderItem.class);
        verify(itemRepo).save(savedItem.capture());
        assertEquals("G-OLD", savedItem.getValue().getGoodsCodeSnapshot());
        assertEquals("APPLICATION_ITEM_AT_SAVE",
                savedItem.getValue().getGoodsSnapshotSource());
        assertSame(existing, savedItem.getValue());
        assertFalse(existing.isDeleted());
        assertEquals(BigDecimal.ONE, savedItem.getValue().getPrice());
        assertEquals(0, BigDecimal.TEN.compareTo(savedItem.getValue().getAmountOriginal()));
        verify(lockedQuantity).setParameter("parent", orderId);
        verify(lockedQuantity).getResultList();
        verify(projection).requireMutable("SUBCONTRACT", orderId);
        verify(existingSourcesQuery).setParameter("order", orderId);
        verify(existingSourcesQuery).getResultList();
        verify(sourceGuard, never()).requireSubcontractOrderMutable(orderId);
    }

    /** Real locked-row JSON shape for the shared plan. The rejected price is
     * corrected from2 to1; quantity10 and its exact original source split stay.
     * No total-input authority was present, so no reference-division proof is invented. */
    private static Query lockedQuantity(EntityManager em, String table, UUID parent,
            UUID item, UUID goods, UUID unit, UUID source, Map<String, Object> header)
            throws Exception {
        boolean purchase = table.equals("purchase_order_items");
        var row = new LinkedHashMap<String, Object>();
        row.put("id", item); row.put("order_id", parent); row.put("line_no", 1);
        row.put("goods_id", goods); row.put("color_id", null); row.put("unit_id", unit);
        row.put("unit_rate", BigDecimal.ONE); row.put("qty", BigDecimal.TEN);
        row.put("price", new BigDecimal("2")); row.put("total_amount_input", null);
        row.put("amount_original", new BigDecimal("20")); row.put("amount_local", null);
        row.put("reference_price_precision_policy", null); row.put("extra_columns", List.of());
        row.put("is_deleted", false);
        row.put("quantity_adoption_version", 2);
        row.put("quantity_precision_policy", Map.of("version", 1, "choices", Map.of()));
        row.put("quantity_semantics", "LEGACY_RECORDED");
        row.put("gift_qty", BigDecimal.ZERO); row.put("charged_base_qty", BigDecimal.TEN);
        row.put("gift_base_qty", BigDecimal.ZERO);
        row.put(purchase ? "request_item_id" : "application_item_id", source);
        row.put(purchase ? "request_item_ids" : "application_item_ids", List.of(source));
        row.put("saved_source_splits", List.of(Map.of("source", source,
                "qty", BigDecimal.TEN, "gift", BigDecimal.ZERO)));
        if (header != null) row.put("reference_header", header);
        Query query = mock(Query.class);
        when(em.createNativeQuery(argThat(sql -> sql != null
                && sql.startsWith("SELECT (to_jsonb(line)")
                && sql.contains("FROM " + table + " line")
                && sql.contains("WHERE line.order_id=:parent AND NOT line.is_deleted")
                && sql.endsWith("FOR UPDATE OF line"))))
                .thenReturn(query);
        when(query.setParameter("parent", parent)).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of(
                new com.fasterxml.jackson.databind.ObjectMapper().writeValueAsString(row)));
        return query;
    }

    private static FinanceApproval rejectedApproval() {
        return new FinanceApproval(
                UUID.randomUUID(),
                "REJECTED",
                1,
                2,
                UUID.randomUUID(),
                UUID.randomUUID(),
                "财务负责人",
                "价格需修正",
                OffsetDateTime.now(),
                List.of("SUBMIT_FINANCE"));
    }

    private static com.uten.imp.features.purchase.order.dto.OrderItemLine purchaseLine(
            UUID goodsId, UUID unitId, UUID requestItemId) {
        var line = new com.uten.imp.features.purchase.order.dto.OrderItemLine();
        line.setLineNo(1);
        line.setGoodsId(goodsId);
        line.setUnitId(unitId);
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(BigDecimal.TEN);
        line.setPrice(BigDecimal.ONE);
        line.setRequestItemId(requestItemId);
        return line;
    }

    private static void stubPurchaseSnapshots(
            EntityManager em, UUID requestItemId, UUID goodsId) {
        Query requestQuery = mock(Query.class);
        when(em.createNativeQuery(argThat(sql ->
                sql != null && sql.contains("FROM purchase_request_items")
                        // 排除订货行谱系继承查询（SELECT id, source_doc_no, ...）
                        // 与详情头来源申请解析（SELECT DISTINCT pr.id, pr.bill_no）。
                        && !sql.contains("source_doc_no")
                        && !sql.contains("SELECT DISTINCT pr.id"))))
                .thenReturn(requestQuery);
        when(requestQuery.setParameter(anyString(), any())).thenReturn(requestQuery);
        when(requestQuery.getResultList()).thenReturn(List.<Object[]>of(
                new Object[]{requestItemId, goodsId, "G-OLD", "历史货品"}));
        Query requestLineage = mock(Query.class);
        when(em.createNativeQuery(argThat(sql ->
                sql != null && sql.contains("FROM purchase_request_items")
                        && sql.contains("source_doc_no"))))
                .thenReturn(requestLineage);
        when(requestLineage.setParameter(anyString(), any())).thenReturn(requestLineage);
        when(requestLineage.getResultList()).thenReturn(List.of());
        Query requestSource = mock(Query.class);
        when(em.createNativeQuery(argThat(sql ->
                sql != null && sql.contains("SELECT DISTINCT pr.id"))))
                .thenReturn(requestSource);
        when(requestSource.setParameter(anyString(), any())).thenReturn(requestSource);
        when(requestSource.getResultList()).thenReturn(List.of());

        Query masterQuery = mock(Query.class);
        when(em.createNativeQuery(argThat(sql ->
                sql != null && sql.contains("FROM goods"))))
                .thenReturn(masterQuery);
        when(masterQuery.setParameter(anyString(), any())).thenReturn(masterQuery);
        when(masterQuery.getResultList()).thenReturn(List.<Object[]>of(
                new Object[]{goodsId, goodsId, "G-NEW", "当前货品"}));

        // V463：同货品合并行来源拆分（剩余量查询 3 列）与 sources 落库 INSERT。
        // Mockito 后配的匹配桩优先于上面宽泛的 requestQuery 桩。
        Query remainingQuery = mock(Query.class);
        when(em.createNativeQuery(argThat(sql ->
                sql != null && sql.contains("remaining_qty")
                        && sql.contains("FROM purchase_request_items"))))
                .thenReturn(remainingQuery);
        when(remainingQuery.setParameter(anyString(), any()))
                .thenReturn(remainingQuery);
        when(remainingQuery.getResultList()).thenReturn(List.<Object[]>of(
                new Object[]{requestItemId, BigDecimal.TEN,
                        LocalDate.of(2026, 9, 1)}));
        Query sourceInsert = mock(Query.class);
        when(em.createNativeQuery(argThat(sql ->
                sql != null
                        && sql.contains("INSERT INTO purchase_order_item_sources"))))
                .thenReturn(sourceInsert);
        when(sourceInsert.setParameter(anyString(), any()))
                .thenReturn(sourceInsert);
        when(sourceInsert.executeUpdate()).thenReturn(1);
    }

    private static com.uten.imp.features.subcontract.order.dto.OrderItemLine subcontractLine(
            UUID goodsId, UUID unitId, UUID applicationItemId) {
        var line = new com.uten.imp.features.subcontract.order.dto.OrderItemLine();
        line.setLineNo(1);
        line.setGoodsId(goodsId);
        line.setUnitId(unitId);
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(BigDecimal.TEN);
        line.setPrice(BigDecimal.ONE);
        line.setApplicationItemId(applicationItemId);
        return line;
    }

    private static void stubSubcontractSnapshots(
            EntityManager em, UUID applicationItemId, UUID goodsId) {
        Query applicationQuery = mock(Query.class);
        when(em.createNativeQuery(argThat(sql ->
                sql != null && sql.contains("FROM subcontract_application_items")
                        // 排除详情头来源申请解析查询（SELECT DISTINCT sa.id, sa.bill_no）。
                        && !sql.contains("SELECT DISTINCT sa.id"))))
                .thenReturn(applicationQuery);
        when(applicationQuery.setParameter(anyString(), any())).thenReturn(applicationQuery);
        when(applicationQuery.getResultList()).thenReturn(List.<Object[]>of(
                new Object[]{applicationItemId, goodsId, "G-OLD", "历史货品"}));
        Query applicationSource = mock(Query.class);
        when(em.createNativeQuery(argThat(sql ->
                sql != null && sql.contains("SELECT DISTINCT sa.id"))))
                .thenReturn(applicationSource);
        when(applicationSource.setParameter(anyString(), any())).thenReturn(applicationSource);
        when(applicationSource.getResultList()).thenReturn(List.of());

        Query masterQuery = mock(Query.class);
        when(em.createNativeQuery(argThat(sql ->
                sql != null && sql.contains("FROM goods"))))
                .thenReturn(masterQuery);
        when(masterQuery.setParameter(anyString(), any())).thenReturn(masterQuery);
        when(masterQuery.getResultList()).thenReturn(List.<Object[]>of(
                new Object[]{goodsId, goodsId, "G-NEW", "当前货品"}));

        // V463：同货品合并行来源拆分（剩余量查询 2 列）与 sources 落库 INSERT。
        Query remainingQuery = mock(Query.class);
        when(em.createNativeQuery(argThat(sql ->
                sql != null && sql.contains("remaining_qty")
                        && sql.contains("FROM subcontract_application_items"))))
                .thenReturn(remainingQuery);
        when(remainingQuery.setParameter(anyString(), any()))
                .thenReturn(remainingQuery);
        when(remainingQuery.getResultList()).thenReturn(List.<Object[]>of(
                new Object[]{applicationItemId, BigDecimal.TEN}));
        Query sourceInsert = mock(Query.class);
        when(em.createNativeQuery(argThat(sql ->
                sql != null
                        && sql.contains("INSERT INTO subcontract_order_item_sources"))))
                .thenReturn(sourceInsert);
        when(sourceInsert.setParameter(anyString(), any()))
                .thenReturn(sourceInsert);
        when(sourceInsert.executeUpdate()).thenReturn(1);
    }
}
