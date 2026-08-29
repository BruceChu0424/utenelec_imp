package com.uten.imp.features.sales.order;

import com.uten.imp.features.sales.order.dto.OrderItemLine;
import jakarta.persistence.LockModeType;
import org.junit.jupiter.api.Test;
import org.springframework.data.jpa.repository.Lock;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

class SalesOrderRejectedRevisionContractTest {

    private static final Path SALES =
            Path.of("src/main/java/com/uten/imp/features/sales");

    @Test
    void financeDecisionRepositoryUsesPessimisticWriteLock() throws Exception {
        Lock lock = SalesOrderRepository.class
                .getMethod("findActiveByIdForUpdate", UUID.class)
                .getAnnotation(Lock.class);
        assertNotNull(lock);
        assertEquals(LockModeType.PESSIMISTIC_WRITE, lock.value());
    }

    @Test
    void revisionRejectsEveryDownstreamQuantityFact() {
        SalesOrderItem clean = cleanItem();
        assertFalse(SalesOrderService.hasRejectedRevisionBlockingLineFacts(clean));

        clean.setShippedQty(BigDecimal.ONE);
        assertTrue(SalesOrderService.hasRejectedRevisionBlockingLineFacts(clean));
        clean = cleanItem();
        clean.setReturnedQty(BigDecimal.ONE);
        assertTrue(SalesOrderService.hasRejectedRevisionBlockingLineFacts(clean));
        clean = cleanItem();
        clean.setFlagQty(BigDecimal.ONE);
        assertTrue(SalesOrderService.hasRejectedRevisionBlockingLineFacts(clean));
        clean = cleanItem();
        clean.setPlannedQty(BigDecimal.ONE);
        assertTrue(SalesOrderService.hasRejectedRevisionBlockingLineFacts(clean));
        clean = cleanItem();
        clean.setProducedQty(BigDecimal.ONE);
        assertTrue(SalesOrderService.hasRejectedRevisionBlockingLineFacts(clean));
        clean = cleanItem();
        clean.setInboundQty(BigDecimal.ONE);
        assertTrue(SalesOrderService.hasRejectedRevisionBlockingLineFacts(clean));
    }

    @Test
    void identityChangeRequiresANewLineButScaleOnlyChangeDoesNot() {
        UUID goods = UUID.randomUUID();
        UUID color = UUID.randomUUID();
        UUID unit = UUID.randomUUID();
        SalesOrderItem stored = cleanItem();
        stored.setGoodsId(goods);
        stored.setColorId(color);
        stored.setUnitId(unit);
        stored.setUnitRate(new BigDecimal("1.000000"));
        OrderItemLine requested = new OrderItemLine();
        requested.setId(stored.getId());
        requested.setGoodsId(goods);
        requested.setColorId(color);
        requested.setUnitId(unit);
        requested.setUnitRate(BigDecimal.ONE);

        assertTrue(SalesOrderService.sameRejectedRevisionIdentity(
                stored, requested));
        requested.setGoodsId(UUID.randomUUID());
        assertFalse(SalesOrderService.sameRejectedRevisionIdentity(
                stored, requested));
    }

    @Test
    void rejectedRevisionWiringPreservesLineageAndChecksAllDownstreamDomains()
            throws Exception {
        String orderService = read("order/SalesOrderService.java");
        String itemRepository = read("order/SalesOrderItemRepository.java");
        String shipmentService = read("shipment/SalesShipmentService.java");

        assertTrue(orderService.contains("reviseFinanceRejectedOrder(o, req)"));
        assertTrue(orderService.contains("reservationService.releaseByOrderItems"));
        assertTrue(orderService.contains("stored.setDeleted(true)"));
        assertTrue(orderService.contains("order.setStatus(STATUS_DRAFT)"));
        assertTrue(orderService.contains("FROM ar_ap_source_refs"));
        assertTrue(orderService.contains("FROM production_material_analysis_items"));
        assertTrue(orderService.contains("FROM sales_shipment_items"));
        assertTrue(orderService.contains(
                "订单已被财务驳回，请使用“修改订单”完成受控修订并重新审核"));
        assertTrue(orderService.contains(
                "订单已被财务驳回，请先使用“修改订单”完成受控修订"));
        assertTrue(orderService.contains("o.setFinanceRejected(false)"));
        assertTrue(itemRepository.contains(
                "findByOrderIdAndDeletedFalseOrderByLineNoAsc"));
        assertTrue(shipmentService.contains("o.finance_rejected"));
        assertTrue(shipmentService.contains("FOR UPDATE OF sales_order, item"));
    }

    private static SalesOrderItem cleanItem() {
        SalesOrderItem item = new SalesOrderItem();
        item.setShippedQty(BigDecimal.ZERO);
        item.setReturnedQty(BigDecimal.ZERO);
        item.setFlagQty(BigDecimal.ZERO);
        item.setPlannedQty(BigDecimal.ZERO);
        item.setProducedQty(BigDecimal.ZERO);
        item.setInboundQty(BigDecimal.ZERO);
        return item;
    }

    private static String read(String relative) throws Exception {
        return Files.readString(SALES.resolve(relative), StandardCharsets.UTF_8);
    }
}
