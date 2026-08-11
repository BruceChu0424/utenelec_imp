package com.uten.imp.features.notice;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.FinanceReviewerEligibilityPort;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.rbac.UserRoleRepository;
import com.uten.imp.features.rd_task.RdTaskService;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.contains;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.ArgumentMatchers.isNull;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class ChainNoticeOutboxEventTest {

    @Test
    void finishedInboundPublishesImmutableBatchAvailabilitySnapshot() {
        UUID stockDocId = UUID.randomUUID();
        UUID orderId = UUID.randomUUID();
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        BusinessEventPublisher outbox = mock(BusinessEventPublisher.class);
        when(jdbc.queryForList(
                contains("WITH inbound_item AS"),
                eq(stockDocId),
                eq(stockDocId))).thenReturn(List.of(Map.of(
                        "order_id", orderId,
                        "order_bill_no", "SO-001",
                        "document_no", "FI-001",
                        "goods", "FG-001",
                        "batch_qty", new BigDecimal("5.0000"),
                        "produced_qty", new BigDecimal("5.0000"),
                        "order_qty", new BigDecimal("10.0000"),
                        "shipment_policy", "ALLOW_PARTIAL")));
        ChainNoticeService service = service(jdbc, outbox);

        service.notifyFinishedInbound(stockDocId);

        verify(outbox).publish(
                ChainNoticeService.EVENT_FINISHED_INBOUND,
                "STOCK_DOCUMENT",
                stockDocId,
                Map.of("allocations", List.of(Map.of(
                        "orderId", orderId.toString(),
                        "orderBillNo", "SO-001",
                        "documentNo", "FI-001",
                        "goods", "FG-001",
                        "batchQty", "5",
                        "producedQty", "5",
                        "orderQty", "10",
                        "shipmentPolicy", "ALLOW_PARTIAL"))));
    }

    @Test
    void finishedInboundSnapshotNotifiesSalesAndPlannerForThisBatch() {
        UUID stockDocId = UUID.randomUUID();
        UUID orderId = UUID.randomUUID();
        UUID ownerEmployeeId = UUID.randomUUID();
        UUID ownerUserId = UUID.randomUUID();
        UUID plannerUserId = UUID.randomUUID();
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        NoticeService notice = mock(NoticeService.class);
        UserAccountRepository users = mock(UserAccountRepository.class);
        UserRoleRepository roles = mock(UserRoleRepository.class);
        when(jdbc.queryForList(
                contains("SELECT bill_no, owner_employee_id, seller_id"),
                eq(orderId))).thenReturn(List.of(Map.of(
                        "bill_no", "SO-CURRENT",
                        "owner_employee_id", ownerEmployeeId)));
        when(users.findByEmployeeId(ownerEmployeeId))
                .thenReturn(Optional.of(activeUser(ownerUserId)));
        when(users.findById(ownerUserId))
                .thenReturn(Optional.of(activeUser(ownerUserId)));
        when(users.findById(plannerUserId))
                .thenReturn(Optional.of(activeUser(plannerUserId)));
        when(roles.findUserIdsByRoleCode("planner"))
                .thenReturn(List.of(plannerUserId));
        ChainNoticeService service = service(
                notice, users, roles, jdbc, mock(BusinessEventPublisher.class));
        Map<String, Object> payload = Map.of("allocations", List.of(Map.of(
                "orderId", orderId.toString(),
                "orderBillNo", "SO-SNAPSHOT",
                "documentNo", "FI-001",
                "goods", "FG-001",
                "batchQty", "5",
                "producedQty", "5",
                "orderQty", "10",
                "shipmentPolicy", "ALLOW_PARTIAL")));

        service.deliverOutboxEvent(
                ChainNoticeService.EVENT_FINISHED_INBOUND,
                stockDocId,
                new ObjectMapper().valueToTree(payload));

        verify(notice).publishForUser(
                eq(ownerUserId),
                eq("本批成品已入库：SO-SNAPSHOT"),
                contains("本批新增可发数量 5"),
                eq(ChainNoticeService.TYPE_WORKFLOW),
                anyString(),
                eq("/sales/orders/" + orderId),
                eq(ChainNoticeService.EVENT_FINISHED_INBOUND));
        verify(notice).publishForUser(
                eq(plannerUserId),
                eq("生产批次已入库：SO-SNAPSHOT"),
                contains("本批新增可发数量 5"),
                eq(ChainNoticeService.TYPE_WORKFLOW),
                anyString(),
                eq("/production/plans"),
                isNull());
    }

    @Test
    void warehouseHandoffsAreDurableAndDocumentScoped() {
        UUID finishedInId = UUID.randomUUID();
        UUID shipmentId = UUID.randomUUID();
        BusinessEventPublisher outbox = mock(BusinessEventPublisher.class);
        ChainNoticeService service = service(mock(JdbcTemplate.class), outbox);

        service.notifyFinishedInboundPending(finishedInId);
        service.notifyShipmentPendingPick(shipmentId);

        verify(outbox).publishOnce(
                ChainNoticeService.EVENT_FINISHED_INBOUND_PENDING,
                "STOCK_DOCUMENT",
                finishedInId,
                Map.of(),
                ChainNoticeService.EVENT_FINISHED_INBOUND_PENDING + ':'
                        + finishedInId);
        verify(outbox).publishOnce(
                ChainNoticeService.EVENT_SHIPMENT_PENDING_PICK,
                "SALES_SHIPMENT",
                shipmentId,
                Map.of(),
                ChainNoticeService.EVENT_SHIPMENT_PENDING_PICK + ':'
                        + shipmentId);
    }

    @Test
    void pendingShipmentDeliveryTargetsWarehouseWithoutClaimingAllocation() {
        UUID shipmentId = UUID.randomUUID();
        UUID warehouseUserId = UUID.randomUUID();
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        NoticeService notice = mock(NoticeService.class);
        UserAccountRepository users = mock(UserAccountRepository.class);
        when(jdbc.queryForList(
                contains("FROM sales_shipments shipment"),
                eq(shipmentId))).thenReturn(List.of(Map.of(
                        "bill_no", "SH-001",
                        "warehouse_name", "成品仓",
                        "shipment_qty", new BigDecimal("5"))));
        when(jdbc.queryForList(
                contains("WITH RECURSIVE subtree(id)"),
                eq(UUID.class),
                eq("SUB_WH"))).thenReturn(List.of(warehouseUserId));
        when(users.findById(warehouseUserId))
                .thenReturn(Optional.of(activeUser(warehouseUserId)));
        ChainNoticeService service = service(
                notice, users, jdbc, mock(BusinessEventPublisher.class));

        service.deliverOutboxEvent(
                ChainNoticeService.EVENT_SHIPMENT_PENDING_PICK,
                shipmentId,
                new ObjectMapper().createObjectNode());

        verify(notice).publishForUser(
                eq(warehouseUserId),
                eq("待拣货发货单：SH-001"),
                contains("通知不代表已占用或已出库"),
                eq(ChainNoticeService.TYPE_TASK),
                anyString(),
                eq("/sales/shipments/" + shipmentId),
                eq(ChainNoticeService.EVENT_SHIPMENT_PENDING_PICK));
    }

    @Test
    void pendingFinishedInboundDeliveryTargetsOnlyActiveWarehouseUsers() {
        UUID stockDocId = UUID.randomUUID();
        UUID warehouseUserId = UUID.randomUUID();
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        NoticeService notice = mock(NoticeService.class);
        UserAccountRepository users = mock(UserAccountRepository.class);
        when(jdbc.queryForList(
                contains("FROM stock_documents stock"),
                eq(stockDocId))).thenReturn(List.of(Map.of(
                        "bill_no", "FI-001",
                        "source_doc_no", "DR-001",
                        "warehouse_name", "成品仓")));
        when(jdbc.queryForList(
                contains("WITH RECURSIVE subtree(id)"),
                eq(UUID.class),
                eq("SUB_WH"))).thenReturn(List.of(warehouseUserId));
        when(users.findById(warehouseUserId))
                .thenReturn(Optional.of(activeUser(warehouseUserId)));
        ChainNoticeService service = service(
                notice, users, jdbc, mock(BusinessEventPublisher.class));

        service.deliverOutboxEvent(
                ChainNoticeService.EVENT_FINISHED_INBOUND_PENDING,
                stockDocId,
                new ObjectMapper().createObjectNode());

        verify(notice).publishForUser(
                eq(warehouseUserId),
                eq("待审核成品入库：FI-001"),
                contains("通知不代替库存审核"),
                eq(ChainNoticeService.TYPE_TASK),
                anyString(),
                eq("/warehouse/FINISHED_IN/" + stockDocId),
                eq(ChainNoticeService.EVENT_FINISHED_INBOUND_PENDING));
    }

    @Test
    void approvedOrderSendsPlannerToMaterialAnalysisBeforeScheduling() {
        UUID orderId = UUID.randomUUID();
        UUID plannerUserId = UUID.randomUUID();
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        NoticeService notice = mock(NoticeService.class);
        UserAccountRepository users = mock(UserAccountRepository.class);
        UserRoleRepository roles = mock(UserRoleRepository.class);
        when(jdbc.queryForList(
                contains("SELECT bill_no, owner_employee_id, seller_id"),
                eq(orderId))).thenReturn(List.of(Map.of("bill_no", "SO-001")));
        when(jdbc.queryForList(
                contains("SELECT COUNT(*) AS lines"),
                eq(orderId))).thenReturn(List.of(Map.of(
                        "lines", 2L,
                        "deliver", "2026-08-20",
                        "goods", "FG-001 / FG-002")));
        when(roles.findUserIdsByRoleCode("planner"))
                .thenReturn(List.of(plannerUserId));
        when(jdbc.queryForList(
                contains("WITH RECURSIVE subtree(id)"),
                eq(UUID.class),
                eq("SUB_PLAN"))).thenReturn(List.of());
        when(users.findById(plannerUserId))
                .thenReturn(Optional.of(activeUser(plannerUserId)));
        ChainNoticeService service = service(
                notice, users, roles, jdbc, mock(BusinessEventPublisher.class));

        service.deliverOutboxEvent(
                ChainNoticeService.EVENT_ORDER_APPROVED,
                orderId,
                new ObjectMapper().createObjectNode());

        verify(notice).publishForUser(
                eq(plannerUserId),
                eq("新订单待物料分析：SO-001"),
                contains("请先核对库存并按采购、委外、自制拆分需求"),
                eq(ChainNoticeService.TYPE_TASK),
                anyString(),
                eq("/production/material-analysis"),
                isNull());
    }

    @Test
    void deliveryDueKeepsSalesOnOrderAndRoutesPlannerToMaterialAnalysis() {
        UUID orderId = UUID.randomUUID();
        UUID ownerEmployeeId = UUID.randomUUID();
        UUID ownerUserId = UUID.randomUUID();
        UUID plannerUserId = UUID.randomUUID();
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        NoticeService notice = mock(NoticeService.class);
        UserAccountRepository users = mock(UserAccountRepository.class);
        UserRoleRepository roles = mock(UserRoleRepository.class);
        when(jdbc.queryForList(
                contains("SELECT bill_no, owner_employee_id, seller_id"),
                eq(orderId))).thenReturn(List.of(Map.of(
                        "bill_no", "SO-002",
                        "owner_employee_id", ownerEmployeeId)));
        when(users.findByEmployeeId(ownerEmployeeId))
                .thenReturn(Optional.of(activeUser(ownerUserId)));
        when(roles.findUserIdsByRoleCode("planner"))
                .thenReturn(List.of(plannerUserId));
        when(users.findById(ownerUserId))
                .thenReturn(Optional.of(activeUser(ownerUserId)));
        when(users.findById(plannerUserId))
                .thenReturn(Optional.of(activeUser(plannerUserId)));
        ChainNoticeService service = service(
                notice, users, roles, jdbc, mock(BusinessEventPublisher.class));

        service.deliverOutboxEvent(
                ChainNoticeService.EVENT_DELIVERY_DUE,
                orderId,
                new ObjectMapper().createObjectNode()
                        .put("daysLeft", 2)
                        .put("daily", false));

        verify(notice).publishForUser(
                eq(ownerUserId),
                eq("交货预警：SO-002"),
                contains("尚未结案"),
                eq(ChainNoticeService.TYPE_URGENT),
                anyString(),
                eq("/sales/orders/" + orderId),
                isNull());
        verify(notice).publishForUser(
                eq(plannerUserId),
                eq("交货预警：SO-002"),
                contains("尚未结案"),
                eq(ChainNoticeService.TYPE_URGENT),
                anyString(),
                eq("/production/material-analysis"),
                isNull());
    }

    @Test
    void materialAnalysisReadyUsesAuthoritativeMakerAndOutboxDelivery() {
        UUID analysisId = UUID.randomUUID();
        UUID makerEmployeeId = UUID.randomUUID();
        UUID makerUserId = UUID.randomUUID();
        UUID receiptId = UUID.randomUUID();
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        NoticeService notice = mock(NoticeService.class);
        UserAccountRepository users = mock(UserAccountRepository.class);
        BusinessEventPublisher outbox = mock(BusinessEventPublisher.class);
        when(jdbc.queryForList(
                contains("FROM production_material_analyses"),
                eq(analysisId))).thenReturn(List.of(Map.of(
                        "maker_id", makerEmployeeId)));
        when(users.findByEmployeeId(makerEmployeeId))
                .thenReturn(Optional.of(activeUser(makerUserId)));
        when(users.findById(makerUserId))
                .thenReturn(Optional.of(activeUser(makerUserId)));
        ChainNoticeService service = service(notice, users, jdbc, outbox);

        service.notifyMaterialAnalysisReady(
                analysisId,
                UUID.randomUUID(),
                "PURCHASE",
                receiptId,
                new BigDecimal("3.0000"),
                new BigDecimal("8.0000"));

        Map<String, String> payload = Map.of(
                "makerEmployeeId", makerEmployeeId.toString(),
                "sourceType", "PURCHASE",
                "sourceDocumentId", receiptId.toString(),
                "readyFinishDelta", "3",
                "readyFinishQty", "8");
        verify(outbox).publishOnce(
                ChainNoticeService.EVENT_MATERIAL_ANALYSIS_READY,
                "PRODUCTION_MATERIAL_ANALYSIS",
                analysisId,
                payload,
                ChainNoticeService.EVENT_MATERIAL_ANALYSIS_READY + ':'
                        + analysisId + ":PURCHASE:" + receiptId);

        service.deliverOutboxEvent(
                ChainNoticeService.EVENT_MATERIAL_ANALYSIS_READY,
                analysisId,
                new ObjectMapper().valueToTree(payload));

        verify(notice).publishForUser(
                eq(makerUserId),
                contains("剩余物料已可下达"),
                contains("采购到货后"),
                eq(ChainNoticeService.TYPE_TASK),
                anyString(),
                eq("/production/material-analysis"),
                eq(ChainNoticeService.EVENT_MATERIAL_ANALYSIS_READY));
    }

    @Test
    void terminalMaterialAnalysisDropsQueuedReadyNotice() {
        UUID analysisId = UUID.randomUUID();
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        NoticeService notice = mock(NoticeService.class);
        when(jdbc.queryForList(
                contains("status IN ('ACTIVE', 'PARTIALLY_PLANNED')"),
                eq(analysisId))).thenReturn(List.of());
        ChainNoticeService service = service(
                notice,
                mock(UserAccountRepository.class),
                jdbc,
                mock(BusinessEventPublisher.class));

        service.deliverOutboxEvent(
                ChainNoticeService.EVENT_MATERIAL_ANALYSIS_READY,
                analysisId,
                new ObjectMapper().createObjectNode()
                        .put("makerEmployeeId", UUID.randomUUID().toString())
                        .put("sourceType", "PURCHASE")
                        .put("readyFinishDelta", "3")
                        .put("readyFinishQty", "8"));

        verifyNoInteractions(notice);
    }

    @Test
    void readinessSourceLabelsNeverMisstateMakeOrManualAsPurchase() {
        assertEquals("采购到货",
                ChainNoticeService.executionReadySourceLabel("PURCHASE"));
        assertEquals("委外回厂",
                ChainNoticeService.executionReadySourceLabel("SUBCONTRACT"));
        assertEquals("自制件完工入库",
                ChainNoticeService.executionReadySourceLabel("MAKE"));
        assertEquals("人工解除暂缓",
                ChainNoticeService.executionReadySourceLabel("MANUAL_RELEASE"));
        assertEquals("物料状态变化",
                ChainNoticeService.executionReadySourceLabel("UNKNOWN"));

        assertEquals("采购到货",
                ChainNoticeService.analysisReadySourceLabel("PURCHASE"));
        assertEquals("委外回厂",
                ChainNoticeService.analysisReadySourceLabel("SUBCONTRACT"));
        assertEquals("自制件完工入库",
                ChainNoticeService.analysisReadySourceLabel("MAKE"));
        assertEquals("人工复核",
                ChainNoticeService.analysisReadySourceLabel("MANUAL"));
    }

    private static ChainNoticeService service(
            JdbcTemplate jdbc,
            BusinessEventPublisher outbox) {
        return service(
                mock(NoticeService.class),
                mock(UserAccountRepository.class),
                jdbc,
                outbox);
    }

    private static ChainNoticeService service(
            NoticeService notice,
            UserAccountRepository users,
            JdbcTemplate jdbc,
            BusinessEventPublisher outbox) {
        return service(
                notice,
                users,
                mock(UserRoleRepository.class),
                jdbc,
                outbox);
    }

    private static ChainNoticeService service(
            NoticeService notice,
            UserAccountRepository users,
            UserRoleRepository roles,
            JdbcTemplate jdbc,
            BusinessEventPublisher outbox) {
        return new ChainNoticeService(
                notice,
                users,
                roles,
                jdbc,
                outbox,
                mock(RdTaskService.class),
                mock(FinanceReviewerEligibilityPort.class));
    }

    private static UserAccount activeUser(UUID userId) {
        UserAccount user = new UserAccount();
        user.setId(userId);
        user.setStatus("active");
        user.setDeleted(false);
        return user;
    }
}
