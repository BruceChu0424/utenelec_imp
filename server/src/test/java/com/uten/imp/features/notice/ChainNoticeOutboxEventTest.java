package com.uten.imp.features.notice;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.FinanceReviewerEligibilityPort;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.rbac.UserRoleRepository;
import com.uten.imp.features.rd_task.RdTaskService;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;

import java.math.BigDecimal;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.isNull;
import static org.mockito.ArgumentMatchers.contains;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoMoreInteractions;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class ChainNoticeOutboxEventTest {

    @Test
    void customerShipmentRejectDeliveryCannotReuseAnOlderRevisionReason() {
        UUID shipment=UUID.randomUUID();JdbcTemplate jdbc=mock(JdbcTemplate.class);
        NoticeService notice=mock(NoticeService.class);UserAccountRepository users=mock(UserAccountRepository.class);
        BusinessEventPublisher outbox=mock(BusinessEventPublisher.class);
        when(jdbc.queryForList(contains("SELECT bill_no,shipment_kind,owner_employee_id,review_revision"),eq(shipment)))
                .thenReturn(List.of(Map.of("bill_no","XC-REV2","shipment_kind","DIRECT_CUSTOMER","owner_employee_id",UUID.randomUUID(),"review_revision",2L)));
        ChainNoticeService service=service(notice,users,mock(PermissionResolver.class),mock(UserRoleRepository.class),jdbc,outbox);
        service.notifyShipmentFinanceRejected(shipment,"当前退回原因");
        verify(outbox).publishOnce(ChainNoticeService.EVENT_DIRECT_SHIPMENT_FINANCE_REJECTED,"SALES_SHIPMENT",shipment,
                Map.of("reason","当前退回原因","reviewRevision",2L),ChainNoticeService.EVENT_DIRECT_SHIPMENT_FINANCE_REJECTED+":"+shipment+":2");
        service.deliverOutboxEvent(ChainNoticeService.EVENT_DIRECT_SHIPMENT_FINANCE_REJECTED,shipment,
                new ObjectMapper().createObjectNode().put("reason","上一版已办结原因").put("reviewRevision",1));
        verifyNoInteractions(notice,users);verifyNoMoreInteractions(outbox);
    }

    @Test
    void preplanSupplyActionPublishesOnceAndDeliversToDeduplicatedPurchasePool() {
        UUID actionId = UUID.randomUUID();
        UUID requestId = UUID.randomUUID();
        UUID roleBuyerId = UUID.randomUUID();
        UUID departmentBuyerId = UUID.randomUUID();
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        NoticeService notice = mock(NoticeService.class);
        UserAccountRepository users = mock(UserAccountRepository.class);
        PermissionResolver permissions = mock(PermissionResolver.class);
        UserRoleRepository roles = mock(UserRoleRepository.class);
        BusinessEventPublisher outbox = mock(BusinessEventPublisher.class);
        UserAccount roleBuyer = activeUser(roleBuyerId);
        UserAccount departmentBuyer = activeUser(departmentBuyerId);
        when(jdbc.queryForList(
                contains("FROM preplan_supply_actions supply"),
                eq(actionId))).thenReturn(List.of(Map.of(
                        "route", "BUY",
                        "requested_qty", new BigDecimal("12.5000"),
                        "need_date", LocalDate.of(2026, 9, 8),
                        "external_document_type", "PURCHASE_REQUEST",
                        "external_document_id", requestId,
                        "external_document_no", "SQ-001",
                        "goods_code", "WL-001",
                        "goods_name", "\u6d4b\u8bd5\u7269\u6599")));
        when(roles.findUserIdsByRoleCode("buyer"))
                .thenReturn(List.of(roleBuyerId));
        when(jdbc.queryForList(
                contains("WITH RECURSIVE subtree"),
                eq(UUID.class),
                eq("SUB_PURCHASE")))
                .thenReturn(List.of(roleBuyerId, departmentBuyerId));
        when(users.findById(roleBuyerId))
                .thenReturn(Optional.of(roleBuyer));
        when(users.findById(departmentBuyerId))
                .thenReturn(Optional.of(departmentBuyer));
        when(permissions.permsOf(roleBuyer)).thenReturn(Set.of(
                "notice:read", "purchase_request:view"));
        when(permissions.permsOf(departmentBuyer)).thenReturn(Set.of(
                "notice:read", "purchase_request:view"));
        ChainNoticeService service = service(
                notice, users, permissions, roles, jdbc, outbox);

        service.notifyPreplanSupplyActionCreated(actionId);

        verify(outbox).publishOnce(
                ChainNoticeService.EVENT_PREPLAN_SUPPLY_ACTION_CREATED,
                "PREPLAN_SUPPLY_ACTION",
                actionId,
                Map.of(),
                ChainNoticeService.EVENT_PREPLAN_SUPPLY_ACTION_CREATED + ':' + actionId);

        service.deliverOutboxEvent(
                ChainNoticeService.EVENT_PREPLAN_SUPPLY_ACTION_CREATED,
                actionId,
                new ObjectMapper().createObjectNode());

        verify(notice).publishForUser(
                eq(roleBuyerId),
                eq("\u65b0\u91c7\u8d2d\u9700\u6c42\uff1aSQ-001"),
                contains("\u6d4b\u8bd5\u7269\u6599\uff0c\u6570\u91cf 12.5"
                        + "\uff0c\u9700\u6c42\u65e5\u671f 2026-09-08"),
                eq(ChainNoticeService.TYPE_TASK),
                anyString(),
                eq("/purchase/requests/" + requestId),
                eq(ChainNoticeService.EVENT_PREPLAN_SUPPLY_ACTION_CREATED));
        verify(notice).publishForUser(
                eq(departmentBuyerId),
                eq("\u65b0\u91c7\u8d2d\u9700\u6c42\uff1aSQ-001"),
                contains("\u6d4b\u8bd5\u7269\u6599\uff0c\u6570\u91cf 12.5"
                        + "\uff0c\u9700\u6c42\u65e5\u671f 2026-09-08"),
                eq(ChainNoticeService.TYPE_TASK),
                anyString(),
                eq("/purchase/requests/" + requestId),
                eq(ChainNoticeService.EVENT_PREPLAN_SUPPLY_ACTION_CREATED));
    }

    @Test
    void preplanSubcontractActionUsesApplicationDeepLinkAndCancelledActionIsSilent() {
        UUID subcontractActionId = UUID.randomUUID();
        UUID cancelledActionId = UUID.randomUUID();
        UUID applicationId = UUID.randomUUID();
        UUID buyerId = UUID.randomUUID();
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        NoticeService notice = mock(NoticeService.class);
        UserAccountRepository users = mock(UserAccountRepository.class);
        PermissionResolver permissions = mock(PermissionResolver.class);
        UserRoleRepository roles = mock(UserRoleRepository.class);
        UserAccount buyer = activeUser(buyerId);
        when(jdbc.queryForList(
                contains("FROM preplan_supply_actions supply"),
                eq(subcontractActionId))).thenReturn(List.of(Map.of(
                        "route", "SUBCONTRACT",
                        "requested_qty", new BigDecimal("3.0000"),
                        "need_date", LocalDate.of(2026, 9, 9),
                        "external_document_type", "SUBCONTRACT_APPLICATION",
                        "external_document_id", applicationId,
                        "external_document_no", "WS-001",
                        "goods_code", "WL-002",
                        "goods_name", "\u59d4\u5916\u7269\u6599")));
        when(jdbc.queryForList(
                contains("FROM preplan_supply_actions supply"),
                eq(cancelledActionId))).thenReturn(List.of());
        when(roles.findUserIdsByRoleCode("buyer"))
                .thenReturn(List.of(buyerId));
        when(jdbc.queryForList(
                contains("WITH RECURSIVE subtree"),
                eq(UUID.class),
                eq("SUB_PURCHASE"))).thenReturn(List.of());
        when(users.findById(buyerId))
                .thenReturn(Optional.of(buyer));
        when(permissions.permsOf(buyer)).thenReturn(Set.of(
                "notice:read", "subcontract_application:view"));
        ChainNoticeService service = service(
                notice,
                users,
                permissions,
                roles,
                jdbc,
                mock(BusinessEventPublisher.class));

        service.deliverOutboxEvent(
                ChainNoticeService.EVENT_PREPLAN_SUPPLY_ACTION_CREATED,
                subcontractActionId,
                new ObjectMapper().createObjectNode());

        verify(notice).publishForUser(
                eq(buyerId),
                eq("\u65b0\u59d4\u5916\u9700\u6c42\uff1aWS-001"),
                contains("\u59d4\u5916\u7269\u6599\uff0c\u6570\u91cf 3"
                        + "\uff0c\u9700\u6c42\u65e5\u671f 2026-09-09"),
                eq(ChainNoticeService.TYPE_TASK),
                anyString(),
                eq("/subcontract/applications/" + applicationId),
                eq(ChainNoticeService.EVENT_PREPLAN_SUPPLY_ACTION_CREATED));

        service.deliverOutboxEvent(
                ChainNoticeService.EVENT_PREPLAN_SUPPLY_ACTION_CREATED,
                cancelledActionId,
                new ObjectMapper().createObjectNode());

        verify(jdbc).queryForList(
                contains("FROM preplan_supply_actions supply"),
                eq(cancelledActionId));
        verifyNoMoreInteractions(notice);
    }

    @Test
    void preplanPurchaseRecipientsRequireNoticeReadAndRequestView() {
        UUID actionId = UUID.randomUUID();
        UUID requestId = UUID.randomUUID();
        UUID noticeOnlyId = UUID.randomUUID();
        UUID requestOnlyId = UUID.randomUUID();
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        NoticeService notice = mock(NoticeService.class);
        UserAccountRepository users = mock(UserAccountRepository.class);
        PermissionResolver permissions = mock(PermissionResolver.class);
        UserRoleRepository roles = mock(UserRoleRepository.class);
        UserAccount noticeOnly = activeUser(noticeOnlyId);
        UserAccount requestOnly = activeUser(requestOnlyId);

        when(jdbc.queryForList(
                contains("FROM preplan_supply_actions supply"),
                eq(actionId))).thenReturn(List.of(Map.of(
                        "route", "BUY",
                        "requested_qty", new BigDecimal("1.0000"),
                        "need_date", LocalDate.of(2026, 9, 10),
                        "external_document_type", "PURCHASE_REQUEST",
                        "external_document_id", requestId,
                        "external_document_no", "SQ-REVOKE",
                        "goods_code", "WL-003",
                        "goods_name", "权限测试物料")));
        when(roles.findUserIdsByRoleCode("buyer"))
                .thenReturn(List.of(noticeOnlyId));
        when(jdbc.queryForList(
                contains("WITH RECURSIVE subtree"),
                eq(UUID.class),
                eq("SUB_PURCHASE")))
                .thenReturn(List.of(noticeOnlyId, requestOnlyId));
        when(users.findById(noticeOnlyId)).thenReturn(Optional.of(noticeOnly));
        when(users.findById(requestOnlyId)).thenReturn(Optional.of(requestOnly));
        when(permissions.permsOf(noticeOnly)).thenReturn(Set.of("notice:read"));
        when(permissions.permsOf(requestOnly))
                .thenReturn(Set.of("purchase_request:view"));
        ChainNoticeService service = service(
                notice, users, permissions, roles, jdbc, mock(BusinessEventPublisher.class));

        service.deliverOutboxEvent(
                ChainNoticeService.EVENT_PREPLAN_SUPPLY_ACTION_CREATED,
                actionId,
                new ObjectMapper().createObjectNode());

        verifyNoInteractions(notice);
    }

    @Test
    void remakeEventUsesDailyReportUuidForPublishAndDeliveryLookup() {
        UUID reportId = UUID.randomUUID();
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        BusinessEventPublisher outbox = mock(BusinessEventPublisher.class);
        when(jdbc.queryForList(
                contains("FROM production_daily_reports"),
                eq(reportId))).thenReturn(List.of(Map.of("bill_no", "DR-001")));
        when(jdbc.queryForList(
                contains("WHERE rp.source_daily_report_id = ?"),
                eq(reportId))).thenReturn(List.of());
        ChainNoticeService service = service(jdbc, outbox);

        service.notifyRemakeCreated(reportId);

        verify(outbox).publish(
                ChainNoticeService.EVENT_REMAKE_CREATED,
                "PRODUCTION_DAILY_REPORT",
                reportId,
                Map.of());

        service.deliverOutboxEvent(
                ChainNoticeService.EVENT_REMAKE_CREATED,
                reportId,
                new ObjectMapper().createObjectNode());

        verify(jdbc).queryForList(
                contains("WHERE rp.source_daily_report_id = ?"),
                eq(reportId));
    }

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
                eq(ChainNoticeService.EVENT_FINISHED_INBOUND),
                eq("normal"));
    }

    @Test
    void warehouseHandoffsAreDurableAndDocumentScoped() {
        UUID finishedInId = UUID.randomUUID();
        UUID shipmentId = UUID.randomUUID();
        BusinessEventPublisher outbox = mock(BusinessEventPublisher.class);
        JdbcTemplate jdbc=mock(JdbcTemplate.class);
        ChainNoticeService service = service(jdbc, outbox);

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
                        + shipmentId + ":legacy");

        UUID financePendingId = UUID.randomUUID();
        when(jdbc.queryForList(contains("SELECT shipment.review_revision"),eq(financePendingId)))
                .thenReturn(List.of(Map.of("submission_identity","2:INITIAL")));
        service.notifyShipmentPendingFinanceAudit(financePendingId);
        verify(outbox).publishOnce(
                ChainNoticeService.EVENT_SHIPMENT_PENDING_FINANCE,
                "SALES_SHIPMENT",
                financePendingId,
                Map.of("submissionIdentity","2:INITIAL"),
                ChainNoticeService.EVENT_SHIPMENT_PENDING_FINANCE + ':'
                        + financePendingId+":2:INITIAL");
    }

    @Test
    void pendingShipmentDeliveryTargetsWarehouseWithoutClaimingAllocation() {
        UUID shipmentId = UUID.randomUUID();
        UUID warehouseUserId = UUID.randomUUID();
        UUID revokedWarehouseUserId = UUID.randomUUID();
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        NoticeService notice = mock(NoticeService.class);
        UserAccountRepository users = mock(UserAccountRepository.class);
        PermissionResolver permissions = mock(PermissionResolver.class);
        when(jdbc.queryForList(
                contains("FROM sales_shipments shipment"),
                eq(shipmentId))).thenReturn(List.of(Map.of(
                        "bill_no", "SH-001",
                        "warehouse_name", "成品仓",
                        "shipment_qty", new BigDecimal("5"))));
        when(jdbc.queryForList(
                contains("WITH RECURSIVE subtree(id)"),
                eq(UUID.class),
                eq("SUB_WH"))).thenReturn(List.of(
                        warehouseUserId, revokedWarehouseUserId));
        UserAccount warehouseUser = activeUser(warehouseUserId);
        UserAccount revokedWarehouseUser = activeUser(revokedWarehouseUserId);
        when(users.findById(warehouseUserId))
                .thenReturn(Optional.of(warehouseUser));
        when(users.findById(revokedWarehouseUserId))
                .thenReturn(Optional.of(revokedWarehouseUser));
        when(permissions.permsOf(warehouseUser))
                .thenReturn(Set.of("notice:read", "sales_shipment:warehouse-work"));
        when(permissions.permsOf(revokedWarehouseUser))
                .thenReturn(Set.of("notice:read"));
        ChainNoticeService service = service(
                notice, users, permissions, mock(UserRoleRepository.class),
                jdbc, mock(BusinessEventPublisher.class));

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
                eq(ChainNoticeService.EVENT_SHIPMENT_PENDING_PICK),eq("normal"),eq(shipmentId));
        verify(notice, never()).publishForUser(
                eq(revokedWarehouseUserId), anyString(), anyString(), anyString(),
                anyString(), anyString(), anyString(),anyString(),any(UUID.class));
    }

    @Test
    void financeReleaseRevokedTargetsOnlyWarehouseUsersWithCurrentTaskAuthority() {
        UUID shipmentId = UUID.randomUUID();
        UUID allowed = UUID.randomUUID();
        UUID revoked = UUID.randomUUID();
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        NoticeService notice = mock(NoticeService.class);
        UserAccountRepository users = mock(UserAccountRepository.class);
        PermissionResolver permissions = mock(PermissionResolver.class);
        when(jdbc.queryForList(
                contains("finance_audit = 0"), eq(shipmentId)))
                .thenReturn(List.of(Map.of("bill_no", "SH-REVOKED-001")));
        when(jdbc.queryForList(
                contains("WITH RECURSIVE subtree(id)"),
                eq(UUID.class), eq("SUB_WH")))
                .thenReturn(List.of(allowed, revoked));
        UserAccount allowedUser = activeUser(allowed);
        UserAccount revokedUser = activeUser(revoked);
        when(users.findById(allowed)).thenReturn(Optional.of(allowedUser));
        when(users.findById(revoked)).thenReturn(Optional.of(revokedUser));
        when(permissions.permsOf(allowedUser)).thenReturn(
                Set.of("notice:read", "sales_shipment:warehouse-work"));
        when(permissions.permsOf(revokedUser)).thenReturn(Set.of("notice:read"));
        ChainNoticeService service = service(
                notice, users, permissions, mock(UserRoleRepository.class),
                jdbc, mock(BusinessEventPublisher.class));

        service.deliverOutboxEvent(
                ChainNoticeService.EVENT_SHIPMENT_FINANCE_REVOKED,
                shipmentId,
                new ObjectMapper().createObjectNode());

        verify(notice).publishForUser(
                eq(allowed),
                eq("出货财务放行已撤回：SH-REVOKED-001"),
                contains("请暂停拣货"),
                eq(ChainNoticeService.TYPE_URGENT),
                anyString(),
                eq("/sales/shipments/" + shipmentId),
                eq(ChainNoticeService.EVENT_SHIPMENT_FINANCE_REVOKED));
        verify(notice, never()).publishForUser(
                eq(revoked), anyString(), anyString(), anyString(),
                anyString(), anyString(), anyString());
    }

    @Test
    void pendingFinishedInboundDeliveryTargetsOnlyActiveWarehouseUsers() {
        UUID stockDocId = UUID.randomUUID();
        UUID warehouseUserId = UUID.randomUUID();
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        NoticeService notice = mock(NoticeService.class);
        UserAccountRepository users = mock(UserAccountRepository.class);
        PermissionResolver permissions = mock(PermissionResolver.class);
        UserAccount warehouseUser = activeUser(warehouseUserId);
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
                .thenReturn(Optional.of(warehouseUser));
        when(permissions.permsOf(warehouseUser))
                .thenReturn(Set.of("stock_doc:approve"));
        ChainNoticeService service = new ChainNoticeService(
                notice,
                users,
                permissions,
                mock(UserRoleRepository.class),
                jdbc,
                mock(BusinessEventPublisher.class),
                mock(RdTaskService.class),
                mock(FinanceReviewerEligibilityPort.class),
                mock(com.uten.imp.features.admin.workflow.SalesOrderFinanceConfirmerEligibility.class));

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
    void productionFinishedArrivalPendingPublishesOnceWithReportPayload() {
        UUID reportId = UUID.randomUUID();
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        BusinessEventPublisher outbox = mock(BusinessEventPublisher.class);
        when(jdbc.queryForList(
                contains("FROM production_daily_reports report"),
                eq(reportId))).thenReturn(List.of(Map.of(
                        "id", reportId,
                        "bill_no", "RB-ARRIVAL-001")));
        ChainNoticeService service = service(jdbc, outbox);

        service.notifyProductionFinishedArrivalPending(reportId);

        verify(outbox).publishOnce(
                ChainNoticeService.EVENT_PRODUCTION_FINISHED_ARRIVAL_PENDING,
                "PRODUCTION_DAILY_REPORT",
                reportId,
                Map.of("reportId", reportId, "reportNo", "RB-ARRIVAL-001"),
                ChainNoticeService.EVENT_PRODUCTION_FINISHED_ARRIVAL_PENDING
                        + ':' + reportId);
    }

    @Test
    void productionFinishedArrivalDeliveryRequiresWarehouseViewAndApprove() {
        UUID reportId = UUID.randomUUID();
        UUID allowed = UUID.randomUUID();
        UUID approveOnly = UUID.randomUUID();
        UUID viewOnly = UUID.randomUUID();
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        NoticeService notice = mock(NoticeService.class);
        UserAccountRepository users = mock(UserAccountRepository.class);
        PermissionResolver permissions = mock(PermissionResolver.class);
        when(jdbc.queryForList(
                contains("FROM production_daily_reports report"),
                eq(reportId))).thenReturn(List.of(Map.of(
                        "id", reportId,
                        "bill_no", "RB-ARRIVAL-002")));
        when(jdbc.queryForList(
                contains("WITH RECURSIVE subtree(id)"),
                eq(UUID.class),
                eq("SUB_WH"))).thenReturn(List.of(
                        allowed, approveOnly, viewOnly));
        UserAccount allowedUser = activeUser(allowed);
        UserAccount approveOnlyUser = activeUser(approveOnly);
        UserAccount viewOnlyUser = activeUser(viewOnly);
        when(users.findById(allowed)).thenReturn(Optional.of(allowedUser));
        when(users.findById(approveOnly))
                .thenReturn(Optional.of(approveOnlyUser));
        when(users.findById(viewOnly)).thenReturn(Optional.of(viewOnlyUser));
        when(permissions.permsOf(allowedUser))
                .thenReturn(Set.of("stock_doc:view", "stock_doc:approve"));
        when(permissions.permsOf(approveOnlyUser))
                .thenReturn(Set.of("stock_doc:approve"));
        when(permissions.permsOf(viewOnlyUser))
                .thenReturn(Set.of("stock_doc:view"));
        ChainNoticeService service = new ChainNoticeService(
                notice, users, permissions, mock(UserRoleRepository.class),
                jdbc, mock(BusinessEventPublisher.class),
                mock(RdTaskService.class),
                mock(FinanceReviewerEligibilityPort.class),
                mock(com.uten.imp.features.admin.workflow
                        .SalesOrderFinanceConfirmerEligibility.class));

        service.deliverOutboxEvent(
                ChainNoticeService.EVENT_PRODUCTION_FINISHED_ARRIVAL_PENDING,
                reportId,
                new ObjectMapper().createObjectNode());

        verify(notice).publishForUser(
                eq(allowed),
                eq("待登记生产成品送检：RB-ARRIVAL-002"),
                contains("通知不代替仓库任务队列"),
                eq(ChainNoticeService.TYPE_TASK),
                anyString(),
                eq("/warehouse/production-finished-in/tasks"),
                eq(ChainNoticeService.EVENT_PRODUCTION_FINISHED_ARRIVAL_PENDING));
        verifyNoMoreInteractions(notice);
    }

    @Test
    void nonPendingOrLegacyReportDoesNotPublishWarehouseArrivalNotice() {
        UUID reportId = UUID.randomUUID();
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        BusinessEventPublisher outbox = mock(BusinessEventPublisher.class);
        when(jdbc.queryForList(
                contains("FROM production_daily_reports report"),
                eq(reportId))).thenReturn(List.of());
        ChainNoticeService service = service(jdbc, outbox);

        service.notifyProductionFinishedArrivalPending(reportId);

        verifyNoInteractions(outbox);
    }

    @Test
    void productionReportedCopyUsesDeclaredNotQualifiedQuantity()
            throws Exception {
        String source = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/notice/"
                        + "ChainNoticeService.java"));

        org.assertj.core.api.Assertions.assertThat(source)
                .contains("累计完工申报")
                .contains("等待仓库登记送检、品质放行和最终点收")
                .doesNotContain("已审核，累计合格")
                .doesNotContain("成品入库审核后会再次通知可发货状态");
    }

    @Test
    void iqcPendingTargetsOnlyActiveQualityHandlersAndLinksLiveTaskCenter() {
        UUID receiptId = UUID.randomUUID();
        UUID qualityViewerId = UUID.randomUUID();
        UUID revokedViewerId = UUID.randomUUID();
        UUID inactiveViewerId = UUID.randomUUID();
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        NoticeService notice = mock(NoticeService.class);
        UserAccountRepository users = mock(UserAccountRepository.class);
        PermissionResolver permissionResolver = mock(PermissionResolver.class);
        UserAccount qualityViewer = activeUser(qualityViewerId);
        UserAccount revokedViewer = activeUser(revokedViewerId);
        UserAccount inactiveViewer = activeUser(inactiveViewerId);
        inactiveViewer.setStatus("disabled");
        when(jdbc.queryForList(
                contains("FROM purchase_receipts receipt"),
                eq(receiptId))).thenReturn(List.of(Map.of(
                        "bill_no", "CR-001",
                        "supplier_name", "供应商甲",
                        "warehouse_name", "原料仓")));
        when(jdbc.queryForList(
                contains("AS pending_lines"),
                eq("PURCHASE"),
                eq(receiptId))).thenReturn(List.of(Map.of(
                        "pending_lines", 2L,
                        "pending_base_qty", new BigDecimal("8.0000"))));
        when(jdbc.queryForList(
                contains("WHERE code = 'DEPT_QA'"),
                eq(UUID.class))).thenReturn(List.of(
                        qualityViewerId, revokedViewerId, inactiveViewerId));
        when(users.findById(qualityViewerId)).thenReturn(Optional.of(qualityViewer));
        when(users.findById(revokedViewerId)).thenReturn(Optional.of(revokedViewer));
        when(users.findById(inactiveViewerId)).thenReturn(Optional.of(inactiveViewer));
        when(permissionResolver.permsOf(qualityViewer))
                .thenReturn(Set.of("notice:read", "procurement_inspection:view",
                        "procurement_inspection:handle"));
        when(permissionResolver.permsOf(revokedViewer))
                .thenReturn(Set.of("notice:read", "procurement_inspection:view"));
        ChainNoticeService service = new ChainNoticeService(
                notice,
                users,
                permissionResolver,
                mock(UserRoleRepository.class),
                jdbc,
                mock(BusinessEventPublisher.class),
                mock(RdTaskService.class),
                mock(FinanceReviewerEligibilityPort.class),
                mock(com.uten.imp.features.admin.workflow.SalesOrderFinanceConfirmerEligibility.class));

        service.deliverOutboxEvent(
                ChainNoticeService.EVENT_IQC_PENDING,
                receiptId,
                new ObjectMapper().createObjectNode().put("receiptType", "PURCHASE"));

        verify(jdbc).queryForList(
                contains("WHERE code = 'DEPT_QA'"),
                eq(UUID.class));
        // V459：待检通知携带聚合 (IQC_INSPECTION, receiptId)，整单检验结案时批量撤回。
        verify(notice).publishForUser(
                eq(qualityViewerId),
                eq("待检处置：CR-001"),
                contains("角标和待检数量以任务中心实时数据为准"),
                eq(ChainNoticeService.TYPE_TASK),
                anyString(),
                eq("/quality/task-center"),
                eq(ChainNoticeService.EVENT_IQC_PENDING),
                isNull(),
                eq(receiptId));
        verify(notice, never()).publishForUser(
                eq(revokedViewerId), anyString(), anyString(), anyString(),
                anyString(), anyString(), anyString(), any(), any());
        verify(notice, never()).publishForUser(
                eq(inactiveViewerId), anyString(), anyString(), anyString(),
                anyString(), anyString(), anyString(), any(), any());
    }

    @Test
    void approvedOrderSendsPlannerToMaterialAnalysisBeforeScheduling() {
        UUID orderId = UUID.randomUUID();
        UUID plannerUserId = UUID.randomUUID();
        UUID viewerUserId = UUID.randomUUID();
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
        // 2026-09-05 修弹窗串台：接收池从「planner 角色 ∪ SUB_PLAN 主部门」收敛为
        // 「(主/兼职部门 ∈ SUB_PLAN 子树) AND notice:read AND view AND create」
        // ——夹具改为部门树命中 + 权限解析放行（角色查询不再参与）。
        com.uten.imp.features.auth.PermissionResolver permissions =
                mock(com.uten.imp.features.auth.PermissionResolver.class);
        UserAccount planner = activeUser(plannerUserId);
        UserAccount viewer = activeUser(viewerUserId);
        when(permissions.permsOf(planner)).thenReturn(Set.of(
                "notice:read", "production_material_analysis:view",
                "production_material_analysis:create"));
        when(permissions.permsOf(viewer)).thenReturn(Set.of(
                "notice:read", "production_material_analysis:view"));
        when(jdbc.queryForList(
                contains("WITH RECURSIVE subtree(id)"),
                eq(UUID.class),
                eq("SUB_PLAN"))).thenReturn(List.of(plannerUserId, viewerUserId));
        when(users.findById(plannerUserId))
                .thenReturn(Optional.of(planner));
        when(users.findById(viewerUserId)).thenReturn(Optional.of(viewer));
        ChainNoticeService service = service(
                notice, users, permissions, roles, jdbc, mock(BusinessEventPublisher.class));

        service.deliverOutboxEvent(
                ChainNoticeService.EVENT_ORDER_APPROVED,
                orderId,
                new ObjectMapper().createObjectNode());

        // V477 办结闭环：事件注册进 ReviewNoticeCatalog 且发布绑定
        // (SALES_ORDER, orderId) 聚合——生产部创建物料分析后可按聚合撤回。
        assertTrue(ReviewNoticeCatalog.isReviewEvent(
                ChainNoticeService.EVENT_ORDER_APPROVED));
        verify(notice).publishForUser(
                eq(plannerUserId),
                eq("新订单待物料分析：SO-001"),
                contains("请先核对库存并按采购、委外、自制拆分需求"),
                eq(ChainNoticeService.TYPE_TASK),
                anyString(),
                eq("/production/material-analysis"),
                eq(ChainNoticeService.EVENT_ORDER_APPROVED),
                eq("normal"),
                eq(orderId));
        verify(notice, never()).publishForUser(
                eq(viewerUserId), anyString(), anyString(), anyString(),
                anyString(), anyString(), anyString(), any(), any());
    }

    @Test
    void salesFinanceRejectionCarriesEventActorBusinessTimeAndSourceEvent() {
        UUID orderId = UUID.randomUUID();
        UUID ownerEmployeeId = UUID.randomUUID();
        UUID ownerUserId = UUID.randomUUID();
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        NoticeService notice = mock(NoticeService.class);
        UserAccountRepository users = mock(UserAccountRepository.class);
        when(jdbc.queryForList(
                contains("sales_order.finance_rejected_at"),
                eq(orderId))).thenReturn(List.of(Map.of(
                        "bill_no", "SO-REJECT-001",
                        "owner_employee_id", ownerEmployeeId,
                        "finance_rejected_at",
                        OffsetDateTime.parse("2026-08-27T06:32:00Z"),
                        "reviewer_name", "王会计")));
        when(users.findByEmployeeId(ownerEmployeeId))
                .thenReturn(Optional.of(activeUser(ownerUserId)));
        when(users.findById(ownerUserId))
                .thenReturn(Optional.of(activeUser(ownerUserId)));
        ChainNoticeService service = service(
                notice, users, jdbc, mock(BusinessEventPublisher.class));

        service.deliverOutboxEvent(
                ChainNoticeService.EVENT_ORDER_FINANCE_REJECTED,
                orderId,
                new ObjectMapper().createObjectNode().put("reason", "币种与合同不一致"));

        verify(notice).publishForUser(
                eq(ownerUserId),
                eq("订单被财务驳回：SO-REJECT-001"),
                contains("由财务 王会计 于 2026-08-27 14:32 驳回。驳回原因：币种与合同不一致"),
                eq(ChainNoticeService.TYPE_URGENT),
                anyString(),
                eq("/sales/orders/" + orderId),
                eq(ChainNoticeService.EVENT_ORDER_FINANCE_REJECTED));
    }

    @Test
    void procurementFinanceRejectionCarriesCurrentOutboxSourceEvent() {
        UUID approvalCaseId = UUID.randomUUID();
        UUID orderId = UUID.randomUUID();
        UUID submitterUserId = UUID.randomUUID();
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        NoticeService notice = mock(NoticeService.class);
        UserAccountRepository users = mock(UserAccountRepository.class);
        when(jdbc.queryForList(
                contains("FROM procurement_order_approval_cases approval_case"),
                eq(approvalCaseId))).thenReturn(List.of(Map.of(
                        "bill_no_snapshot", "CG-001",
                        "amount_snapshot", new BigDecimal("1200.00"),
                        "order_type", "PURCHASE",
                        "order_id", orderId,
                        "submitted_by_user_id", submitterUserId,
                        "rejection_reason", "付款条件不完整",
                        "decided_at", OffsetDateTime.parse("2026-08-27T07:15:00Z"),
                        "reviewer_name", "李会计")));
        when(users.findById(submitterUserId))
                .thenReturn(Optional.of(activeUser(submitterUserId)));
        ChainNoticeService service = service(
                notice, users, jdbc, mock(BusinessEventPublisher.class));

        service.deliverOutboxEvent(
                ChainNoticeService.EVENT_PROCUREMENT_FINANCE_REJECTED,
                approvalCaseId,
                new ObjectMapper().createObjectNode());

        verify(notice).publishForUser(
                eq(submitterUserId),
                eq("财务驳回：CG-001"),
                contains("由财务 李会计 于 2026-08-27 15:15 驳回。原因：付款条件不完整"),
                eq(ChainNoticeService.TYPE_URGENT),
                anyString(),
                eq("/purchase/orders/" + orderId),
                eq(ChainNoticeService.EVENT_PROCUREMENT_FINANCE_REJECTED));
    }

    @Test
    void subcontractFinanceApprovalReturnsSubmitterToOrderAndExplainsTargetPreparation() {
        UUID approvalCaseId = UUID.randomUUID();
        UUID orderId = UUID.randomUUID();
        UUID submitterUserId = UUID.randomUUID();
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        NoticeService notice = mock(NoticeService.class);
        UserAccountRepository users = mock(UserAccountRepository.class);
        when(jdbc.queryForList(
                contains("FROM procurement_order_approval_cases approval_case"),
                eq(approvalCaseId))).thenReturn(List.of(Map.of(
                        "bill_no_snapshot", "WW-001",
                        "amount_snapshot", new BigDecimal("800.00"),
                        "order_type", "SUBCONTRACT",
                        "order_id", orderId,
                        "submitted_by_user_id", submitterUserId)));
        when(users.findById(submitterUserId))
                .thenReturn(Optional.of(activeUser(submitterUserId)));
        ChainNoticeService service = service(
                notice, users, jdbc, mock(BusinessEventPublisher.class));

        service.deliverOutboxEvent(
                ChainNoticeService.EVENT_PROCUREMENT_FINANCE_APPROVED,
                approvalCaseId,
                new ObjectMapper().createObjectNode());

        verify(notice).publishForUser(
                eq(submitterUserId),
                eq("财务通过：WW-001"),
                contains("目标件真实审核出仓后才进入仓库预计到货"),
                eq(ChainNoticeService.TYPE_WORKFLOW),
                anyString(),
                eq("/subcontract/orders/" + orderId),
                eq(ChainNoticeService.EVENT_PROCUREMENT_FINANCE_APPROVED));
        verifyNoMoreInteractions(notice);
    }

    @Test
    void subcontractSupplierReturnBroadcastUsesEffectiveTaskPermissionNotPurchaseDepartment() {
        UUID exceptionId = UUID.randomUUID();
        UUID ownerUserId = UUID.randomUUID();
        UUID followerUserId = UUID.randomUUID();
        UUID deniedUserId = UUID.randomUUID();
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        NoticeService notice = mock(NoticeService.class);
        UserAccountRepository users = mock(UserAccountRepository.class);
        PermissionResolver permissions = mock(PermissionResolver.class);
        UserAccount owner = activeUser(ownerUserId);
        UserAccount follower = activeUser(followerUserId);
        UserAccount denied = activeUser(deniedUserId);
        when(users.findAll()).thenReturn(List.of(owner, follower, denied));
        when(users.findById(ownerUserId)).thenReturn(Optional.of(owner));
        when(users.findById(followerUserId)).thenReturn(Optional.of(follower));
        when(permissions.permsOf(owner)).thenReturn(
                Set.of("supplier_return_task:view", "notice:read"));
        when(permissions.permsOf(follower)).thenReturn(
                Set.of("supplier_return_task:view", "notice:read"));
        when(permissions.permsOf(denied)).thenReturn(Set.of("notice:read"));
        when(jdbc.queryForList(
                contains("FROM procurement_arrival_exceptions exception"),
                eq(exceptionId))).thenReturn(List.of(Map.of(
                        "order_type", "SUBCONTRACT",
                        "receipt_bill_no_snapshot", "WR-001",
                        "order_bill_no_snapshot", "WW-001",
                        "owner_user_id", ownerUserId,
                        "return_qty", new BigDecimal("5"))));
        ChainNoticeService service = service(
                notice, users, permissions, mock(UserRoleRepository.class),
                jdbc, mock(BusinessEventPublisher.class));

        service.deliverOutboxEvent(
                ChainNoticeService.EVENT_PROCUREMENT_RETURN_REQUIRED,
                exceptionId,
                new ObjectMapper().createObjectNode());

        verify(notice).publishForUser(
                eq(followerUserId),
                eq("供应商退回任务：WW-001"),
                contains("委外订货单 WW-001"),
                eq(ChainNoticeService.TYPE_TASK),
                anyString(),
                eq("/procurement/arrival-exceptions"),
                eq(ChainNoticeService.EVENT_PROCUREMENT_RETURN_REQUIRED),
                eq("normal"));
        verify(notice, never()).publishForUser(
                eq(deniedUserId), anyString(), anyString(), anyString(),
                anyString(), anyString(), anyString(), anyString());
    }

    @Test
    void subcontractLossOpenedNotifiesEffectiveFinanceReviewPool() {
        UUID caseId = UUID.randomUUID();
        UUID reviewerId = UUID.randomUUID();
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        NoticeService notice = mock(NoticeService.class);
        UserAccountRepository users = mock(UserAccountRepository.class);
        PermissionResolver permissions = mock(PermissionResolver.class);
        UserAccount reviewer = activeUser(reviewerId);
        when(users.findAll()).thenReturn(List.of(reviewer));
        when(users.findById(reviewerId)).thenReturn(Optional.of(reviewer));
        when(permissions.permsOf(reviewer)).thenReturn(
                Set.of("subcontract_loss_claim:review", "notice:read"));
        when(jdbc.queryForList(
                contains("FROM subcontract_loss_cases loss"),
                eq(caseId))).thenReturn(List.of(Map.of(
                        "waste_bill_no", "SH-001",
                        "status", "OPEN",
                        "supplier_name", "委外商甲")));
        ChainNoticeService service = service(
                notice, users, permissions, mock(UserRoleRepository.class),
                jdbc, mock(BusinessEventPublisher.class));

        service.deliverOutboxEvent(
                ChainNoticeService.EVENT_SUBCONTRACT_LOSS_OPENED,
                caseId,
                new ObjectMapper().createObjectNode());

        verify(notice).publishForUser(
                eq(reviewerId),
                eq("委外超耗待财务决定：SH-001"),
                contains("损耗事实本身不会自动冲应付"),
                eq(ChainNoticeService.TYPE_APPROVAL),
                anyString(),
                eq("/finance/payables"),
                eq(ChainNoticeService.EVENT_SUBCONTRACT_LOSS_OPENED));
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
                eq(ChainNoticeService.EVENT_DELIVERY_DUE),
                eq("normal"));
        verify(notice).publishForUser(
                eq(plannerUserId),
                eq("交货预警：SO-002"),
                contains("尚未结案"),
                eq(ChainNoticeService.TYPE_URGENT),
                anyString(),
                eq("/production/material-analysis"),
                eq(ChainNoticeService.EVENT_DELIVERY_DUE),
                eq("normal"));
    }

    @Test
    void retiredPlannerReadyEventIsAcknowledgedWithoutQueryOrDeliveryEvenWhenReplayed() {
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        NoticeService notice = mock(NoticeService.class);
        UserAccountRepository users = mock(UserAccountRepository.class);
        BusinessEventPublisher outbox = mock(BusinessEventPublisher.class);
        ChainNoticeService service = service(notice, users, jdbc, outbox);
        var payload = new ObjectMapper().createObjectNode()
                .put("makerEmployeeId", UUID.randomUUID().toString())
                .put("sourceType", "PURCHASE").put("readyFinishDelta", "3");
        UUID analysisId = UUID.randomUUID();
        service.deliverOutboxEvent(ChainNoticeService.EVENT_MATERIAL_ANALYSIS_READY, analysisId, payload);
        service.deliverOutboxEvent(ChainNoticeService.EVENT_MATERIAL_ANALYSIS_READY, analysisId, payload);
        verifyNoInteractions(jdbc, notice, users, outbox);
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
        return service(
                notice,
                users,
                mock(PermissionResolver.class),
                roles,
                jdbc,
                outbox);
    }

    private static ChainNoticeService service(
            NoticeService notice,
            UserAccountRepository users,
            PermissionResolver permissions,
            UserRoleRepository roles,
            JdbcTemplate jdbc,
            BusinessEventPublisher outbox) {
        return new ChainNoticeService(
                notice,
                users,
                permissions,
                roles,
                jdbc,
                outbox,
                mock(RdTaskService.class),
                mock(FinanceReviewerEligibilityPort.class),
                mock(com.uten.imp.features.admin.workflow.SalesOrderFinanceConfirmerEligibility.class));
    }

    private static UserAccount activeUser(UUID userId) {
        UserAccount user = new UserAccount();
        user.setId(userId);
        user.setStatus("active");
        user.setDeleted(false);
        return user;
    }
}
