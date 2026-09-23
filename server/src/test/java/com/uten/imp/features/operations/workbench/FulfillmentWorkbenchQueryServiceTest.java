package com.uten.imp.features.operations.workbench;

import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.security.access.prepost.PreAuthorize;

import java.lang.reflect.Method;
import java.math.BigDecimal;
import java.sql.Date;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.Collections;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class FulfillmentWorkbenchQueryServiceTest {

    @Test
    void exceptionFilterAndOptionsAreEvaluatedByTheDatabaseNotTheCurrentPage() {
        EntityManager em = mock(EntityManager.class);
        Query rows = mock(Query.class);
        Query summary = mock(Query.class);
        Query statuses = mock(Query.class);
        Query exceptions = mock(Query.class);
        Query pending = mock(Query.class);
        when(em.createNativeQuery(anyString()))
                .thenReturn(rows, summary, statuses, exceptions, pending);
        when(rows.getResultList()).thenReturn(List.of());
        when(summary.getSingleResult()).thenReturn(new Object[]{
                5L, 2L, 4L, new BigDecimal("12")
        });
        when(statuses.getResultList()).thenReturn(
                Collections.singletonList(new Object[]{"UNPEGGED", 3L}));
        when(exceptions.getResultList()).thenReturn(
                Collections.singletonList(new Object[]{"OVERDUE_SHORTAGE", 2L}));
        when(pending.getSingleResult()).thenReturn(4L);

        FulfillmentWorkbenchAccessPolicy accessPolicy =
                mock(FulfillmentWorkbenchAccessPolicy.class);
        FulfillmentWorkbenchPage result = new FulfillmentWorkbenchQueryService(em, accessPolicy)
                .query("PURCHASE", "UNPEGGED", "轴套", "OVERDUE_ANY", null, null, 2, 20);

        verify(rows).setParameter("exception", "OVERDUE_ANY");
        verify(summary).setParameter("exception", "OVERDUE_ANY");
        verify(statuses).setParameter("exception", "OVERDUE_ANY");
        verify(exceptions).setParameter("exception", "");
        assertEquals(2L, result.summary().exceptionCounts().get("OVERDUE_SHORTAGE"));

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em, times(5)).createNativeQuery(sql.capture());
        assertTrue(sql.getAllValues().getFirst().contains("OVERDUE_ANY"));
        assertTrue(sql.getAllValues().get(3).contains("exception_code IS NOT NULL"));
    }

    @Test
    void pendingCardCountIgnoresTheActiveStatusCardFilter() {
        EntityManager em = mock(EntityManager.class);
        Query rows = mock(Query.class);
        Query summary = mock(Query.class);
        Query statuses = mock(Query.class);
        Query exceptions = mock(Query.class);
        Query pending = mock(Query.class);
        when(em.createNativeQuery(anyString()))
                .thenReturn(rows, summary, statuses, exceptions, pending);
        when(rows.getResultList()).thenReturn(List.of());
        when(summary.getSingleResult()).thenReturn(new Object[]{
                3L, 0L, 0L, BigDecimal.ZERO
        });
        when(statuses.getResultList()).thenReturn(List.of());
        when(exceptions.getResultList()).thenReturn(List.of());
        when(pending.getSingleResult()).thenReturn(9L);

        FulfillmentWorkbenchPage result = new FulfillmentWorkbenchQueryService(
                        em, mock(FulfillmentWorkbenchAccessPolicy.class))
                .query("PURCHASE", "COMPLETED", "", "", null, null, 1, 20);

        // 「待完成」卡走部门×关键字全量口径：状态绑定 ""，不被已选「已完成」卡清零。
        verify(pending).setParameter("status", "");
        assertEquals(9L, result.summary().pendingTasks());

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em, times(5)).createNativeQuery(sql.capture());
        assertTrue(sql.getAllValues().getFirst().contains("OPEN_ANY"));
        assertTrue(sql.getAllValues().getLast().contains("open_qty > 0"));
    }

    @Test
    void openAnyStatusSentinelFiltersByOpenQuantity() {
        EntityManager em = mock(EntityManager.class);
        Query rows = mock(Query.class);
        Query summary = mock(Query.class);
        Query statuses = mock(Query.class);
        Query exceptions = mock(Query.class);
        Query pending = mock(Query.class);
        when(em.createNativeQuery(anyString()))
                .thenReturn(rows, summary, statuses, exceptions, pending);
        when(rows.getResultList()).thenReturn(List.of());
        when(summary.getSingleResult()).thenReturn(new Object[]{
                6L, 1L, 6L, new BigDecimal("30")
        });
        when(statuses.getResultList()).thenReturn(List.of());
        when(exceptions.getResultList()).thenReturn(List.of());
        when(pending.getSingleResult()).thenReturn(6L);

        FulfillmentWorkbenchPage result = new FulfillmentWorkbenchQueryService(
                        em, mock(FulfillmentWorkbenchAccessPolicy.class))
                .query("SUBCONTRACT", "OPEN_ANY", "", "", null, null, 1, 20);

        // OPEN_ANY 哨兵原样下传 SQL（按 open_qty > 0 过滤），不当作真实 task_status。
        verify(rows).setParameter("status", "OPEN_ANY");
        assertEquals(6L, result.summary().pendingTasks());
    }

    @Test
    void purchaseCountUsesRequestLineDecompositionProjection() {
        EntityManager em = mock(EntityManager.class);
        Query countQuery = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(countQuery);
        when(countQuery.getSingleResult()).thenReturn(7L);

        long count = new FulfillmentWorkbenchQueryService(
                em, mock(FulfillmentWorkbenchAccessPolicy.class))
                .countPending("PURCHASE");

        assertEquals(7L, count);
        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em).createNativeQuery(sql.capture());
        String captured = sql.getValue();
        assertTrue(captured.contains("v_procurement_decomposition_tasks"));
        assertTrue(captured.contains("open_qty > 0"));
        // 红徽章只数「等本部门动手」的两档（2026-09-11）：等待财务审核 / 财务已通过
        // 下一步在财务和供应商手上，是监控数，混进合计会让工作台卡片数字对不上
        // 页面里各红色分段之和。
        assertTrue(captured.contains(
                "task_status IN ('WAITING_ORDER', 'FINANCE_REJECTED')"));
        assertFalse(captured.contains("FINANCE_APPROVED"));
        assertFalse(captured.contains("ORDER_PENDING_APPROVAL"));
        verify(countQuery).setParameter("department", "PURCHASE");
    }

    /**
     * ADR-103 路线 B: 委外红数要剔除「子件仓里一件都没有」的申请行, 判据片段与列表同一常量;
     * 采购分支的 SQL 一个字都不能带上这段.
     */
    @Test
    void subcontractPendingCountExcludesRouteBLockedApplicationsAndPurchaseStaysUntouched() {
        EntityManager em = mock(EntityManager.class);
        Query countQuery = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(countQuery);
        when(countQuery.getSingleResult()).thenReturn(2L);
        FulfillmentWorkbenchQueryService service = new FulfillmentWorkbenchQueryService(
                em, mock(FulfillmentWorkbenchAccessPolicy.class));

        assertEquals(2L, service.countPending("SUBCONTRACT"));
        assertEquals(2L, service.countPending("PURCHASE"));

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em, times(2)).createNativeQuery(sql.capture());
        // ADR-103 (2026-09-22 用户实机纠偏): 锁行照计红数, 与路线 A 合成行同款——红数 SQL 不碰子件库存.
        String subcontract = sql.getAllValues().getFirst();
        assertFalse(subcontract.contains("fn_subcontract_sole_component_goods"));
        assertFalse(subcontract.contains("v_stock_available"));
        assertTrue(subcontract.contains("decomposition.task_status IN ('WAITING_ORDER', 'FINANCE_REJECTED')"));
        String purchase = sql.getAllValues().getLast();
        assertFalse(purchase.contains("fn_subcontract_sole_component_goods"));
        assertFalse(purchase.contains("v_stock_available"));
        assertFalse(purchase.contains("decomposition.action_doc_type"));
    }

    /** ADR-103 (2026-09-22 用户实机纠偏): 锁行留在待处理段, 黄数只数财审三档, 不再把锁行加进来. */
    @Test
    void subcontractInProgressCountAddsRouteBLockedApplications() {
        EntityManager em = mock(EntityManager.class);
        Query countQuery = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(countQuery);
        when(countQuery.getSingleResult()).thenReturn(1L);
        FulfillmentWorkbenchQueryService service = new FulfillmentWorkbenchQueryService(
                em, mock(FulfillmentWorkbenchAccessPolicy.class));

        assertEquals(1L, service.countInProgress("SUBCONTRACT"));
        assertEquals(1L, service.countInProgress("PURCHASE"));

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em, times(2)).createNativeQuery(sql.capture());
        String subcontract = sql.getAllValues().getFirst();
        assertFalse(subcontract.contains("fn_subcontract_sole_component_goods"));
        assertFalse(subcontract.contains("decomposition.open_qty > 0 AND"));
        assertTrue(subcontract.contains("task_status IN ('ORDER_PENDING_APPROVAL', 'FINANCE_APPROVED', 'FINANCE_REJECTED')"));
        String purchase = sql.getAllValues().getLast();
        assertFalse(purchase.contains("fn_subcontract_sole_component_goods"));
        assertTrue(purchase.contains("task_status IN ('ORDER_PENDING_APPROVAL', 'FINANCE_APPROVED', 'FINANCE_REJECTED')"));
    }

    /**
     * ADR-103: 委外列表行带路线 B 的三个阶段码与 component_available_qty 列, 锁行不能生成订货单;
     * 分段计数仍按 task_status 分桶(锁行留在 WAITING_ORDER, 用户口径「刚下单的都是待处理」),
     * WAITING_COMPONENT_STOCK 键只是其中在等子件的行数(说明用), IN_PROGRESS 只数财审三档.
     */
    @Test
    void subcontractRowsCarryComponentLockStagesAndStatusCountsSplitTheLockedBucket() {
        EntityManager em = mock(EntityManager.class);
        Query rows = mock(Query.class);
        Query summary = mock(Query.class);
        Query statuses = mock(Query.class);
        Query exceptions = mock(Query.class);
        Query pending = mock(Query.class);
        when(em.createNativeQuery(anyString()))
                .thenReturn(rows, summary, statuses, exceptions, pending);
        when(rows.getResultList()).thenReturn(List.of());
        when(summary.getSingleResult()).thenReturn(new Object[]{3L, 0L, 3L, new BigDecimal("30")});
        when(statuses.getResultList()).thenReturn(List.of(
                new Object[]{"FINANCE_APPROVED", 1L, 0L},
                new Object[]{"WAITING_ORDER", 4L, 2L}));
        when(exceptions.getResultList()).thenReturn(List.of());
        when(pending.getSingleResult()).thenReturn(3L);
        FulfillmentWorkbenchAccessPolicy accessPolicy = mock(FulfillmentWorkbenchAccessPolicy.class);
        when(accessPolicy.canCreateSubcontractOrder()).thenReturn(true);

        FulfillmentWorkbenchPage page = new FulfillmentWorkbenchQueryService(em, accessPolicy)
                .query("SUBCONTRACT", "WAITING_ORDER", "", "", null, null, 1, 20);

        assertEquals(2L, page.summary().statusCounts().get("WAITING_COMPONENT_STOCK"));
        assertEquals(4L, page.summary().statusCounts().get("WAITING_ORDER"), "锁行留在 WAITING_ORDER 桶里, 不减");
        assertEquals(1L, page.summary().statusCounts().get("IN_PROGRESS"), "黄数只数财审三档");

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em, times(5)).createNativeQuery(sql.capture());
        String rowsSql = sql.getAllValues().getFirst();
        assertTrue(rowsSql.contains("'WAITING_COMPONENT_STOCK'"));
        assertTrue(rowsSql.contains("'COMPONENT_STOCK_READY'"));
        assertTrue(rowsSql.contains("WHEN progress.waiting_component THEN 'OUTBOUND_WAITING_COMPONENT'"));
        assertTrue(rowsSql.contains("AND NOT COALESCE(component.locked, FALSE)) AS can_create_order"));
        assertTrue(rowsSql.contains("component.available_qty AS component_available_qty"));
        assertTrue(rowsSql.contains("waiting_item.flow_mode = 'COMPONENT_OUTBOUND'"));
        assertTrue(rowsSql.contains(FulfillmentWorkbenchQueryService.COMPONENT_STOCK_AVAILABLE_SQL
                .formatted("waiting_item.goods_id", "waiting_item.color_id")));
        // 锁行留在「待处理」段: 分段筛选按 task_status, 与采购同一句 SQL; 分桶只顺带数在等子件的行数.
        assertFalse(rowsSql.contains("display_stage IS DISTINCT FROM 'WAITING_COMPONENT_STOCK'"));
        assertTrue(rowsSql.contains("OR (:status NOT IN ('OPEN_ANY', 'IN_PROGRESS') AND task_status = :status)"));
        String statusSql = sql.getAllValues().get(2);
        assertTrue(statusSql.contains("COUNT(*) FILTER (WHERE display_stage = 'WAITING_COMPONENT_STOCK')"));
        assertTrue(statusSql.contains("GROUP BY task_status"));
    }

    /** 采购列表不拼委外的子件锁, 只补一列 NULL 占位, 行映射两边同宽. */
    @Test
    void purchaseRowsDoNotCarryTheSubcontractComponentLock() {
        EntityManager em = mock(EntityManager.class);
        Query rows = mock(Query.class);
        Query summary = mock(Query.class);
        Query statuses = mock(Query.class);
        Query exceptions = mock(Query.class);
        Query pending = mock(Query.class);
        when(em.createNativeQuery(anyString()))
                .thenReturn(rows, summary, statuses, exceptions, pending);
        when(rows.getResultList()).thenReturn(List.of());
        when(summary.getSingleResult()).thenReturn(new Object[]{0L, 0L, 0L, BigDecimal.ZERO});
        when(statuses.getResultList()).thenReturn(List.of());
        when(exceptions.getResultList()).thenReturn(List.of());
        when(pending.getSingleResult()).thenReturn(0L);

        FulfillmentWorkbenchPage page = new FulfillmentWorkbenchQueryService(
                em, mock(FulfillmentWorkbenchAccessPolicy.class))
                .query("PURCHASE", "", "", "", null, null, 1, 20);

        assertFalse(page.summary().statusCounts().containsKey("WAITING_COMPONENT_STOCK"));
        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em, times(5)).createNativeQuery(sql.capture());
        String rowsSql = sql.getAllValues().getFirst();
        assertTrue(rowsSql.contains("NULL::numeric AS component_available_qty"));
        assertFalse(rowsSql.contains("component.locked"));
        assertFalse(rowsSql.contains("fn_subcontract_sole_component_goods"));
        assertTrue(rowsSql.contains("OR (:status NOT IN ('OPEN_ANY', 'IN_PROGRESS') AND task_status = :status)"));
    }

    /** ADR-103: 第 38 列 component_available_qty 读进行对象, 脱敏/透传两条路都不丢, 短行 (旧 34 列) 为 null. */
    @Test
    void componentAvailableQtyIsReadFromTheRowAndSurvivesActionCopy() {
        EntityManager em = mock(EntityManager.class);
        Query rows = mock(Query.class);
        Query summary = mock(Query.class);
        Query statuses = mock(Query.class);
        Query exceptions = mock(Query.class);
        Query pending = mock(Query.class);
        when(em.createNativeQuery(anyString()))
                .thenReturn(rows, summary, statuses, exceptions, pending);
        when(pending.getSingleResult()).thenReturn(0L);
        UUID documentId = UUID.randomUUID();
        Object[] wide = java.util.Arrays.copyOf(
                taskRow("SUBCONTRACT", "SUBCONTRACT_APPLICATION", documentId, UUID.randomUUID()), 38);
        wide[35] = Boolean.TRUE;
        wide[36] = "COMPONENT_STOCK_READY";
        wide[37] = new BigDecimal("7.5");
        when(rows.getResultList()).thenReturn(List.of(
                wide, taskRow("SUBCONTRACT", "SUBCONTRACT_APPLICATION", UUID.randomUUID(), UUID.randomUUID())));
        when(summary.getSingleResult()).thenReturn(new Object[]{2L, 0L, 2L, BigDecimal.TEN});
        when(statuses.getResultList()).thenReturn(List.of());
        when(exceptions.getResultList()).thenReturn(List.of());
        FulfillmentWorkbenchAccessPolicy accessPolicy = mock(FulfillmentWorkbenchAccessPolicy.class);
        when(accessPolicy.documentAccess("SUBCONTRACT", "SUBCONTRACT_APPLICATION"))
                .thenReturn(new FulfillmentWorkbenchAccessPolicy.DocumentAccess(true, true));

        FulfillmentWorkbenchPage page = new FulfillmentWorkbenchQueryService(em, accessPolicy)
                .query("SUBCONTRACT", "", "", "", null, null, 1, 20);

        FulfillmentTaskRow ready = page.items().getFirst();
        assertEquals(0, new BigDecimal("7.5").compareTo(ready.componentAvailableQty()));
        assertEquals("COMPONENT_STOCK_READY", ready.displayStage());
        assertTrue(ready.canCreateOrder());
        assertEquals(null, page.items().get(1).componentAvailableQty());
    }

    @Test
    void warehouseCountUsesTheFulfillmentProjectionAndOpenQuantity() {
        EntityManager em = mock(EntityManager.class);
        Query countQuery = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(countQuery);
        when(countQuery.getSingleResult()).thenReturn(4L);
        FulfillmentWorkbenchAccessPolicy accessPolicy =
                mock(FulfillmentWorkbenchAccessPolicy.class);
        when(accessPolicy.canAccessWarehouseTasks()).thenReturn(true);

        long count = new FulfillmentWorkbenchQueryService(
                em, accessPolicy)
                .countPending("WAREHOUSE");

        assertEquals(4L, count);
        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em).createNativeQuery(sql.capture());
        // 2026-09-03 仓库口径与列表归组对齐：一张 DRAW 领料单=一个待办
        //（DISTINCT COALESCE 兜底尚未挂单的行级需求）。
        assertTrue(sql.getValue().contains("v_fulfillment_workbench_actions"));
        assertTrue(sql.getValue().contains("open_qty > 0"));
        assertTrue(sql.getValue().contains("fn_production_draw_pending(action_doc_id)"));
        assertTrue(sql.getValue()
                .contains("DISTINCT COALESCE(action_doc_id, task_id)"));
        verify(countQuery).setParameter("department", "WAREHOUSE");
    }

    @Test
    void warehouseListAndStatusBreakdownRequireTheSameExplicitRequest() {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of());
        FulfillmentWorkbenchAccessPolicy access = mock(FulfillmentWorkbenchAccessPolicy.class);
        when(access.canAccessWarehouseTasks()).thenReturn(true);

        new FulfillmentWorkbenchQueryService(em, access).warehouseStatusBreakdown();

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em).createNativeQuery(sql.capture());
        assertTrue(sql.getValue().contains(FulfillmentWorkbenchQueryService.WAREHOUSE_DOCUMENT_ROWS));
        assertTrue(sql.getValue().contains("fn_production_draw_requested(v.action_doc_id)"));
    }

    @Test
    void warehouseCountIsZeroOutsideTheWarehouseOrganizationScope() {
        EntityManager em = mock(EntityManager.class);
        FulfillmentWorkbenchAccessPolicy accessPolicy =
                mock(FulfillmentWorkbenchAccessPolicy.class);

        long count = new FulfillmentWorkbenchQueryService(
                em, accessPolicy).countPending("WAREHOUSE");

        assertEquals(0L, count);
        verify(em, org.mockito.Mockito.never()).createNativeQuery(anyString());
    }

    @Test
    void actionMetadataIsMaskedWhenTheExactDocumentPermissionIsMissing() {
        EntityManager em = mock(EntityManager.class);
        Query rows = mock(Query.class);
        Query summary = mock(Query.class);
        Query statuses = mock(Query.class);
        Query exceptions = mock(Query.class);
        Query pending = mock(Query.class);
        when(em.createNativeQuery(anyString()))
                .thenReturn(rows, summary, statuses, exceptions, pending);
        when(pending.getSingleResult()).thenReturn(0L);
        UUID documentId = UUID.randomUUID();
        UUID documentItemId = UUID.randomUUID();
        when(rows.getResultList()).thenReturn(Collections.singletonList(taskRow(
                "PURCHASE", "PURCHASE_ORDER", documentId, documentItemId)));
        when(summary.getSingleResult()).thenReturn(new Object[]{1L, 0L, 1L, BigDecimal.ONE});
        when(statuses.getResultList()).thenReturn(List.of());
        when(exceptions.getResultList()).thenReturn(List.of());
        FulfillmentWorkbenchAccessPolicy accessPolicy =
                mock(FulfillmentWorkbenchAccessPolicy.class);
        when(accessPolicy.documentAccess("PURCHASE", "PURCHASE_ORDER"))
                .thenReturn(new FulfillmentWorkbenchAccessPolicy.DocumentAccess(false, false));

        FulfillmentWorkbenchPage page =
                new FulfillmentWorkbenchQueryService(em, accessPolicy)
                        .query("PURCHASE", "", "", "", null, null, 1, 20);

        FulfillmentTaskRow task = page.items().getFirst();
        assertTrue(task.actionDocRestricted());
        assertEquals(null, task.actionDocType());
        assertEquals(null, task.actionDocId());
        assertEquals(null, task.actionDocNo());
        assertEquals(null, task.actionDocItemId());
        assertEquals(null, task.actionDocStatus());
        assertTrue(!task.actionDocCanView());
        assertTrue(!task.actionDocCanEdit());
    }

    @Test
    void actionAndBatchCapabilitiesUseSeparateViewAndEditPermissions() {
        EntityManager em = mock(EntityManager.class);
        Query rows = mock(Query.class);
        Query summary = mock(Query.class);
        Query statuses = mock(Query.class);
        Query exceptions = mock(Query.class);
        Query pending = mock(Query.class);
        when(em.createNativeQuery(anyString()))
                .thenReturn(rows, summary, statuses, exceptions, pending);
        when(pending.getSingleResult()).thenReturn(0L);
        UUID documentId = UUID.randomUUID();
        UUID documentItemId = UUID.randomUUID();
        when(rows.getResultList()).thenReturn(Collections.singletonList(taskRow(
                "PURCHASE", "PURCHASE_REQUEST", documentId, documentItemId)));
        when(summary.getSingleResult()).thenReturn(new Object[]{1L, 0L, 1L, BigDecimal.ONE});
        when(statuses.getResultList()).thenReturn(List.of());
        when(exceptions.getResultList()).thenReturn(List.of());
        FulfillmentWorkbenchAccessPolicy accessPolicy =
                mock(FulfillmentWorkbenchAccessPolicy.class);
        when(accessPolicy.documentAccess("PURCHASE", "PURCHASE_REQUEST"))
                .thenReturn(new FulfillmentWorkbenchAccessPolicy.DocumentAccess(true, false));
        when(accessPolicy.canCreatePurchaseOrder()).thenReturn(true);

        FulfillmentWorkbenchPage page =
                new FulfillmentWorkbenchQueryService(em, accessPolicy)
                        .query("PURCHASE", "", "", "", null, null, 1, 20);

        FulfillmentTaskRow task = page.items().getFirst();
        assertEquals(documentId, task.actionDocId());
        assertEquals(documentItemId, task.actionDocItemId());
        assertTrue(task.actionDocCanView());
        assertTrue(!task.actionDocCanEdit());
        assertTrue(!task.actionDocRestricted());
        assertTrue(page.capabilities().canCreatePurchaseOrder());
    }

    @Test
    void purchaseCountEndpointGuardsPurchaseReadPermissions() throws Exception {
        Method method = FulfillmentWorkbenchController.class.getDeclaredMethod("purchaseCount");
        assertEquals(
                "hasAnyAuthority('purchase_request:view','purchase_order:view','purchase_receipt:view','purchase_return:view')",
                method.getAnnotation(PreAuthorize.class).value());
    }

    @Test
    void warehouseCountEndpointRequiresStockDocumentView() throws Exception {
        Method method = FulfillmentWorkbenchController.class.getDeclaredMethod(
                "warehouseCount");
        assertEquals(
                "hasAuthority('stock_doc:view')",
                method.getAnnotation(PreAuthorize.class).value());
    }

    @Test
    void controllerReadPermissionsMatchFlutterAnyPermissionGuards() throws Exception {
        assertPermission(
                "warehouse",
                "hasAnyAuthority('stock_doc:view')");
        assertPermission(
                "purchase",
                "hasAnyAuthority('purchase_request:view','purchase_order:view','purchase_receipt:view','purchase_return:view')");
        assertPermission(
                "subcontract",
                "hasAnyAuthority('subcontract_inquiry:view','subcontract_application:view','subcontract_order:view','subcontract_receipt:view','subcontract_material_issue:view','subcontract_return:view','subcontract_material_return:view','subcontract_waste:view')");
    }

    private static void assertPermission(String methodName, String expected) throws Exception {
        // 控制器读端点签名：status/exception/keyword + dateFrom/dateTo + 分页。
        Method method = java.util.Arrays.stream(FulfillmentWorkbenchController.class.getDeclaredMethods())
                .filter(candidate -> candidate.getName().equals(methodName)).findFirst().orElseThrow();
        assertEquals(expected, method.getAnnotation(PreAuthorize.class).value());
    }

    private static Object[] taskRow(
            String department,
            String documentType,
            UUID documentId,
            UUID documentItemId) {
        return new Object[]{
                department,
                UUID.randomUUID(),
                UUID.randomUUID(),
                UUID.randomUUID(),
                "PP-001",
                UUID.randomUUID(),
                "原材料仓",
                UUID.randomUUID(),
                "MAT-001",
                "轴套",
                "φ20",
                null,
                "",
                UUID.randomUUID(),
                "件",
                "PURCHASE",
                BigDecimal.TEN,
                BigDecimal.ZERO,
                BigDecimal.ZERO,
                BigDecimal.ZERO,
                BigDecimal.TEN,
                "WAITING_SUPPLY",
                Date.valueOf(LocalDate.of(2026, 8, 1)),
                null,
                null,
                OffsetDateTime.parse("2026-08-01T10:00:00+08:00"),
                documentType,
                documentId,
                "DOC-001",
                documentItemId,
                "1",
                // 2026-09-03 按单据归组新增列：单货品行 goods_count=1、
                // open_line_count=1、action_item_ids=null（stringArray 回空表）。
                1L,
                1L,
                null
        };
    }
}
