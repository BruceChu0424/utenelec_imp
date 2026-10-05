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
     * 委外红数只数申请待分解、财务驳回与回厂短交待判定; 「可领料」的委外任务是「领料」分段的红数,
     * 由委外领料模块单独登记, 这里不能再数一遍; 前置自制合成行已经删除。采购分支不带委外片段。
     */
    @Test
    void subcontractPendingCountLeavesDrawableTasksToTheDrawSegmentAndPurchaseStaysUntouched() {
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
        String subcontract = sql.getAllValues().getFirst();
        assertTrue(subcontract.contains("decomposition.task_status IN ('WAITING_ORDER', 'FINANCE_REJECTED')"));
        assertTrue(subcontract.contains("subcontract_short_delivery_cases"));
        assertFalse(subcontract.contains("fn_subcontract_draw_summary"));
        assertFalse(subcontract.contains("preplan_subcontract_make_tasks"));
        String purchase = sql.getAllValues().getLast();
        assertFalse(purchase.contains("subcontract_short_delivery_cases"));
        assertFalse(purchase.contains("decomposition.action_doc_type"));
    }

    /** 黄数只数财审三档(等待财务审核 / 财务已通过 / 财务已退回), 采购与委外同一口径。 */
    @Test
    void inProgressCountOnlyCountsTheThreeFinanceStages() {
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
        for (String captured : sql.getAllValues()) {
            assertFalse(captured.contains("decomposition.open_qty > 0 AND"));
            assertTrue(captured.contains(
                    "task_status IN ('ORDER_PENDING_APPROVAL', 'FINANCE_APPROVED', 'FINANCE_REJECTED')"));
        }
    }

    /**
     * ADR-143 §4.1: 已批准委外订货单的「进行中」状态列按领料模型取第一个命中, 可领料逐明细按
     * fn_subcontract_draw_summary 判; 分段计数仍按 task_status 分桶, IN_PROGRESS 只数财审三档。
     */
    @Test
    void subcontractOrderStagesFollowTheDrawModelAndStatusCountsStayOnTaskStatus() {
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
                new Object[]{"FINANCE_APPROVED", 1L},
                new Object[]{"WAITING_ORDER", 4L}));
        when(exceptions.getResultList()).thenReturn(List.of());
        when(pending.getSingleResult()).thenReturn(3L);
        FulfillmentWorkbenchAccessPolicy accessPolicy = mock(FulfillmentWorkbenchAccessPolicy.class);
        when(accessPolicy.canCreateSubcontractOrder()).thenReturn(true);

        FulfillmentWorkbenchPage page = new FulfillmentWorkbenchQueryService(em, accessPolicy)
                .query("SUBCONTRACT", "WAITING_ORDER", "", "", null, null, 1, 20);

        assertEquals(4L, page.summary().statusCounts().get("WAITING_ORDER"));
        assertEquals(1L, page.summary().statusCounts().get("IN_PROGRESS"), "黄数只数财审三档");
        assertFalse(page.summary().statusCounts().containsKey("WAITING_COMPONENT_STOCK"));

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em, times(5)).createNativeQuery(sql.capture());
        String rowsSql = sql.getAllValues().getFirst();
        List<String> precedence = List.of(
                "THEN 'SHORT_DELIVERY'", "THEN 'WAITING_MORE_BATCH'", "THEN 'TOLERANT_SHORT'",
                "THEN 'RECEIVED_PENDING_STOCK'", "WHEN progress.any_drawable THEN 'DRAWABLE'",
                "WHEN progress.any_draw_submitted THEN 'DRAW_SUBMITTED'", "THEN 'PARTIAL_RECEIVED'",
                "WHEN progress.any_issued THEN 'AT_SUPPLIER'", "ELSE 'WAITING_MATERIAL' END",
                "AND bom_gap.bom_missing THEN 'BOM_MISSING'");
        int previous = -1;
        for (String stage : precedence) {
            int at = rowsSql.indexOf(stage);
            assertTrue(at > previous, "状态列优先级顺序: " + stage);
            previous = at;
        }
        assertTrue(rowsSql.contains("CROSS JOIN LATERAL fn_subcontract_draw_summary(draw_item.id) draw_summary"));
        // ADR-143 §二.3：委外申请里有缺 BOM 的委外件时不能生成订货单, 状态列为「缺 BOM·已通知研发」。
        assertTrue(rowsSql.contains(
                "AND base.open_line_count > 0 AND NOT COALESCE(bom_gap.bom_missing, FALSE)) AS can_create_order"));
        assertTrue(rowsSql.contains("NOT EXISTS (SELECT 1 FROM fn_subcontract_draw_edges(gap_item.goods_id))"));
        assertTrue(rowsSql.contains("bom_gap.rd_task_no AS rd_task_no"));
        assertTrue(rowsSql.contains("OR (:status NOT IN ('OPEN_ANY', 'IN_PROGRESS') AND task_status = :status)"));
        for (String removed : List.of("flow_mode", "component", "AWAITING_OUTBOUND", "OUTBOUND_WAITING_COMPONENT",
                "preplan_subcontract_make", "SUBCONTRACT_MAKE_TASK", "SUPPLIER_SELF_SUPPLIED", "self_supplied")) {
            assertFalse(rowsSql.contains(removed), removed);
        }
        String statusSql = sql.getAllValues().get(2);
        // ADR-143 §二.3: 缺 BOM 的申请行留在「待处理」段, 但单独按 BOM_MISSING 分桶, 不计入该段红数。
        assertTrue(statusSql.contains(
                "SELECT CASE WHEN display_stage = 'BOM_MISSING' THEN 'BOM_MISSING' ELSE task_status END AS status_key"));
        assertTrue(statusSql.contains("GROUP BY 1"));
        assertFalse(statusSql.contains("WAITING_COMPONENT_STOCK"));
    }

    /** 采购列表的状态列就是 task_status, 不拼委外的领料片段。 */
    @Test
    void purchaseRowsUseTaskStatusAsDisplayStage() {
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

        new FulfillmentWorkbenchQueryService(em, mock(FulfillmentWorkbenchAccessPolicy.class))
                .query("PURCHASE", "", "", "", null, null, 1, 20);

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em, times(5)).createNativeQuery(sql.capture());
        String rowsSql = sql.getAllValues().getFirst();
        assertTrue(rowsSql.contains("base.task_status AS display_stage"));
        assertFalse(rowsSql.contains("fn_subcontract_draw_summary"));
        assertFalse(rowsSql.contains("component"));
        assertTrue(rowsSql.contains("OR (:status NOT IN ('OPEN_ANY', 'IN_PROGRESS') AND task_status = :status)"));
    }

    /** 第 37 列 display_stage 读进行对象, 脱敏/透传两条路都不丢; 短行 (旧 34 列) 为 null. */
    @Test
    void displayStageAndOrderCapabilityAreReadFromTheRowAndSurviveActionCopy() {
        EntityManager em = mock(EntityManager.class);
        Query rows = mock(Query.class);
        Query summary = mock(Query.class);
        Query statuses = mock(Query.class);
        Query exceptions = mock(Query.class);
        Query pending = mock(Query.class);
        Query sources = mock(Query.class);
        when(em.createNativeQuery(anyString()))
                .thenReturn(rows, sources, summary, statuses, exceptions, pending);
        when(pending.getSingleResult()).thenReturn(0L);
        UUID documentId = UUID.randomUUID();
        Object[] wide = java.util.Arrays.copyOf(
                taskRow("SUBCONTRACT", "SUBCONTRACT_APPLICATION", documentId, UUID.randomUUID()), 37);
        wide[35] = Boolean.TRUE;
        wide[36] = "WAITING_ORDER";
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
        assertEquals("WAITING_ORDER", ready.displayStage());
        assertTrue(ready.canCreateOrder());
        assertEquals(null, page.items().get(1).displayStage());
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
        // One requested DRAW or one pending material-definition request is one task.
        assertTrue(sql.getValue().contains("FROM v_fulfillment_workbench v"));
        assertTrue(sql.getValue().contains("mapping.demand_id=v.task_id"));
        assertTrue(sql.getValue().contains("draw_doc.warehouse_id AS warehouse_id"));
        assertTrue(sql.getValue().contains("open_line_count > 0"));
        assertTrue(sql.getValue().contains("fn_production_draw_requested(draw_doc.id)"));
        assertTrue(sql.getValue().contains("production_material_discovery_requests"));
        assertTrue(sql.getValue().contains("request.status='PENDING'"));
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
        assertTrue(sql.getValue().contains("fn_production_draw_requested(draw_doc.id)"));
    }

    @Test void warehouseUnknownMaterialRequestsHaveTheirOwnStatusAndCountOnceWithoutInventingQuantity() {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of(new Object[]{"READY_TO_PICK", 3L},
                new Object[]{"PARTIAL", 2L}, new Object[]{"MATERIALS_TO_DEFINE", 4L}));
        FulfillmentWorkbenchAccessPolicy access = mock(FulfillmentWorkbenchAccessPolicy.class);
        when(access.canAccessWarehouseTasks()).thenReturn(true);
        var counts = new FulfillmentWorkbenchQueryService(em, access).warehouseStatusBreakdown(
                new com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseTaskScope(true, List.of(), true));
        assertEquals(4L, counts.get("MATERIALS_TO_DEFINE"));
        assertEquals(9L, counts.get("OPEN_ANY"));
        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em).createNativeQuery(sql.capture());
        assertTrue(sql.getValue().contains("material.qty, 'MATERIALS_TO_DEFINE'"));
        assertTrue(sql.getValue().contains("jsonb_to_recordset(request.requested_materials)"));
        assertTrue(sql.getValue().contains("request.status='PENDING'"));
        assertTrue(sql.getValue().contains("NOT plan.is_closed"));
        assertTrue(sql.getValue().contains("warehouse_id IS NULL OR"));
        verify(query).setParameter("warehouse_scope", "");
    }

    /** 生产领料任务中心表头排序(2026-09-24): 按生产计划号排, 白名单字段;
     *  2026-09-25 单号列统一: 仓库多跑一次 docNo(领料单号)分面查询, 桶随响应带回。 */
    @Test
    void warehouseRowsSortByPlanNumberAndCarryDocNoFacets() {
        EntityManager em = mock(EntityManager.class);
        Query rows = mock(Query.class);
        Query summary = mock(Query.class);
        Query statuses = mock(Query.class);
        Query exceptions = mock(Query.class);
        Query pending = mock(Query.class);
        Query docNoFacets = mock(Query.class);
        when(em.createNativeQuery(anyString()))
                .thenReturn(rows, summary, statuses, exceptions, pending, docNoFacets);
        when(rows.getResultList()).thenReturn(List.of());
        when(summary.getSingleResult()).thenReturn(new Object[]{0L, 0L, 0L, BigDecimal.ZERO});
        when(statuses.getResultList()).thenReturn(List.of());
        when(exceptions.getResultList()).thenReturn(List.of());
        when(pending.getSingleResult()).thenReturn(0L);
        when(docNoFacets.getResultList())
                .thenReturn(List.of(new Object[]{"LL2609001", 2L}, new Object[]{null, 1L}));
        FulfillmentWorkbenchAccessPolicy access = mock(FulfillmentWorkbenchAccessPolicy.class);
        when(access.canAccessWarehouseTasks()).thenReturn(true);

        FulfillmentWorkbenchPage result = new FulfillmentWorkbenchQueryService(em, access).query(
                "WAREHOUSE", "OPEN_ANY", "", "", null, null, 1, 20,
                new FulfillmentWorkbenchTableQuery("planNo", "desc", java.util.Map.of(), null, null, null, null));

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em, times(6)).createNativeQuery(sql.capture());
        assertTrue(sql.getAllValues().getFirst().contains("NULLIF(plan_no,'') desc NULLS LAST, task_id"));
        // docNo 分面：与列表同一份 WHERE（filters），按 visible_doc_no 分组计数。
        assertTrue(sql.getAllValues().getLast().contains("GROUP BY visible_doc_no"));
        assertEquals(1, result.facets().size());
        assertEquals("LL2609001", result.facets().get("docNo").getFirst().value());
        assertEquals(2L, result.facets().get("docNo").getFirst().count());
        // 看不见领料单号的行（对象范围裁剪/物料待定）计进 nullCounts，不混进桶。
        assertEquals(1L, result.nullCounts().get("docNo"));
    }

    @Test
    void warehouseSortOnlyColumnsAreWhitelistedAndNeverBecomeFilters() {
        assertEquals("NULLIF(warehouse_name,'') asc NULLS LAST, task_id",
                new FulfillmentWorkbenchTableQuery("warehouseName", "asc", java.util.Map.of(),
                        null, null, null, null).orderSql());
        assertEquals("open_qty desc NULLS LAST, task_id",
                new FulfillmentWorkbenchTableQuery("openQty", "desc", java.util.Map.of(),
                        null, null, null, null).orderSql());
        org.junit.jupiter.api.Assertions.assertThrows(com.uten.imp.common.web.ApiException.class,
                () -> new FulfillmentWorkbenchTableQuery("warehouseName", "asc",
                        java.util.Map.of("warehouseName", "成品仓库"), null, null, null, null));
        org.junit.jupiter.api.Assertions.assertThrows(com.uten.imp.common.web.ApiException.class,
                () -> new FulfillmentWorkbenchTableQuery("warehouse_name;--", "asc",
                        java.util.Map.of(), null, null, null, null));
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
                "warehouseCount", java.util.UUID.class);
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
